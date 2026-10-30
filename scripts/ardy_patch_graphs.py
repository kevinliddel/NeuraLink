"""Prepare ARDY-mini ONNX graphs for ONNX Runtime's CoreML provider.

The published graphs leave Clip's optional max bound empty, which is legal ONNX
but the CoreML execution provider refuses ("Required param 'beta' is missing")
and onnx2torch mis-parses. This writes a copy of the model directory with every
Clip given explicit float32 bounds, verifies the three graphs still produce the
same outputs through ONNX Runtime, and rewrites model.json's file sizes and
SHA-256s so GeneratedMotionBench can verify the copy.

usage: python -I scripts/ardy_patch_graphs.py <model_dir> <output_dir>
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper

GRAPHS = ("text_encoder", "decoder", "denoiser")
# Finite but not FLT_MAX: ONNX Runtime's CoreML builder treats FLT_MAX as "no bound".
BOUNDS = {
    onnx.TensorProto.FLOAT: (np.float32(-1e30), np.float32(1e30)),
    onnx.TensorProto.INT64: (np.int64(-(2**62)), np.int64(2**62)),
    onnx.TensorProto.INT32: (np.int32(-(2**30)), np.int32(2**30)),
}


def tensor_types(model):
    """Element type of every value the graph names, from shape inference,
    initializers and inputs."""
    inferred = onnx.shape_inference.infer_shapes(model)
    types = {}
    for info in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output):
        if info.type.HasField("tensor_type"):
            types[info.name] = info.type.tensor_type.elem_type
    for init in model.graph.initializer:
        types[init.name] = init.data_type
    return types


def patch_clip_bounds(model):
    graph, fixed = model.graph, 0
    types = tensor_types(model)
    for node in graph.node:
        if node.op_type != "Clip":
            continue
        while len(node.input) < 3:
            node.input.append("")
        element_type = types.get(node.input[0]) or next((types[i] for i in node.input[1:] if i in types), onnx.TensorProto.FLOAT)
        low, high = BOUNDS[element_type]
        for index, (suffix, value) in enumerate((("min", low), ("max", high)), start=1):
            if node.input[index] == "":
                name = f"{node.name}_{suffix}_patch".replace("/", "_")
                graph.initializer.append(numpy_helper.from_array(np.array(value), name))
                node.input[index] = name
                fixed += 1
    return fixed


def same_outputs(original, patched, feeds):
    outputs = [o.name for o in original.get_outputs()]
    a = original.run(outputs, feeds)
    b = patched.run(outputs, feeds)
    return max(float(np.abs(x - y).max()) for x, y in zip(a, b) if x.dtype != np.bool_)


def example_feeds(session):
    feeds = {}
    for inp in session.get_inputs():
        shape = [1 if (d is None or isinstance(d, str)) else d for d in inp.shape]
        if inp.type == "tensor(int64)":
            feeds[inp.name] = np.zeros(shape, np.int64) if inp.name != "generation_len" else np.array([40], np.int64)
            if inp.name == "input_ids":
                feeds[inp.name][0, :min(10, shape[1])] = [101, 1037, 2711, 5975, 2007, 1996, 2157, 2192, 1012, 102][: min(10, shape[1])]
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


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    target.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((source / "model.json").read_text())
    for name in GRAPHS:
        model = onnx.load(str(source / f"{name}.onnx"))
        fixed = patch_clip_bounds(model)
        out = target / f"{name}.onnx"
        onnx.save(model, str(out), save_as_external_data=False)
        original = ort.InferenceSession(str(source / f"{name}.onnx"), providers=["CPUExecutionProvider"])
        patched = ort.InferenceSession(str(out), providers=["CPUExecutionProvider"])
        delta = same_outputs(original, patched, example_feeds(original))
        print(f"{name}: {fixed} Clip bounds added, max |Δ| vs original {delta:.3g}, {out.stat().st_size / 2**20:.0f} MB")
        entry = manifest["files"][f"{name}.onnx"]
        entry["sha256"], entry["size_bytes"] = sha256(out), out.stat().st_size
        entry.pop("transport", None)
    for name in ("tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"):
        (target / name).parent.mkdir(exist_ok=True)
        shutil.copyfile(source / name, target / name)
    manifest["notes"] = {"patched": "Clip bounds made explicit for the CoreML execution provider (scripts/ardy_patch_graphs.py)"}
    (target / "model.json").write_text(json.dumps(manifest))
    print("model.json rewritten with the patched hashes")


if __name__ == "__main__":
    main()
