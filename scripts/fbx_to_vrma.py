#!/usr/bin/env python3
"""Convert a Mixamo FBX clip into a .vrma (VRMC_vrm_animation 1.0).

Reproduces the pipeline used for the bundled speaking/talking clips:
    1. FBX2glTF v0.9.7 ``--binary`` turns the FBX into a .glb (nodes + one
       animation, no mesh). Mixamo rigs carry non-identity rest rotations;
       the in-app loader normalizes them (VRMRestTransform).
    2. The VRMC_vrm_animation humanoid bone map is injected by matching the
       ``mixamorig:*`` node names, and the result is written as ``.vrma``.

Usage:
    scripts/fbx_to_vrma.py clip.fbx NeuraLink/App/Resources/Animations/clip.vrma
    scripts/fbx_to_vrma.py clip.glb clip.vrma          # inject only
Options:
    --fbx2gltf PATH        FBX2glTF binary (else $FBX2GLTF, PATH, or the
                           ``fbx2gltf`` npm package: ``npm i fbx2gltf@0.9.7-p1``
                           and point at node_modules/fbx2gltf/bin/<OS>/FBX2glTF)
    --framerate RATE       bake24 (default, matches the shipped clips) | bake30 | bake60
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# VRM humanoid bone -> Mixamo node name (as in the shipped speaking.vrma).
MIXAMO_HUMAN_BONES = {
    "hips": "Hips", "spine": "Spine", "chest": "Spine1", "upperChest": "Spine2",
    "neck": "Neck", "head": "Head",
    "rightShoulder": "RightShoulder", "rightUpperArm": "RightArm",
    "rightLowerArm": "RightForeArm", "rightHand": "RightHand",
    "rightThumbMetacarpal": "RightHandThumb1", "rightThumbProximal": "RightHandThumb2",
    "rightThumbDistal": "RightHandThumb3",
    "rightIndexProximal": "RightHandIndex1", "rightIndexIntermediate": "RightHandIndex2",
    "rightIndexDistal": "RightHandIndex3",
    "rightMiddleProximal": "RightHandMiddle1", "rightMiddleIntermediate": "RightHandMiddle2",
    "rightMiddleDistal": "RightHandMiddle3",
    "rightRingProximal": "RightHandRing1", "rightRingIntermediate": "RightHandRing2",
    "rightRingDistal": "RightHandRing3",
    "rightLittleProximal": "RightHandPinky1", "rightLittleIntermediate": "RightHandPinky2",
    "rightLittleDistal": "RightHandPinky3",
    "leftShoulder": "LeftShoulder", "leftUpperArm": "LeftArm",
    "leftLowerArm": "LeftForeArm", "leftHand": "LeftHand",
    "leftThumbMetacarpal": "LeftHandThumb1", "leftThumbProximal": "LeftHandThumb2",
    "leftThumbDistal": "LeftHandThumb3",
    "leftIndexProximal": "LeftHandIndex1", "leftIndexIntermediate": "LeftHandIndex2",
    "leftIndexDistal": "LeftHandIndex3",
    "leftMiddleProximal": "LeftHandMiddle1", "leftMiddleIntermediate": "LeftHandMiddle2",
    "leftMiddleDistal": "LeftHandMiddle3",
    "leftRingProximal": "LeftHandRing1", "leftRingIntermediate": "LeftHandRing2",
    "leftRingDistal": "LeftHandRing3",
    "leftLittleProximal": "LeftHandPinky1", "leftLittleIntermediate": "LeftHandPinky2",
    "leftLittleDistal": "LeftHandPinky3",
    "rightUpperLeg": "RightUpLeg", "rightLowerLeg": "RightLeg",
    "rightFoot": "RightFoot", "rightToes": "RightToeBase",
    "leftUpperLeg": "LeftUpLeg", "leftLowerLeg": "LeftLeg",
    "leftFoot": "LeftFoot", "leftToes": "LeftToeBase",
}

# VRMC_vrm_animation-1.0 required bones; everything else is optional.
REQUIRED_BONES = {
    "hips", "spine", "head",
    "leftUpperArm", "leftLowerArm", "leftHand",
    "rightUpperArm", "rightLowerArm", "rightHand",
    "leftUpperLeg", "leftLowerLeg", "leftFoot",
    "rightUpperLeg", "rightLowerLeg", "rightFoot",
}

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942


def read_glb(path: Path) -> tuple[dict, bytes]:
    data = path.read_bytes()
    magic, version, _length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC or version != 2:
        raise SystemExit(f"{path}: not a glTF 2.0 binary")
    offset = 12
    doc: dict | None = None
    binary = b""
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        payload = data[offset + 8: offset + 8 + chunk_len]
        if chunk_type == CHUNK_JSON:
            doc = json.loads(payload.decode("utf-8"))
        elif chunk_type == CHUNK_BIN:
            binary = payload
        offset += 8 + chunk_len
    if doc is None:
        raise SystemExit(f"{path}: no JSON chunk")
    return doc, binary


def write_glb(path: Path, doc: dict, binary: bytes) -> None:
    json_bytes = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * (-len(json_bytes) % 4)
    bin_bytes = binary + b"\0" * (-len(binary) % 4)
    total = 12 + 8 + len(json_bytes) + (8 + len(bin_bytes) if bin_bytes else 0)
    with path.open("wb") as handle:
        handle.write(struct.pack("<III", GLB_MAGIC, 2, total))
        handle.write(struct.pack("<II", len(json_bytes), CHUNK_JSON))
        handle.write(json_bytes)
        if bin_bytes:
            handle.write(struct.pack("<II", len(bin_bytes), CHUNK_BIN))
            handle.write(bin_bytes)


def find_fbx2gltf(explicit: str | None) -> str:
    candidates = [explicit, os.environ.get("FBX2GLTF"), shutil.which("FBX2glTF")]
    system = platform.system()
    for root in (Path.cwd(), Path(__file__).resolve().parent.parent):
        candidates.append(str(root / "node_modules" / "fbx2gltf" / "bin" / system / "FBX2glTF"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit(
        "FBX2glTF not found. Pass --fbx2gltf, set $FBX2GLTF, or install the npm package:\n"
        "    npm i fbx2gltf@0.9.7-p1   # binary at node_modules/fbx2gltf/bin/<OS>/FBX2glTF"
    )


def run_fbx2gltf(binary: str, fbx: Path, framerate: str, workdir: Path) -> Path:
    out_stem = workdir / fbx.stem
    cmd = [binary, "--binary", "--anim-framerate", framerate,
           "--input", str(fbx), "--output", str(out_stem)]
    print("$", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    glb = out_stem.with_suffix(".glb")
    if result.returncode != 0 or not glb.is_file():
        raise SystemExit(f"FBX2glTF failed (exit {result.returncode})")
    return glb


def inject_humanoid(doc: dict) -> dict[str, int]:
    nodes = doc.get("nodes", [])
    by_name: dict[str, int] = {}
    for index, node in enumerate(nodes):
        name = node.get("name")
        if not name:
            continue
        by_name.setdefault(name, index)
        # Some exports drop the namespace ("mixamorig:Hips" -> "Hips").
        by_name.setdefault(name.split(":")[-1], index)

    human_bones: dict[str, int] = {}
    for bone, mixamo in MIXAMO_HUMAN_BONES.items():
        index = by_name.get(f"mixamorig:{mixamo}", by_name.get(mixamo))
        if index is not None:
            human_bones[bone] = index

    missing_required = sorted(REQUIRED_BONES - human_bones.keys())
    if missing_required:
        raise SystemExit(f"required humanoid bones not found in the rig: {missing_required}")
    missing_optional = sorted(MIXAMO_HUMAN_BONES.keys() - human_bones.keys())
    if missing_optional:
        print(f"warning: optional bones not in the rig: {missing_optional}")

    # The shipped clips carry no identity scales; drop them so the file has
    # the same shape (and the loader never has to multiply by 1).
    for node in nodes:
        if node.get("scale") == [1.0, 1.0, 1.0]:
            del node["scale"]

    used = doc.setdefault("extensionsUsed", [])
    if "VRMC_vrm_animation" not in used:
        used.append("VRMC_vrm_animation")
    doc.setdefault("extensions", {})["VRMC_vrm_animation"] = {
        "specVersion": "1.0",
        "humanoid": {"humanBones": {bone: {"node": index} for bone, index in human_bones.items()}},
    }
    return human_bones


def summarize(doc: dict, human_bones: dict[str, int], out: Path) -> None:
    animations = doc.get("animations", [])
    channels = sum(len(a.get("channels", [])) for a in animations)
    duration = 0.0
    for animation in animations:
        for sampler in animation.get("samplers", []):
            accessor = doc["accessors"][sampler["input"]]
            duration = max(duration, float((accessor.get("max") or [0])[0]))
    print(f"wrote {out} ({out.stat().st_size} bytes): {len(doc.get('nodes', []))} nodes, "
          f"{len(animations)} animation(s), {channels} channels, {duration:.2f} s, "
          f"{len(human_bones)} humanoid bones mapped")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help=".fbx (converted) or .glb (inject only)")
    parser.add_argument("output", type=Path, help="destination .vrma")
    parser.add_argument("--fbx2gltf", help="path to the FBX2glTF binary")
    parser.add_argument("--framerate", default="bake24", choices=["bake24", "bake30", "bake60"])
    args = parser.parse_args()

    if not args.input.is_file():
        raise SystemExit(f"{args.input}: no such file")
    if args.output.suffix.lower() != ".vrma":
        raise SystemExit("output must end in .vrma")

    with tempfile.TemporaryDirectory(prefix="fbx_to_vrma_") as tmp:
        if args.input.suffix.lower() == ".fbx":
            glb = run_fbx2gltf(find_fbx2gltf(args.fbx2gltf), args.input, args.framerate, Path(tmp))
        else:
            glb = args.input
        doc, binary = read_glb(glb)
        if not doc.get("animations"):
            raise SystemExit(f"{glb}: contains no animation")
        human_bones = inject_humanoid(doc)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        write_glb(args.output, doc, binary)
        summarize(doc, human_bones, args.output)


if __name__ == "__main__":
    main()
