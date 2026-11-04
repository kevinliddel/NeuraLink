"""Retarget ARDY cskel27 clips (.npz from ardy_mini_batch.py) to VRMA files.

Own implementation from the VRMC_vrm_animation-1.0 spec: a 20-bone T-pose rest
skeleton with identity rotations (+Z forward, +X left, Y up — the VRM 1.0
convention, which is also ARDY's identity-pose convention), one LINEAR
rotation channel per bone and a translation channel for the hips.

usage: python -I scripts/cskel_to_vrma.py --in DIR --out DIR [--arm-spread 6] [--pin-root] [--fps-div 1]
"""
import argparse
import json
import struct
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation as R

CORE_JOINTS = [
    "Hips", "Spine", "Spine1", "Spine2", "Spine3", "Neck", "Head",
    "RightShoulder", "RightArm", "RightForeArm", "RightHand", "RightHandEnd", "RightHandThumb1",
    "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "LeftHandEnd", "LeftHandThumb1",
    "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase",
    "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
]
CORE = {n: i for i, n in enumerate(CORE_JOINTS)}

# VRM bone -> (core joint, VRM parent). Spine2 is folded into upperChest.
VRM_MAP = {
    "hips": ("Hips", None),
    "spine": ("Spine", "hips"),
    "chest": ("Spine1", "spine"),
    "upperChest": ("Spine3", "chest"),
    "neck": ("Neck", "upperChest"),
    "head": ("Head", "neck"),
    "leftShoulder": ("LeftShoulder", "upperChest"),
    "leftUpperArm": ("LeftArm", "leftShoulder"),
    "leftLowerArm": ("LeftForeArm", "leftUpperArm"),
    "leftHand": ("LeftHand", "leftLowerArm"),
    "rightShoulder": ("RightShoulder", "upperChest"),
    "rightUpperArm": ("RightArm", "rightShoulder"),
    "rightLowerArm": ("RightForeArm", "rightUpperArm"),
    "rightHand": ("RightHand", "rightLowerArm"),
    "leftUpperLeg": ("LeftUpLeg", "hips"),
    "leftLowerLeg": ("LeftLeg", "leftUpperLeg"),
    "leftFoot": ("LeftFoot", "leftLowerLeg"),
    "rightUpperLeg": ("RightUpLeg", "hips"),
    "rightLowerLeg": ("RightLeg", "rightUpperLeg"),
    "rightFoot": ("RightFoot", "rightLowerLeg"),
}

# Rest skeleton written into the VRMA (T-pose, metres). Hips at 0.9 m.
SKELETON = {
    "hips": (None, (0, 0.9, 0)),
    "spine": ("hips", (0, 0.08, 0)),
    "chest": ("spine", (0, 0.12, 0)),
    "upperChest": ("chest", (0, 0.12, 0)),
    "neck": ("upperChest", (0, 0.13, 0)),
    "head": ("neck", (0, 0.08, 0)),
    "leftShoulder": ("upperChest", (0.03, 0.10, 0)),
    "leftUpperArm": ("leftShoulder", (0.06, 0, 0)),
    "leftLowerArm": ("leftUpperArm", (0.24, 0, 0)),
    "leftHand": ("leftLowerArm", (0.22, 0, 0)),
    "rightShoulder": ("upperChest", (-0.03, 0.10, 0)),
    "rightUpperArm": ("rightShoulder", (-0.06, 0, 0)),
    "rightLowerArm": ("rightUpperArm", (-0.24, 0, 0)),
    "rightHand": ("rightLowerArm", (-0.22, 0, 0)),
    "leftUpperLeg": ("hips", (0.09, -0.02, 0)),
    "leftLowerLeg": ("leftUpperLeg", (0, -0.38, 0)),
    "leftFoot": ("leftLowerLeg", (0, -0.42, 0)),
    "rightUpperLeg": ("hips", (-0.09, -0.02, 0)),
    "rightLowerLeg": ("rightUpperLeg", (0, -0.38, 0)),
    "rightFoot": ("rightLowerLeg", (0, -0.42, 0)),
}
HIPS_HEIGHT = 0.9
APP_FOOT_HEIGHT = 0.08           # rest foot height of SKELETON (0.9 - 0.02 - 0.38 - 0.42)
CORE_REST_HIPS_HEIGHT = 0.896    # cskel27 neutral: hips -> foot
CORE_REST_FOOT_HEIGHT = 0.07     # cskel27 standing: foot above floor
LEG_SCALE = (HIPS_HEIGHT - APP_FOOT_HEIGHT) / CORE_REST_HIPS_HEIGHT
ARM_SPREAD_SIGN = {"leftUpperArm": 1.0, "rightUpperArm": -1.0}


def rz(deg):
    a = np.deg2rad(deg)
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def retarget(glob, root, fps, arm_spread=0.0, pin_root=False, fps_div=1):
    """glob [T,27,3,3] global rotation matrices, root [T,3] -> per-bone quats + hips offsets."""
    frames = list(range(0, glob.shape[0], fps_div))
    times = np.array([f / fps for f in frames], np.float32)
    quats = {}
    for bone, (core, parent) in VRM_MAP.items():
        qs = []
        prev = None
        for f in frames:
            rg = glob[f, CORE[core]]
            rl = rg if parent is None else glob[f, CORE[VRM_MAP[parent][0]]].T @ rg
            if arm_spread and bone in ARM_SPREAD_SIGN:
                rl = rz(ARM_SPREAD_SIGN[bone] * arm_spread) @ rl
            q = R.from_matrix(rl).as_quat()  # x, y, z, w
            if prev is not None and np.dot(q, prev) < 0:
                q = -q
            prev = q
            qs.append(q)
        quats[bone] = np.array(qs, np.float32)
    hips = []
    for f in frames:
        p = root[f] * LEG_SCALE
        y = (root[f][1] - CORE_REST_FOOT_HEIGHT) * LEG_SCALE + APP_FOOT_HEIGHT
        x, z = (0.0, 0.0) if pin_root else (p[0], p[2])
        hips.append((x, y - HIPS_HEIGHT, z))
    return times, quats, np.array(hips, np.float32)


def rest_world(bone):
    p = np.zeros(3)
    while bone is not None:
        parent, t = SKELETON[bone]
        p = p + np.array(t)
        bone = parent
    return p


def build_vrma(times, quats, hips_offsets, name):
    bones = list(SKELETON.keys())
    index = {b: i for i, b in enumerate(bones)}
    nodes = []
    for b in bones:
        nodes.append({"name": f"J_{b}", "translation": list(map(float, SKELETON[b][1]))})
    for b in bones:
        parent = SKELETON[b][0]
        if parent is not None:
            nodes[index[parent]].setdefault("children", []).append(index[b])
    bin_parts = []
    buffer_views = []
    accessors = []
    offset = 0

    def add(array, component_type, acc_type, with_minmax=False):
        nonlocal offset
        data = np.ascontiguousarray(array).tobytes()
        pad = (-len(data)) % 4
        bin_parts.append(data + b"\0" * pad)
        buffer_views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data)})
        acc = {"bufferView": len(buffer_views) - 1, "componentType": component_type, "count": int(array.shape[0]), "type": acc_type}
        if with_minmax:
            acc["min"] = [float(array.min())]
            acc["max"] = [float(array.max())]
        accessors.append(acc)
        offset += len(data) + pad
        return len(accessors) - 1

    time_acc = add(times.astype(np.float32), 5126, "SCALAR", True)
    samplers, channels = [], []
    for b in bones:
        out = add(quats[b].astype(np.float32), 5126, "VEC4")
        samplers.append({"input": time_acc, "output": out, "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": index[b], "path": "rotation"}})
    hips_world = rest_world("hips")
    hips_pos = (hips_offsets + hips_world.astype(np.float32)).astype(np.float32)
    out = add(hips_pos, 5126, "VEC3")
    samplers.append({"input": time_acc, "output": out, "interpolation": "LINEAR"})
    channels.append({"sampler": len(samplers) - 1, "target": {"node": index["hips"], "path": "translation"}})
    human_bones = {b: {"node": index[b]} for b in bones}
    gltf = {
        "asset": {"version": "2.0", "generator": "NeuraLink cskel_to_vrma (Phase 0)"},
        "extensionsUsed": ["VRMC_vrm_animation"],
        "extensions": {"VRMC_vrm_animation": {"specVersion": "1.0", "humanoid": {"humanBones": human_bones}}},
        "scene": 0,
        "scenes": [{"nodes": [index["hips"]]}],
        "nodes": nodes,
        "animations": [{"name": name, "samplers": samplers, "channels": channels}],
        "buffers": [{"byteLength": offset}],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * ((-len(json_bytes)) % 4)
    bin_bytes = b"".join(bin_parts)
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    return b"".join([
        struct.pack("<4sII", b"glTF", 2, total),
        struct.pack("<II", len(json_bytes), 0x4E4F534A), json_bytes,
        struct.pack("<II", len(bin_bytes), 0x004E4942), bin_bytes,
    ])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--arm-spread", type=float, default=6.0)
    ap.add_argument("--pin-root", action="store_true")
    ap.add_argument("--fps-div", type=int, default=1)
    args = ap.parse_args()
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    count = 0
    for npz in sorted(Path(args.inp).glob("*.npz")):
        d = np.load(npz, allow_pickle=False)
        times, quats, hips = retarget(d["global_rot_mats"], d["root_positions"], float(d["fps"]), args.arm_spread, args.pin_root, args.fps_div)
        glb = build_vrma(times, quats, hips, npz.stem)
        (out / f"{npz.stem}.vrma").write_bytes(glb)
        count += 1
    print(f"wrote {count} clips to {out}")


if __name__ == "__main__":
    main()
