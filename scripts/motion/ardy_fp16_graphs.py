"""Halve the ARDY-mini ONNX graphs: float16 weights and activations.

Kept for the bench. The app downloads the float32 graphs with their weights
in external-data sidecars (scripts/motion/ardy_external_graphs.py): on ONNX Runtime
1.20's CPU provider a float16 graph costs more memory than float32, not
less, since every weight is cast to float32 at the start of each step.

Writes a copy of a patched model directory (scripts/motion/ardy_patch_graphs.py) with
the three graphs converted to float16, the graph inputs and outputs kept
float32 so motion_bridge's tensor contract is unchanged, and model.json's
sizes and SHA-256s rewritten. Ops that float16 cannot carry stay float32:
the converter's own block list, plus, with --keep-fp32-from, everything the
named inputs feed before the first weight multiply (for a sinusoidal timestep
embedding in another export; ARDY's is a learned ten-entry table, so nothing
by default). Each graph is then run
against the float32 original through ONNX Runtime and the largest difference
reported; the real check is scripts/motion/ardy_mini_batch.py on both folders.

usage: python -I scripts/motion/ardy_fp16_graphs.py <patched_fp32_dir> <output_dir> [--keep-fp32-from timestep,...]
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
from onnxconverter_common import float16

GRAPHS = ("text_encoder", "decoder", "denoiser")
WEIGHT_OPS = {"MatMul", "Gemm", "Conv", "Einsum"}


def nodes_fed_by(model, input_names):
    """Names of the nodes on every path from `input_names` up to, excluding,
    the first node that multiplies by weights."""
    graph = model.graph
    consumers = {}
    for node in graph.node:
        for name in node.input:
            consumers.setdefault(name, []).append(node)
    blocked, tainted, queue = set(), set(input_names), list(input_names)
    while queue:
        tensor = queue.pop()
        for node in consumers.get(tensor, []):
            if node.op_type in WEIGHT_OPS or node.name in blocked:
                continue
            blocked.add(node.name)
            for out in node.output:
                if out not in tainted:
                    tainted.add(out)
                    queue.append(out)
    return blocked


def retarget_casts(model, original_casts, blocked):
    """The converter retypes the outputs of the graph's own Cast-to-float
    nodes as float16 but leaves their `to` at float32, which the loader then
    rejects. Point those Casts at float16: only the graph's own (the casts
    the converter adds around float32 islands and graph outputs are right
    as they are), and none kept float32."""
    fixed = 0
    for node in model.graph.node:
        if node.op_type != "Cast" or node.name not in original_casts or node.name in blocked:
            continue
        for attribute in node.attribute:
            if attribute.name == "to" and attribute.i == onnx.TensorProto.FLOAT:
                attribute.i = onnx.TensorProto.FLOAT16
                fixed += 1
    return fixed


def rewire_output_consumers(model):
    """A tensor that is both a graph output and an input of other nodes
    (the decoder's `normalized_motion`) gets a float32 output cast from the
    converter, but those nodes keep reading the cast's output while their
    other inputs went float16. Point them back at the float16 tensor."""
    outputs = {o.name for o in model.graph.output}
    fp16_source = {}
    for node in model.graph.node:
        if node.op_type == "Cast" and len(node.output) == 1 and node.output[0] in outputs:
            if any(a.name == "to" and a.i == onnx.TensorProto.FLOAT for a in node.attribute):
                fp16_source[node.output[0]] = node.input[0]
    rewired = 0
    for node in model.graph.node:
        if node.op_type == "Cast" and len(node.output) == 1 and node.output[0] in fp16_source:
            continue
        for index, name in enumerate(node.input):
            if name in fp16_source:
                node.input[index] = fp16_source[name]
                rewired += 1
    return rewired


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
            if inp.name == "generation_len":
                feeds[inp.name][...] = 40
            if inp.name == "history_len":
                feeds[inp.name][...] = 40
            if inp.name == "timestep":
                feeds[inp.name][...] = 7  # an index into the ten-step schedule's embedding table
            if inp.name == "input_ids":
                feeds[inp.name][0, : min(10, shape[1])] = [101, 1037, 2711, 5975, 2007, 1996, 2157, 2192, 1012, 102][: min(10, shape[1])]
            if inp.name == "attention_mask":
                feeds[inp.name][...] = 1
        else:
            feeds[inp.name] = (np.random.RandomState(0).randn(*shape) * 0.5).astype(np.float32)
            if inp.name.endswith("mask"):
                feeds[inp.name][...] = 0
                feeds[inp.name].reshape(-1)[: feeds[inp.name].size // 2] = 1
            if inp.name == "cfg_weight":
                feeds[inp.name][...] = 2.0
    return feeds


def compare(original_path, converted_path):
    original = ort.InferenceSession(str(original_path), providers=["CPUExecutionProvider"])
    feeds = example_feeds(original)
    outputs = [o.name for o in original.get_outputs()]
    reference = original.run(outputs, feeds)
    report = []
    for providers in (["CoreMLExecutionProvider", "CPUExecutionProvider"], ["CPUExecutionProvider"]):
        try:
            started = time.time()
            converted = ort.InferenceSession(str(converted_path), providers=providers)
            created = time.time() - started
            started = time.time()
            got = converted.run(outputs, feeds)
            ran = time.time() - started
        except Exception as error:  # noqa: BLE001 - reported, not fatal
            report.append(f"    {providers[0]}: failed ({str(error).splitlines()[0][:160]})")
            continue
        worst = 0.0
        for name, a, b in zip(outputs, reference, got):
            if a.dtype == np.bool_:
                delta = float((a != b).mean())
                report.append(f"    {providers[0]}: {name}: {delta * 100:.2f} % of booleans differ")
                continue
            scale = float(np.abs(a).max()) or 1.0
            delta = float(np.abs(a.astype(np.float32) - b.astype(np.float32)).max())
            worst = max(worst, delta / scale)
            report.append(f"    {providers[0]}: {name}: max |Δ| {delta:.3g} (scale {scale:.3g}, {delta / scale * 100:.3f} %)")
        report.append(f"    {providers[0]}: session {created:.1f} s, run {ran * 1000:.0f} ms, worst relative {worst * 100:.3f} %")
    return "\n".join(report)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--keep-fp32-from", default="", help="comma-separated graph inputs whose pre-weight subgraph stays float32 (none by default: ARDY's timestep embedding is a table lookup)")
    parser.add_argument("--skip-compare", action="store_true")
    args = parser.parse_args()
    source, target = Path(args.source), Path(args.target)
    target.mkdir(parents=True, exist_ok=True)
    keep_from = [name for name in args.keep_fp32_from.split(",") if name]
    manifest = json.loads((source / "model.json").read_text())
    for name in GRAPHS:
        started = time.time()
        model = onnx.load(str(source / f"{name}.onnx"))
        present = {i.name for i in model.graph.input}
        original_casts = {n.name for n in model.graph.node if n.op_type == "Cast"}
        blocked = nodes_fed_by(model, [n for n in keep_from if n in present])
        converted = float16.convert_float_to_float16(
            model, keep_io_types=True, disable_shape_infer=False, node_block_list=sorted(blocked) or None
        )
        casts = retarget_casts(converted, original_casts, blocked)
        rewired = rewire_output_consumers(converted)
        onnx.checker.check_model(converted, full_check=True)
        out = target / f"{name}.onnx"
        onnx.save(converted, str(out), save_as_external_data=False)
        size = out.stat().st_size
        print(
            f"{name}: {size / 2**20:.0f} MB (was {(source / f'{name}.onnx').stat().st_size / 2**20:.0f} MB), "
            f"{len(blocked)} nodes kept float32, {casts} casts retargeted, {rewired} output readers rewired, checker passed, "
            f"{time.time() - started:.0f} s",
            flush=True,
        )
        if not args.skip_compare:
            print(compare(source / f"{name}.onnx", out), flush=True)
        entry = manifest["files"][f"{name}.onnx"]
        entry["sha256"], entry["size_bytes"] = sha256(out), size
        entry.pop("transport", None)
    for name in ("tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"):
        (target / name).parent.mkdir(exist_ok=True)
        shutil.copyfile(source / name, target / name)
    notes = dict(manifest.get("notes", {}))
    islands = f"; the subgraphs fed by {', '.join(keep_from)} stay float32" if keep_from else ""
    notes["precision"] = f"float16 weights and activations, float32 inputs/outputs{islands} (scripts/motion/ardy_fp16_graphs.py)"
    manifest["notes"] = notes
    (target / "model.json").write_text(json.dumps(manifest))
    print("model.json rewritten with the float16 hashes", flush=True)


if __name__ == "__main__":
    main()
