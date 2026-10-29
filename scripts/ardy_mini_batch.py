"""Batch driver for the ARDY-mini ONNX graphs (docs/REALTIME_MOTION_PLAN.md, Phase 0).

Model files: the fp32 directory of intsuc/Llama-3-ARDY-Mini-Core40-Browser on
Hugging Face (model.json, text_encoder.onnx, denoiser.onnx, decoder.onnx,
tokenizer/), gunzipped and SHA-256 checked against model.json. Their terms are
separate from this repository's licence; see the plan.

A Python port of ardy-mini's browser runtime loop (web/src/runtime/engine.ts,
windows.ts, ddim.ts, random.ts) so clips can be generated in batch on the Mac
without running any downloaded code: only the ONNX graphs (data) are loaded.

usage: python -I scripts/ardy_mini_batch.py --model-dir DIR --out DIR [--captions FILE]
       [--seeds 1,2,3] [--seconds 4] [--steps 10] [--cfg 2.0] [--history-frames 40]
       [--provider cpu|coreml]
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

M32 = 0xFFFFFFFF
EPSILON = 2.220446049250313e-16


class PortableRandom:
    """Mulberry32 uniform + Marsaglia polar normal, float32 at the write boundary."""

    def __init__(self, seed):
        if isinstance(seed, str):
            h = 0x811C9DC5
            for b in seed.encode("utf-8"):
                h ^= b
                h = (h * 0x01000193) & M32
            seed = h
        self.seed = int(seed) & M32
        self.state = self.seed
        self.spare = None

    def next_uint32(self):
        self.state = (self.state + 0x6D2B79F5) & M32
        v = self.state
        v = ((v ^ (v >> 15)) * (v | 1)) & M32
        v = v ^ ((v + (((v ^ (v >> 7)) * (v | 61)) & M32)) & M32)
        return (v ^ (v >> 14)) & M32

    def next_float(self):
        return (self.next_uint32() + 1) / (4294967296 + 1)

    def next_normal(self):
        if self.spare is not None:
            r, self.spare = self.spare, None
            return r
        while True:
            x = 2 * self.next_float() - 1
            y = 2 * self.next_float() - 1
            r2 = x * x + y * y
            if EPSILON < r2 < 1:
                break
        s = math.sqrt(-2 * math.log(r2) / r2)
        self.spare = y * s
        return x * s

    def fill_normal(self, target, start, end):
        for i in range(start, end):
            target[i] = np.float32(self.next_normal())


def round_ties_to_even(value):
    f = math.floor(value)
    frac = value - f
    if frac < 0.5:
        return f
    if frac > 0.5:
        return f + 1
    return f if f % 2 == 0 else f + 1


class ArdyMini:
    def __init__(self, model_dir, provider="cpu", threads=0):
        self.dir = Path(model_dir)
        self.m = json.loads((self.dir / "model.json").read_text())
        d = self.m["dimensions"]
        self.hd = d["hybrid_dim"]
        self.max_tokens = d["max_tokens"]
        self.max_frames = d["max_frames"]
        self.fpt = d["num_frames_per_token"]
        self.history_tokens = d["history_tokens"]
        self.gen_tokens = d["generation_tokens"]
        self.gen_frames = d["generation_frames"]
        self.root_dim = d["root_features_per_frame"]
        self.root_token_dim = d["nframe_root_dim"]
        self.latent_dim = d["latent_dim"]
        self.motion_dim = d["motion_dim"]
        self.joints = d["num_joints"]
        self.fps = d["fps"]
        self.dims = d
        self.recenter = self.m["recenter"]
        self.quant = self.m["latent_quantization"]
        self.diffusion = self.m["diffusion"]
        self.graphs = self.m["graphs"]
        opts = ort.SessionOptions()
        if threads:
            opts.intra_op_num_threads = threads
        providers = ["CPUExecutionProvider"]
        if provider == "coreml":
            providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"]
        t0 = time.perf_counter()
        self.enc = ort.InferenceSession(str(self.dir / "text_encoder.onnx"), opts, providers=providers)
        self.den = ort.InferenceSession(str(self.dir / "denoiser.onnx"), opts, providers=providers)
        self.dec = ort.InferenceSession(str(self.dir / "decoder.onnx"), opts, providers=providers)
        self.load_s = time.perf_counter() - t0
        tok = self.m["tokenizer"]
        self.tokenizer = Tokenizer.from_file(str(self.dir / tok["directory"] / "tokenizer.json"))
        self.max_length = tok["max_length"]
        self.skeleton = self.m["skeleton"]

    # ---- text -----------------------------------------------------------
    def encode_text(self, prompt):
        enc = self.tokenizer.encode(prompt, add_special_tokens=True)
        ids, mask, types = enc.ids, enc.attention_mask, enc.type_ids
        if len(ids) > self.max_length:  # keep the final [SEP]
            ids = ids[: self.max_length - 1] + [ids[-1]]
            mask = mask[: self.max_length - 1] + [mask[-1]]
            types = types[: self.max_length - 1] + [types[-1]]
        g = self.graphs["text_encoder"]
        feeds = {
            g["inputs"]["inputIds"]: np.array([ids], dtype=np.int64),
            g["inputs"]["attentionMask"]: np.array([mask], dtype=np.int64),
            g["inputs"]["tokenTypeIds"]: np.array([types], dtype=np.int64),
        }
        out = self.enc.run([g["outputs"]["textConditions"]], feeds)[0]
        assert out.shape == (1, 1, self.dims["text_condition_dim"]) and np.isfinite(out).all()
        return out.astype(np.float32), len(ids)

    # ---- windows ----------------------------------------------------------
    def root_offset(self, frame, feature):
        return (frame // self.fpt) * self.hd + (frame % self.fpt) * self.root_dim + feature

    def raw_root(self, buf, frame, feature):
        return float(buf[self.root_offset(frame, feature)]) * self.recenter["root_std"][feature] + self.recenter["root_mean"][feature]

    def set_root(self, buf, frame, feature, raw):
        buf[self.root_offset(frame, feature)] = np.float32((raw - self.recenter["root_mean"][feature]) / self.recenter["root_std"][feature])

    def create_window(self, random, history):
        history_tokens = 0 if history is None else len(history) // self.hd
        history_frames = history_tokens * self.fpt
        x = np.zeros(self.max_tokens * self.hd, dtype=np.float32)
        if history is not None:
            x[: len(history)] = history
        random.fill_normal(x, history_tokens * self.hd, (history_tokens + self.gen_tokens) * self.hd)
        hm = np.zeros(self.max_frames, np.float32); hm[:history_frames] = 1
        gm = np.zeros(self.max_frames, np.float32); gm[history_frames: history_frames + self.gen_frames] = 1
        htm = np.zeros(self.max_tokens, np.float32); htm[:history_tokens] = 1
        gtm = np.zeros(self.max_tokens, np.float32); gtm[history_tokens: history_tokens + self.gen_tokens] = 1
        return dict(x=x, history_mask=hm, generation_mask=gm, history_token_mask=htm, generation_token_mask=gtm,
                    history_frames=history_frames, generation_frames=self.gen_frames,
                    history_tokens=history_tokens, generation_tokens=self.gen_tokens, generation_token_offset=history_tokens)

    def denoise(self, window, text, first_heading, cfg, steps=None):
        g = self.graphs["denoiser"]["inputs"]
        i = self.graphs["denoiser"]
        timesteps = self.diffusion["timesteps"]
        if steps and steps < len(timesteps):
            # Fewer steps: keep the same schedule ends, subsample reachable timesteps.
            idx = np.round(np.linspace(0, len(timesteps) - 1, steps)).astype(int)
            timesteps = [timesteps[k] for k in idx]
        ac, acp = self.diffusion["alphas_cumprod"], self.diffusion["alphas_cumprod_prev"]
        x = window["x"]
        gs = window["generation_token_offset"] * self.hd
        ge = (window["generation_token_offset"] + window["generation_tokens"]) * self.hd
        feeds = {
            g["cfgWeight"]: np.array([cfg], np.float32),
            g["x"]: x.reshape(1, self.max_tokens, self.hd),
            g["historyLength"]: np.array([window["history_frames"]], np.int64),
            g["generationLength"]: np.array([window["generation_frames"]], np.int64),
            g["historyMask"]: window["history_mask"].reshape(1, -1),
            g["generationMask"]: window["generation_mask"].reshape(1, -1),
            g["historyTokenMask"]: window["history_token_mask"].reshape(1, -1),
            g["generationTokenMask"]: window["generation_token_mask"].reshape(1, -1),
            g["textConditions"]: text,
            g["timestep"]: np.array([0], np.int64),
            g["firstHeadingAngle"]: np.array([first_heading], np.float32),
        }
        step_times = []
        for k, t in enumerate(timesteps):
            alpha, alpha_prev = ac[t], (acp[t] if k == len(timesteps) - 1 or steps is None or steps >= len(self.diffusion["timesteps"]) else ac[timesteps[k + 1]])
            feeds[g["timestep"]] = np.array([t], np.int64)
            feeds[g["x"]] = x.reshape(1, self.max_tokens, self.hd)
            t0 = time.perf_counter()
            pred = self.den.run([i["outputs"]["predX0"]], feeds)[0].reshape(-1)
            step_times.append(time.perf_counter() - t0)
            sa, srm1 = math.sqrt(alpha), math.sqrt(1 / alpha - 1)
            sp, somp = math.sqrt(alpha_prev), math.sqrt(1 - alpha_prev)
            xs, ps = x[gs:ge].astype(np.float64), pred[gs:ge].astype(np.float64)
            eps = np.zeros_like(xs) if srm1 == 0 else (xs / sa - ps) / srm1
            x[gs:ge] = (ps * sp + eps * somp).astype(np.float32)
        return step_times

    def recenter_and_requantize(self, hybrid, valid_tokens, global_translation, next_history_start):
        rc, q = self.recenter, self.quant
        px, py, pz = rc["position_indices"]
        hc, hs = rc["heading_indices"]
        valid_frames = valid_tokens * self.fpt
        center_frame = valid_frames - 1
        cx, cz = self.raw_root(hybrid, center_frame, px), self.raw_root(hybrid, center_frame, pz)
        for f in range(valid_frames):
            self.set_root(hybrid, f, px, self.raw_root(hybrid, f, px) - cx)
            self.set_root(hybrid, f, pz, self.raw_root(hybrid, f, pz) - cz)
        for tkn in range(valid_tokens):
            base = tkn * self.hd + self.root_token_dim
            for feat in range(self.latent_dim):
                idx = base + feat
                raw = float(hybrid[idx]) * q["std"][feat] + q["mean"][feat]
                half = q["levels"][feat] // 2
                clamped = max(-1.0, min(1.0, raw))
                discrete = round_ties_to_even(clamped * half) / half
                hybrid[idx] = np.float32((discrete - q["mean"][feat]) / q["std"][feat])
        f0 = next_history_start * self.fpt
        heading = math.atan2(self.raw_root(hybrid, f0, hs), self.raw_root(hybrid, f0, hc))
        gt = np.array([global_translation[0] + cx, global_translation[1], global_translation[2] + cz], np.float32)
        return gt, heading

    def decode(self, hybrid, valid_tokens, global_translation):
        g = self.graphs["decoder"]
        pad = np.zeros(self.max_frames, np.float32); pad[: valid_tokens * self.fpt] = 1
        names = g["outputs"]
        wanted = [names["normalizedMotion"], names["posedJoints"], names["localRotations"], names["globalRotations"],
                  names["rootPositions"], names["footContacts"], names["globalRootHeading"]]
        out = self.dec.run(wanted, {
            g["inputs"]["hybridTokens"]: hybrid.reshape(1, self.max_tokens, self.hd),
            g["inputs"]["motionPadMask"]: pad.reshape(1, -1),
            g["inputs"]["globalTranslation"]: np.asarray(global_translation, np.float32).reshape(1, 3),
        })
        return dict(motion=out[0][0], joints=out[1][0], local=out[2][0], glob=out[3][0], root=out[4][0],
                    contacts=np.asarray(out[5][0]).astype(np.uint8), heading=out[6][0])

    # ---- session ----------------------------------------------------------
    def generate(self, prompt, seed, frames, cfg=2.0, history_frames=40, steps=None, log=None):
        random = PortableRandom(seed)
        global_hybrid = np.zeros(0, np.float32)
        frame_count = 0
        initial_translation = np.zeros(3, np.float32)
        initial_heading = 0.0
        t0 = time.perf_counter()
        text, ntok = self.encode_text(prompt)
        text_s = time.perf_counter() - t0
        rc = self.recenter
        px, py, pz = rc["position_indices"]
        hc, hs = rc["heading_indices"]
        chunks = []
        timings = dict(text_s=text_s, windows=[])
        windows = math.ceil(frames / self.gen_frames)
        written = 0
        for w in range(windows):
            # prepareHistory
            available = min(frame_count // self.fpt, len(global_hybrid) // self.hd)
            requested = min(self.history_tokens, history_frames // self.fpt, available)
            if requested == 0:
                history = None
                if available > 0:
                    last = available * self.fpt - 1
                    gt = np.array([self.raw_root(global_hybrid, last, px), initial_translation[1], self.raw_root(global_hybrid, last, pz)], np.float32)
                    heading = math.atan2(self.raw_root(global_hybrid, last, hs), self.raw_root(global_hybrid, last, hc))
                else:
                    gt, heading = initial_translation.copy(), initial_heading
            else:
                first = available - requested
                history = global_hybrid[first * self.hd: available * self.hd].copy()
                hf = requested * self.fpt
                cx, cz = self.raw_root(history, hf - 1, px), self.raw_root(history, hf - 1, pz)
                heading = math.atan2(self.raw_root(history, 0, hs), self.raw_root(history, 0, hc))
                for f in range(hf):
                    self.set_root(history, f, px, self.raw_root(history, f, px) - cx)
                    self.set_root(history, f, py, self.raw_root(history, f, py) - initial_translation[1])
                    self.set_root(history, f, pz, self.raw_root(history, f, pz) - cz)
                gt = np.array([cx, initial_translation[1], cz], np.float32)
            window = self.create_window(random, history)
            step_times = self.denoise(window, text, heading, cfg, steps)
            valid = window["history_tokens"] + window["generation_tokens"]
            dec_hybrid = np.zeros(self.max_tokens * self.hd, np.float32)
            dec_hybrid[: valid * self.hd] = window["x"][: valid * self.hd]
            next_hist = max(0, valid - self.history_tokens)
            gt2, _ = self.recenter_and_requantize(dec_hybrid, valid, gt, next_hist)
            t1 = time.perf_counter()
            decoded = self.decode(dec_hybrid, valid, gt2)
            dec_s = time.perf_counter() - t1
            to_copy = min(self.gen_frames, frames - written)
            off = window["history_frames"]
            gen_tokens = math.ceil(to_copy / self.fpt)
            # buildGlobalHybridTokens
            new = np.zeros(gen_tokens * self.hd, np.float32)
            for tkn in range(gen_tokens):
                dst = tkn * self.hd
                src = (window["generation_token_offset"] + tkn) * self.hd
                for fit in range(self.fpt):
                    sf = off + tkn * self.fpt + fit
                    new[dst + fit * self.root_dim: dst + (fit + 1) * self.root_dim] = decoded["motion"][sf, : self.root_dim]
                new[dst + self.root_token_dim: dst + self.hd] = dec_hybrid[src + self.root_token_dim: src + self.hd]
            global_hybrid = np.concatenate([global_hybrid, new])
            chunks.append(dict(start=frame_count, n=to_copy,
                               local=decoded["local"][off: off + to_copy], glob=decoded["glob"][off: off + to_copy],
                               root=decoded["root"][off: off + to_copy], joints=decoded["joints"][off: off + to_copy],
                               contacts=decoded["contacts"][off: off + to_copy], heading=decoded["heading"][off: off + to_copy]))
            frame_count += to_copy
            written += to_copy
            timings["windows"].append(dict(history_tokens=window["history_tokens"], steps_s=step_times, decode_s=dec_s))
            if log:
                log(f"  window {w + 1}/{windows}: hist {window['history_tokens']} tok, "
                    f"{len(step_times)} steps {sum(step_times):.2f}s (mean {np.mean(step_times) * 1000:.0f} ms), decode {dec_s * 1000:.0f} ms")
        timings["total_s"] = time.perf_counter() - t0
        cat = lambda k: np.concatenate([c[k] for c in chunks])
        return dict(prompt=prompt, seed=random.seed, fps=self.fps, frames=written, tokens=ntok,
                    local=cat("local"), glob=cat("glob"), root=cat("root"), joints=cat("joints"),
                    contacts=cat("contacts"), heading=cat("heading"), timings=timings)


DEFAULT_CAPTIONS = [
    "A person nods their head in agreement.",
    "A person shakes their head slowly.",
    "A person shrugs with both shoulders and open palms.",
    "A person waves with the right hand.",
    "A person laughs, leaning back with the shoulders shaking.",
    "A person thinks with the right hand on the chin.",
    "A person points forward with the right hand.",
    "A person bows politely from the waist.",
    "A person leans forward attentively.",
    "A person crosses the arms over the chest.",
    "A person claps their hands.",
    "A person stretches both arms up and yawns.",
    "A person looks around curiously.",
    "A person cheers, raising both fists in the air.",
    "A person droops sadly, looking down.",
    "A person talks, gesturing with both hands.",
    "A person stands still and breathes calmly.",
]


def slug(text):
    return "".join(c if c.isalnum() else "_" for c in text.lower()).strip("_")[:48]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--captions")
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--seconds", type=float, default=4)
    ap.add_argument("--steps", type=int, default=0)
    ap.add_argument("--cfg", type=float, default=2.0)
    ap.add_argument("--history-frames", type=int, default=40)
    ap.add_argument("--provider", default="cpu")
    ap.add_argument("--threads", type=int, default=0)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    captions = DEFAULT_CAPTIONS if not args.captions else json.loads(Path(args.captions).read_text())
    if args.limit:
        captions = captions[: args.limit]
    seeds = [int(s) for s in args.seeds.split(",") if s]
    model = ArdyMini(args.model_dir, args.provider, args.threads)
    print(f"loaded in {model.load_s:.1f}s; providers {model.den.get_providers()}", flush=True)
    frames = int(round(args.seconds * model.fps))
    report = []
    for caption in captions:
        for seed in seeds:
            name = f"{slug(caption)}_s{seed}"
            print(f"== {name}", flush=True)
            r = model.generate(caption, seed, frames, args.cfg, args.history_frames, args.steps or None, log=lambda s: print(s, flush=True))
            np.savez_compressed(out / f"{name}.npz", prompt=caption, seed=r["seed"], fps=r["fps"],
                                local_rot_mats=r["local"], global_rot_mats=r["glob"], root_positions=r["root"],
                                posed_joints=r["joints"], foot_contacts=r["contacts"], heading=r["heading"])
            drift = float(np.linalg.norm(r["root"][-1, [0, 2]] - r["root"][0, [0, 2]]))
            hips_y = (float(r["root"][:, 1].min()), float(r["root"][:, 1].max()))
            # Activity: mean per-frame joint displacement (m) as a crude "did it move" number.
            act = float(np.mean(np.linalg.norm(np.diff(r["joints"], axis=0), axis=-1)))
            steps = [s for w in r["timings"]["windows"] for s in w["steps_s"]]
            rec = dict(name=name, caption=caption, seed=r["seed"], frames=r["frames"], tokens=r["tokens"],
                       total_s=r["timings"]["total_s"], text_s=r["timings"]["text_s"], step_ms_mean=1000 * float(np.mean(steps)),
                       decode_ms=[1000 * w["decode_s"] for w in r["timings"]["windows"]], root_drift_xz_m=drift, hips_y=hips_y, activity=act)
            report.append(rec)
            print(f"   total {rec['total_s']:.2f}s, drift {drift:.3f} m, hips y {hips_y[0]:.3f}..{hips_y[1]:.3f}, activity {act:.4f}", flush=True)
    (out / "report.json").write_text(json.dumps(dict(model=model.m["model"]["id"], provider=args.provider, steps=args.steps or len(model.diffusion["timesteps"]),
                                                     cfg=args.cfg, history_frames=args.history_frames, seconds=args.seconds, load_s=model.load_s, clips=report), indent=1))
    print("done", len(report), "clips", flush=True)


if __name__ == "__main__":
    main()
