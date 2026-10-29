"""ARDY-mini ONNX graphs -> Core ML programs (fp16), checked against ONNX Runtime.

docs/REALTIME_MOTION_PLAN.md, Phase 1. Runs only the published graphs through pip
libraries (onnx2torch + coremltools); no repository code from ardy-mini is executed.

Needs a machine where a current PyTorch runs: Apple Silicon or Linux with
torch >= 2.4, coremltools >= 8, onnx2torch. On the Intel Mac (torch 2.2.2, the
last Intel build) onnx2torch segfaults while converting the text encoder
(2026-10-29), so the conversion was not completed there.

usage: python -I scripts/ardy_onnx_to_coreml.py <model_dir with model.json + *.onnx> <output dir>
"""

import sys, time, json
import numpy as np, torch, onnx, onnxruntime as ort, coremltools as ct
from onnx2torch import convert
M = sys.argv[1]; OUT = sys.argv[2]
man = json.load(open(M + '/model.json'))

def check(name, mlmodel, feeds_np, ort_outputs, out_names):
    pred = mlmodel.predict({k: v for k, v in feeds_np.items()})
    for n, ref in zip(out_names, ort_outputs):
        got = np.asarray(pred[n]).reshape(ref.shape)
        print(f'  {name}.{n}: max|Δ| {np.abs(got - ref).max():.4g}  ref range {ref.min():.3g}..{ref.max():.3g}', flush=True)

def convert_graph(name, example, out_names, dynamic=None):
    t0 = time.time()
    graph = onnx.load(f'{M}/{name}.onnx')
    # Optional ONNX inputs may be given as empty names; onnx2torch wants them absent.
    stripped = 0
    for node in graph.graph.node:
        while len(node.input) and node.input[-1] == '':
            node.input.pop(); stripped += 1
    print(f'{name}: {len(graph.graph.node)} nodes, stripped {stripped} empty optional inputs; ops:', sorted({n.op_type for n in graph.graph.node}), flush=True)
    model = convert(graph).eval()
    print(f'{name}: onnx2torch ok ({time.time()-t0:.0f}s)', flush=True)
    args = tuple(torch.from_numpy(v) for v in example.values())
    with torch.no_grad():
        traced = torch.jit.trace(model, args, strict=False)
    print(f'{name}: traced ({time.time()-t0:.0f}s)', flush=True)
    inputs = [ct.TensorType(name=k, shape=v.shape, dtype=np.int32 if v.dtype == np.int64 else np.float32) for k, v in example.items()]
    ml = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name=n) for n in out_names], convert_to='mlprogram',
                    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
    path = f'{OUT}/{name}.mlpackage'; ml.save(path)
    print(f'{name}: converted and saved ({time.time()-t0:.0f}s)', flush=True)
    sess = ort.InferenceSession(f'{M}/{name}.onnx', providers=['CPUExecutionProvider'])
    ref = sess.run(out_names, example)
    check(name, ml, {k: (v.astype(np.int32) if v.dtype == np.int64 else v) for k, v in example.items()}, ref, out_names)
    return ml

# 1) text encoder (fixed 16-token prompt shape for the experiment)
ids = np.zeros((1, 16), np.int64); ids[0, :10] = [101, 1037, 2711, 5975, 2007, 1996, 2157, 2192, 1012, 102]
mask = (ids != 0).astype(np.int64); types = np.zeros((1, 16), np.int64)
convert_graph('text_encoder', {'input_ids': ids, 'attention_mask': mask, 'token_type_ids': types}, ['text_conditions'])

# 2) decoder
hyb = np.random.RandomState(0).randn(1, 20, 148).astype(np.float32) * 0.5
pad = np.zeros((1, 80), np.float32); pad[0, :40] = 1
convert_graph('decoder', {'hybrid_tokens': hyb, 'motion_pad_mask': pad, 'global_translation': np.zeros((1, 3), np.float32)},
              ['local_rotations', 'global_rotations', 'root_positions'])

# 3) denoiser
x = np.random.RandomState(1).randn(1, 20, 148).astype(np.float32)
hm = np.zeros((1, 80), np.float32); gm = np.zeros((1, 80), np.float32); gm[0, :40] = 1
htm = np.zeros((1, 20), np.float32); gtm = np.zeros((1, 20), np.float32); gtm[0, :10] = 1
text = np.random.RandomState(2).randn(1, 1, 2048).astype(np.float32) * 10
feeds = {'cfg_weight': np.array([2.0], np.float32), 'x': x, 'history_len': np.array([0], np.int64), 'generation_len': np.array([40], np.int64),
         'history_mask': hm, 'generation_mask': gm, 'history_token_mask': htm, 'generation_token_mask': gtm,
         'text_conditions': text, 'timestep': np.array([9], np.int64), 'first_heading_angle': np.array([0.0], np.float32)}
convert_graph('denoiser', feeds, ['pred_x0'])
print('ALL DONE', flush=True)
