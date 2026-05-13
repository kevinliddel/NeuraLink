#!/usr/bin/env python3
"""
Generate a motion database from Three.js KeyframeTrack JSON files.

Default output is a compact binary you can ship in `NeuraLink/Models/motion_db.bin`
and load at runtime (fast builds).

You can also generate a huge `.cpp` file, but compilation will be very slow.

Input:  database_frames/*.json (repo root)
"""

from __future__ import annotations

import base64
import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple
import argparse


@dataclass
class PoseSequence:
    name: str
    times: List[float]
    bone_quats: Dict[str, List[Tuple[float, float, float, float]]]
    category: str


def _decode_f32_b64(s: str) -> List[float]:
    b = base64.b64decode(s)
    if len(b) % 4 != 0:
        raise ValueError("float32 byte count not divisible by 4")
    n = len(b) // 4
    # little-endian float32
    return list(struct.unpack("<%df" % n, b))


def load_sequence(p: Path) -> PoseSequence:
    d = json.loads(p.read_text())
    tracks = d.get("tracks", [])
    name = d.get("name") or p.stem
    category = categorize_name(name)

    times: List[float] = []
    bone_quats: Dict[str, List[Tuple[float, float, float, float]]] = {}

    for tr in tracks:
        tr_name = tr["name"]
        tr_type = tr["type"]
        if tr_type != "QuaternionKeyframeTrack":
            continue
        if not tr_name.endswith(".quaternion"):
            continue
        bone = tr_name[: -len(".quaternion")]
        tr_times = _decode_f32_b64(tr["timesB64"])
        tr_vals = _decode_f32_b64(tr["valuesB64"])
        if not times:
            times = tr_times
        # Some exports have slightly different time arrays for finger bones, etc.
        # We skip those tracks instead of rejecting the whole clip.
        if len(tr_times) != len(times):
            continue
        if len(tr_vals) != len(tr_times) * 4:
            raise ValueError(f"quat length mismatch in {p.name}:{tr_name}")
        quats: List[Tuple[float, float, float, float]] = []
        for i in range(0, len(tr_vals), 4):
            quats.append((tr_vals[i], tr_vals[i + 1], tr_vals[i + 2], tr_vals[i + 3]))
        bone_quats[bone] = quats

    if not times or not bone_quats:
        raise ValueError(f"no usable quaternion tracks in {p.name}")

    return PoseSequence(name=name, times=times, bone_quats=bone_quats, category=category)


def categorize_name(name: str) -> str:
    n = name.strip().lower().replace(" ", "_")
    if n.startswith("talking") or "talk" in n:
        return "talking"
    if n in ("idle", "waiting", "relaxed", "neutral", "model_pose"):
        return "idle"
    if "angry" in n:
        return "angry"
    if "sad" in n:
        return "sad"
    if "happy" in n:
        return "happy"
    if "think" in n:
        return "thinking"
    if "look" in n:
        return "looking"
    if "stretch" in n:
        return "stretching"
    return "misc"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["bin", "cpp"], default="bin")
    ap.add_argument("--out", default=None, help="Override output path")
    ap.add_argument("--vrm0", action="store_true", help="Apply VRM0 quaternion conversion (-x,-z) when writing frames")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[1]
    src_dir = (repo / "database_frames") if (repo / "database_frames").is_dir() else None
    if src_dir is None:
        # Allow running from within the app folder layout too.
        if (repo / "NeuraLink" / "database_frames").is_dir():
            src_dir = repo / "NeuraLink" / "database_frames"
    if src_dir is None:
        raise SystemExit("Could not find database_frames/. Place it at repo root or NeuraLink/database_frames.")

    if args.format == "bin":
        default_out = repo / "NeuraLink" / "Models" / ("motion_db_vrm0.bin" if args.vrm0 else "motion_db.bin")
    else:
        default_out = repo / "NeuraLink" / "VRM" / "Animation" / "Core" / "vrm_motion_dataset.generated.cpp"
    out_path = Path(args.out) if args.out else default_out
    out_path.parent.mkdir(parents=True, exist_ok=True)

    json_files = sorted(src_dir.glob("*.json"))
    if not json_files:
        raise SystemExit(f"No .json files found in {src_dir}")

    sequences: List[PoseSequence] = []
    for f in json_files:
        try:
            sequences.append(load_sequence(f))
        except Exception as e:
            print(f"[WARN] Skipping {f.name}: {e}")

    if not sequences:
        raise SystemExit("No sequences loaded.")

    # Build a stable bone list (union of all bones, sorted).
    bones = sorted({b for s in sequences for b in s.bone_quats.keys()})

    # Flatten frames: for each sequence, for each frame, write quats for all bones (missing => identity).
    # NOTE: This will generate a *very large* translation unit if you include thousands of frames.
    # Consider limiting to a curated subset or adding quantization/compression later.
    frames: List[List[Tuple[float, float, float, float]]] = []
    frame_category: List[str] = []
    for s in sequences:
        n = len(s.times)
        for fi in range(n):
            row: List[Tuple[float, float, float, float]] = []
            for b in bones:
                q = (0.0, 0.0, 0.0, 1.0)
                if b in s.bone_quats and fi < len(s.bone_quats[b]):
                    q = s.bone_quats[b][fi]
                row.append(q)
            frames.append(row)
            frame_category.append(s.category)

    if args.format == "bin":
        # Binary format:
        #   magic[8] = "NMMDBIN\0"
        #   u32 version = 2
        #   u32 boneCount
        #   u32 frameCount
        #   bones: repeated { u16 nameLen, bytes[nameLen] }
        #   categories: repeated { u16 nameLen, bytes[nameLen] } unique category table
        #   frames: repeated { u16 categoryIndex, boneCount * quat(float32x4 LE) }
        # Root translation/features are omitted for now.
        magic = b"NMMDBIN\x00"
        version = 2
        bone_count = len(bones)
        frame_count = len(frames)

        categories = sorted(set(frame_category))
        cat_index = {c: i for i, c in enumerate(categories)}

        with out_path.open("wb") as fp:
            fp.write(magic)
            fp.write(struct.pack("<I", version))
            fp.write(struct.pack("<I", bone_count))
            fp.write(struct.pack("<I", frame_count))
            for b in bones:
                raw = b.encode("utf-8")
                if len(raw) > 65535:
                    raise SystemExit(f"Bone name too long: {b}")
                fp.write(struct.pack("<H", len(raw)))
                fp.write(raw)
            fp.write(struct.pack("<I", len(categories)))
            for c in categories:
                raw = c.encode("utf-8")
                fp.write(struct.pack("<H", len(raw)))
                fp.write(raw)
            for ci, row in zip(frame_category, frames):
                fp.write(struct.pack("<H", cat_index[ci]))
                for (x, y, z, w) in row:
                    if args.vrm0:
                        x, z = -x, -z
                    fp.write(struct.pack("<ffff", x, y, z, w))

        print(f"Wrote {out_path} (bones={bone_count} frames={frame_count} sequences={len(sequences)})")
        return

    with out_path.open("w") as fp:
        fp.write("// Auto-generated by scripts/generate_vrm_motion_dataset_cpp.py\n")
        fp.write('#include "vrm_motion_core.hpp"\n')
        fp.write("#include <cstddef>\n")
        fp.write("#include <string>\n")
        fp.write("\nnamespace NeuraLink {\n")
        fp.write("bool loadGeneratedDatabase(MotionDatabase& db) {\n")
        fp.write("    db.poses.clear();\n")
        fp.write("    db.features.clear();\n")
        fp.write(f"    db.poses.reserve({len(frames)});\n")
        fp.write(f"    db.features.reserve({len(frames)});\n")
        fp.write("\n")
        fp.write("    static const char* kBones[] = {\n")
        for b in bones:
            fp.write(f'        "{b}",\n')
        fp.write("    };\n")
        fp.write(f"    constexpr std::size_t kBoneCount = {len(bones)};\n\n")
        fp.write("    // NOTE: Features are currently placeholders. Replace with meaningful\n")
        fp.write("    // velocity/contact/etc. features if you train a model.\n")
        fp.write(f"    constexpr std::size_t kFrameCount = {len(frames)};\n")
        fp.write("    for (std::size_t i = 0; i < kFrameCount; ++i) {\n")
        fp.write("        HumanoidPose pose;\n")
        fp.write("        pose.rootTranslation = {0,0,0};\n")
        fp.write("        for (std::size_t bi = 0; bi < kBoneCount; ++bi) {\n")
        fp.write("            BoneTransform t;\n")
        fp.write("            t.translation = {0,0,0};\n")
        fp.write("            // Quaternion values injected below.\n")
        fp.write("            pose.bones[std::string(kBones[bi])] = t;\n")
        fp.write("        }\n")
        fp.write("        db.poses.push_back(pose);\n")
        fp.write("        MotionFeature f; f.data = {0.5f, 7.0f};\n")
        fp.write("        db.features.push_back(f);\n")
        fp.write("    }\n")
        fp.write("\n    // Fill rotations\n")
        fp.write("    std::size_t frameIndex = 0;\n")
        def fmt_f(x: float) -> str:
            # C++ float literal rules: `1f` is invalid, must be `1.0f`.
            # Also sanitize NaN/Inf.
            if x != x or x == float("inf") or x == float("-inf"):
                x = 0.0
            if x == 0.0:
                x = 0.0  # normalize -0.0
            s = f"{x:.9g}"
            if s in ("-0", "0"):
                s = "0.0"
            if ("." not in s) and ("e" not in s) and ("E" not in s):
                s = s + ".0"
            return s + "f"
        for row in frames:
            fp.write("    {\n")
            fp.write("        HumanoidPose& p = db.poses[frameIndex];\n")
            for bi, q in enumerate(row):
                fp.write(
                    f'        p.bones[std::string(kBones[{bi}])].rotation = '
                    f"{{{fmt_f(q[0])},{fmt_f(q[1])},{fmt_f(q[2])},{fmt_f(q[3])}}};\n"
                )
            fp.write("        frameIndex++;\n")
            fp.write("    }\n")
        fp.write("    return true;\n")
        fp.write("}\n\n} // namespace NeuraLink\n")

    print(f"Wrote {out_path} (bones={len(bones)} frames={len(frames)} sequences={len(sequences)})")
    print("Tip: compiling this file will be slow; prefer `--format bin`.")


if __name__ == "__main__":
    main()
