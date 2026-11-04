"""Split the ARDY-mini ONNX graphs from their weights: ONNX external data.

Writes a copy of a patched float32 model directory (scripts/motion/ardy_patch_graphs.py)
with each graph's initializers moved out of the protobuf into a sidecar
(`ardy_mini_<graph>.onnx.data`, the name the asset dataset uses, which the
graph records and ONNX Runtime resolves next to the graph wherever it sits).
The numbers do not change. What changes is how the phone holds the weights:
ONNX Runtime memory-maps external initializers on its CPU provider and reads
them in place, so they are clean, file-backed pages the kernel can drop and
refetch and not part of the app's footprint, while a protobuf's weights are
parsed into anonymous memory that counts in full. A float16 graph on that
runtime's CPU provider is worse, not better: it casts every weight to float32
at the start of each step (there is no float16 MatMul kernel), so the whole
float32 set is live in each step (iPhone 11, 2026-11-02).

Each graph is then run against the original through ONNX Runtime and must
match exactly; model.json's `files` gain the sidecars with sizes and SHA-256s.

usage: python -I scripts/motion/ardy_external_graphs.py <patched_fp32_dir> <output_dir> [--skip-compare]
"""
import argparse
import hashlib
import json
import shutil
import time
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

GRAPHS = ("text_encoder", "decoder", "denoiser")
# Initializers this small stay inside the graph: a few hundred shape
# constants and biases are not worth a file read each.
EXTERNAL_THRESHOLD_BYTES = 1024


def sidecar_name(graph):
    return f"ardy_mini_{graph}.onnx.data"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def example_feeds(session):
    feeds = {}
    for inp in session.get_inputs():
        shape = [1 if (d is None or isinstance(d, str)) else d for d in inp.shape]
        if inp.type == "tensor(int64)":
            feeds[inp.name] = np.zeros(shape, np.int64)
            if inp.name in ("generation_len", "history_len"):
                feeds[inp.name][...] = 40
            if inp.name == "timestep":
                feeds[inp.name][...] = 7
            if inp.name == "input_ids":
                feeds[inp.name][...] = 101
            if inp.name == "attention_mask":
                feeds[inp.name][...] = 1
        elif "mask" in inp.name:
            feeds[inp.name] = np.ones(shape, np.float32)
        else:
            rng = np.random.default_rng(1)
            feeds[inp.name] = rng.standard_normal(shape).astype(np.float32)
    return feeds


def max_difference(x, y):
    """Largest |x - y| over the finite entries; infinite when the two
    disagree on where the NaNs are."""
    x64, y64 = x.astype(np.float64), y.astype(np.float64)
    if not np.array_equal(np.isnan(x64), np.isnan(y64)):
        return float("inf")
    finite = ~np.isnan(x64)
    return float(np.max(np.abs(x64[finite] - y64[finite]))) if finite.any() else 0.0


def compare(original, external):
    """Largest absolute difference between the two graphs' outputs on the
    CPU provider; the weights are the same bytes, so this must be 0."""
    options = ort.SessionOptions()
    options.log_severity_level = 3
    a = ort.InferenceSession(str(original), options, providers=["CPUExecutionProvider"])
    b = ort.InferenceSession(str(external), options, providers=["CPUExecutionProvider"])
    feeds = example_feeds(a)
    outs_a = a.run(None, feeds)
    outs_b = b.run(None, feeds)
    worst = max(max_difference(x, y) for x, y in zip(outs_a, outs_b))
    return worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--skip-compare", action="store_true")
    args = parser.parse_args()
    source, target = Path(args.source), Path(args.target)
    target.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((source / "model.json").read_text())
    files = manifest["files"]
    for name in GRAPHS:
        started = time.time()
        model = onnx.load(str(source / f"{name}.onnx"))
        graph_out = target / f"{name}.onnx"
        data_out = target / sidecar_name(name)
        for stale in (graph_out, data_out):
            if stale.exists():
                stale.unlink()
        onnx.save_model(
            model,
            str(graph_out),
            save_as_external_data=True,
            all_tensors_to_one_file=True,
            location=sidecar_name(name),
            size_threshold=EXTERNAL_THRESHOLD_BYTES,
            convert_attribute=False,
        )
        onnx.checker.check_model(str(graph_out), full_check=True)
        graph_size, data_size = graph_out.stat().st_size, data_out.stat().st_size
        print(
            f"{name}: graph {graph_size / 2**20:.1f} MB + weights {data_size / 2**20:.0f} MB "
            f"(was one file of {(source / f'{name}.onnx').stat().st_size / 2**20:.0f} MB), checker passed, "
            f"{time.time() - started:.0f} s",
            flush=True,
        )
        if not args.skip_compare:
            worst = compare(source / f"{name}.onnx", graph_out)
            print(f"{name}: max |Δ| vs the single-file graph {worst:.3g}", flush=True)
            if worst != 0:
                raise SystemExit(f"{name}: the external-data graph does not match its source")
        entry = files[f"{name}.onnx"]
        entry["sha256"], entry["size_bytes"] = sha256(graph_out), graph_size
        entry.pop("transport", None)
        entry["external_data"] = sidecar_name(name)
        files[sidecar_name(name)] = {"sha256": sha256(data_out), "size_bytes": data_size}
    for name in ("tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"):
        (target / name).parent.mkdir(exist_ok=True)
        shutil.copyfile(source / name, target / name)
    notes = dict(manifest.get("notes", {}))
    notes["layout"] = (
        "float32 weights in ONNX external-data sidecars (ardy_mini_<graph>.onnx.data), memory-mapped by "
        "ONNX Runtime's CPU provider (scripts/motion/ardy_external_graphs.py)"
    )
    manifest["notes"] = notes
    (target / "model.json").write_text(json.dumps(manifest))
    print("model.json rewritten with the sidecars", flush=True)


if __name__ == "__main__":
    main()
