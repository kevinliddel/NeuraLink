#!/usr/bin/env python3
"""Cut VRoid VRM/GLB models into standalone part files for the customization
parts library (docs/CHARACTER_CUSTOMIZATION.md).

For every input model it writes up to three minimal VRMs next to each other:

    <stem>__hair.vrm     hair + back-hair primitives, hair bones, springs
    <stem>__outfit.vrm   body skin + every garment (the whole look)
    <stem>__tops.vrm     top / one-piece only
    <stem>__bottoms.vrm  bottoms only
    <stem>__shoes.vrm    shoes only
    <stem>__eyes.vrm     iris/white/highlight (+ eyeline, lashes) — a texture donor

Each part keeps the FULL skeleton (node indices unchanged, so skins, humanoid
and spring-bone references stay valid), only the primitives it needs (vertices
re-indexed to the referenced subset), only the materials/textures it uses, and
the VRM extension trimmed to what still applies. Image bytes and primitive
index counts are copied verbatim so the app's part fingerprints (and therefore
the pre-rendered thumbnails) are identical to the original model's.

Usage:
    python3 scripts/extract_parts.py <input dir> <output dir>
"""

import json
import os
import struct
import sys

import numpy as np

COMPONENT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

HAIR = {"hair", "hairBack"}
OUTFIT = {"bodySkin", "tops", "bottoms", "shoes", "onepiece", "accessory"}
TOPS = {"tops", "onepiece"}
BOTTOMS = {"bottoms"}
SHOES = {"shoes"}
# Eyeline and lashes come along so the picture reads as a pair of eyes;
# only the four eye slots are ever borrowed as textures.
EYES = {"eyeIris", "eyeWhite", "eyeHighlight", "eyeExtra", "eyeline", "eyelash"}
# "outfit" is the whole look (skin included, so VRoid's carved-away geometry
# stays consistent); the single garments let one piece be swapped on its own.
PARTS = {"hair": HAIR, "outfit": OUTFIT, "tops": TOPS, "bottoms": BOTTOMS, "shoes": SHOES, "eyes": EYES}


# ---------------------------------------------------------------- slot rules (mirror VRoidMaterialSlot.swift)

def is_generic(name):
    lower = (name or "").lower()
    return lower == "" or lower.startswith("vrm/") or lower in ("standard", "material")


def classify(name):
    if not name:
        return "other"
    cleaned = name.replace(" (Instance)", "")
    tokens = {t.lower() for t in cleaned.replace("-", "_").replace(" ", "_").split("_") if t}
    by_token = [
        ("facemouth", "mouth"), ("eyeiris", "eyeIris"), ("eyewhite", "eyeWhite"), ("eyehighlight", "eyeHighlight"),
        ("eyeextra", "eyeExtra"), ("facebrow", "brow"), ("faceeyeline", "eyeline"), ("faceeyelash", "eyelash"),
        ("hairback", "hairBack"), ("hair", "hair"), ("face", "faceSkin"), ("body", "bodySkin"), ("tops", "tops"),
        ("bottoms", "bottoms"), ("shoes", "shoes"), ("onepiece", "onepiece"), ("onepice", "onepiece"),
    ]
    for token, slot in by_token:
        if token in tokens:
            return slot
    if cleaned.lower().startswith("accessory") or "accessory" in tokens:
        return "accessory"
    lower = cleaned.lower()
    by_substring = [
        ("iris", "eyeIris"), ("highlight", "eyeHighlight"), ("brow", "brow"), ("lash", "eyelash"),
        ("eyeline", "eyeline"), ("mouth", "mouth"), ("lip", "mouth"), ("eye", "eyeWhite"), ("hair", "hair"),
        ("face", "faceSkin"), ("body", "bodySkin"), ("skin", "bodySkin"), ("shoe", "shoes"), ("boot", "shoes"),
        ("skirt", "bottoms"), ("pants", "bottoms"), ("shorts", "bottoms"), ("cloth", "tops"), ("shirt", "tops"),
        ("dress", "tops"),
    ]
    for needle, slot in by_substring:
        if needle in lower:
            return slot
    return "other"


CANONICAL = {
    "faceSkin": "NL_Face_00_SKIN", "bodySkin": "NL_Body_00_SKIN", "eyeIris": "NL_EyeIris_00_EYE",
    "eyeWhite": "NL_EyeWhite_00_EYE", "eyeHighlight": "NL_EyeHighlight_00_EYE", "eyeExtra": "NL_EyeExtra_00_EYE",
    "brow": "NL_FaceBrow_00_FACE", "eyeline": "NL_FaceEyeline_00_FACE", "eyelash": "NL_FaceEyelash_00_FACE",
    "mouth": "NL_FaceMouth_00_FACE", "hairBack": "NL_HairBack_00_HAIR", "hair": "NL_Hair_00_HAIR",
    "tops": "NL_Tops_01_CLOTH", "bottoms": "NL_Bottoms_01_CLOTH", "shoes": "NL_Shoes_01_CLOTH",
    "onepiece": "NL_Onepiece_00_CLOTH", "accessory": "NL_Accessory_01_CLOTH",
}

# Texture slots whose image name most reliably names the part.
MAIN_TEXTURE_KEYS = ("_MainTex", "_ShadeTexture")


def image_names(g, index, vrm0_prop):
    """Names of the images a material references, main texture first."""
    refs = []
    base = (g["materials"][index].get("pbrMetallicRoughness", {}).get("baseColorTexture") or {}).get("index")
    if base is not None:
        refs.append(base)
    props = (vrm0_prop or {}).get("textureProperties") or {}
    refs += [props[k] for k in MAIN_TEXTURE_KEYS if k in props]
    refs += [t for k, t in sorted(props.items()) if k not in MAIN_TEXTURE_KEYS]
    names = []
    for t in refs:
        if not isinstance(t, int) or t >= len(g.get("textures", [])):
            continue
        source = g["textures"][t].get("source")
        if source is None or source >= len(g.get("images", [])):
            continue
        name = g["images"][source].get("name") or ""
        if name:
            names.append(name)
    return names


def vertical_extents(g, binary):
    """(low, high) Y of every material's geometry, plus the model's own height."""
    if binary is None:
        return {}, 0.0
    spans, lo_all, hi_all = {}, float("inf"), float("-inf")
    for mesh in g.get("meshes", []):
        for prim in mesh["primitives"]:
            index = prim.get("material")
            accessor = prim.get("attributes", {}).get("POSITION")
            if index is None or accessor is None:
                continue
            try:
                positions = read_accessor(g, binary, accessor)[0]
                # VRoid merges a whole body into one vertex array and slices
                # it per primitive with indices, so the accessor alone spans
                # the entire model. Only the referenced vertices are ours.
                if prim.get("indices") is not None:
                    used = np.unique(read_accessor(g, binary, prim["indices"])[0])
                    used = used[used < len(positions)]
                    positions = positions[used]
            except Exception:
                continue
            if not len(positions):
                continue
            low, high = float(positions[:, 1].min()), float(positions[:, 1].max())
            previous = spans.get(index)
            spans[index] = (min(previous[0], low), max(previous[1], high)) if previous else (low, high)
            lo_all, hi_all = min(lo_all, low), max(hi_all, high)
    return spans, (hi_all - lo_all if hi_all > lo_all else 0.0)


def slot_bounds(g, binary, slots, wanted):
    """Size of the geometry drawn with `wanted` slots, or None."""
    if binary is None:
        return None
    lo = np.array([np.inf] * 3)
    hi = np.array([-np.inf] * 3)
    for mesh in g.get("meshes", []):
        for prim in mesh["primitives"]:
            if slots.get(prim.get("material")) not in wanted:
                continue
            accessor = prim.get("attributes", {}).get("POSITION")
            if accessor is None:
                continue
            try:
                positions = read_accessor(g, binary, accessor)[0]
                if prim.get("indices") is not None:
                    used = np.unique(read_accessor(g, binary, prim["indices"])[0])
                    positions = positions[used[used < len(positions)]]
            except Exception:
                continue
            if not len(positions):
                continue
            lo = np.minimum(lo, positions.min(axis=0))
            hi = np.maximum(hi, positions.max(axis=0))
    return None if not np.isfinite(lo).all() else [float(v) for v in (hi - lo)]


def garment_by_band(extent, height, floor):
    """Which garment a nameless clothing material is, from where it sits.

    VRoid lays a body mesh out the same way whatever it calls the pieces:
    shoes at the ankles, bottoms around the hips and legs, tops above the
    waist. That is enough to tell an unnamed shirt from unnamed trousers.
    """
    if extent is None or height <= 0:
        return "tops"
    low, high = (extent[0] - floor) / height, (extent[1] - floor) / height
    if high <= 0.20:
        return "shoes"
    if (low + high) / 2 < 0.5:
        return "bottoms"
    return "tops"


def material_slots(g, binary=None):
    """Slot per material index.

    Falls back, in order, to: the VRM 0.x material-property name, the names
    of the images the material samples (VRoid writes `F00_000_Body_00_nml`
    even when every material is called "VRM/MToon"), an exclusively-hair
    mesh name, and finally "anything else on a body mesh whose skin we DID
    identify is clothing" — which is how VRoid builds that mesh.
    """
    materials = g.get("materials", [])
    vrm0 = g.get("extensions", {}).get("VRM", {}).get("materialProperties", [])
    users = {}
    for mesh in g.get("meshes", []):
        for prim in mesh["primitives"]:
            users.setdefault(prim.get("material"), set()).add((mesh.get("name") or "").lower())

    slots = {}
    for i, material in enumerate(materials):
        prop = vrm0[i] if i < len(vrm0) else None
        name = material.get("name")
        if is_generic(name) and prop and not is_generic(prop.get("name")):
            name = prop["name"]
        slot = classify(name) if not is_generic(name) else "other"
        if slot == "other":
            for image in image_names(g, i, prop):
                candidate = classify(image)
                if candidate != "other":
                    slot = candidate
                    break
        if slot == "other":
            mesh_names = users.get(i, set())
            if mesh_names and all("hair" in m for m in mesh_names):
                slot = "hair"
        slots[i] = slot

    # Unidentified materials on a body mesh that has a known skin are
    # clothes; which garment they are comes from the band they occupy.
    body_meshes = {m for i, s in slots.items() if s == "bodySkin" for m in users.get(i, set())}
    nameless = [i for i, s in slots.items() if s == "other" and users.get(i) and users[i] <= body_meshes]
    if nameless:
        spans, height = vertical_extents(g, binary)
        floor = min((v[0] for v in spans.values()), default=0.0)
        for i in nameless:
            slots[i] = garment_by_band(spans.get(i), height, floor)
    return slots


# ---------------------------------------------------------------- GLB I/O

def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, _, _ = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, f"{path}: not a GLB"
    json_len, json_type = struct.unpack_from("<II", data, 12)
    assert json_type == 0x4E4F534A
    g = json.loads(data[20:20 + json_len])
    bin_off = 20 + json_len
    bin_len, bin_type = struct.unpack_from("<II", data, bin_off)
    assert bin_type == 0x004E4942
    return g, data[bin_off + 8:bin_off + 8 + bin_len]


def write_glb(path, g, binary):
    payload = json.dumps(g, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    payload += b" " * ((4 - len(payload) % 4) % 4)
    binary += b"\0" * ((4 - len(binary) % 4) % 4)
    total = 12 + 8 + len(payload) + 8 + len(binary)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(payload), 0x4E4F534A))
        f.write(payload)
        f.write(struct.pack("<II", len(binary), 0x004E4942))
        f.write(binary)


def read_accessor(g, binary, index):
    acc = g["accessors"][index]
    view = g["bufferViews"][acc["bufferView"]]
    n = COUNT[acc["type"]]
    dtype = np.dtype(COMPONENT[acc["componentType"]])
    stride = view.get("byteStride") or n * dtype.itemsize
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = np.empty((acc["count"], n), dtype=dtype)
    for k in range(acc["count"]):
        out[k] = np.frombuffer(binary, dtype=dtype, count=n, offset=base + k * stride)
    return out, acc


class Builder:
    """Accumulates a fresh binary chunk + bufferViews/accessors."""

    def __init__(self):
        self.chunks = []
        self.length = 0
        self.views = []
        self.accessors = []

    def add_bytes(self, blob, target=None):
        pad = (4 - self.length % 4) % 4
        if pad:
            self.chunks.append(b"\0" * pad)
            self.length += pad
        view = {"buffer": 0, "byteOffset": self.length, "byteLength": len(blob)}
        if target:
            view["target"] = target
        self.views.append(view)
        self.chunks.append(blob)
        self.length += len(blob)
        return len(self.views) - 1

    def add_array(self, array, acc_type, component_type, target=None, normalized=False, with_bounds=False):
        array = np.ascontiguousarray(array, dtype=COMPONENT[component_type])
        view = self.add_bytes(array.tobytes(), target)
        acc = {"bufferView": view, "componentType": component_type, "count": int(array.shape[0]), "type": acc_type}
        if normalized:
            acc["normalized"] = True
        if with_bounds and array.size:
            acc["min"] = [float(v) for v in array.min(axis=0)]
            acc["max"] = [float(v) for v in array.max(axis=0)]
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def binary(self):
        return b"".join(self.chunks)


# ---------------------------------------------------------------- texture references

def texture_refs(material, vrm0_prop):
    refs = set()
    pbr = material.get("pbrMetallicRoughness", {})
    for info in (pbr.get("baseColorTexture"), pbr.get("metallicRoughnessTexture"), material.get("normalTexture"),
                 material.get("emissiveTexture"), material.get("occlusionTexture")):
        if info and "index" in info:
            refs.add(info["index"])
    for ext in material.get("extensions", {}).values():
        if isinstance(ext, dict):
            for key, value in ext.items():
                if key.endswith("Texture") and isinstance(value, dict) and "index" in value:
                    refs.add(value["index"])
    if vrm0_prop:
        refs.update(v for v in vrm0_prop.get("textureProperties", {}).values() if isinstance(v, int))
    return refs


def remap_material(material, tex_map, slot=None):
    m = json.loads(json.dumps(material))
    if slot and slot != "other" and is_generic(m.get("name")):
        m["name"] = CANONICAL[slot]
    pbr = m.get("pbrMetallicRoughness", {})
    for key in ("baseColorTexture", "metallicRoughnessTexture"):
        if key in pbr:
            pbr[key]["index"] = tex_map[pbr[key]["index"]]
    for key in ("normalTexture", "emissiveTexture", "occlusionTexture"):
        if key in m:
            m[key]["index"] = tex_map[m[key]["index"]]
    for ext in m.get("extensions", {}).values():
        if isinstance(ext, dict):
            for key, value in ext.items():
                if key.endswith("Texture") and isinstance(value, dict) and "index" in value:
                    value["index"] = tex_map[value["index"]]
    return m


# ---------------------------------------------------------------- extraction

def legwear(g, binary, slots, kept):
    """Socks and stockings that run down into the shoe.

    VRoid draws these as part of a garment material that also covers the
    torso — the bunny-girl stockings live in the same "Tops" as her bodysuit.
    Taking only the shoe leaves the leg bare, which is what made a borrowed
    shoe look like it had lost the foot. Only the geometry below the knee
    comes along, clipped triangle by triangle.
    """
    spans, height = vertical_extents(g, binary)
    if not spans or height <= 0:
        return []
    floor = min(v[0] for v in spans.values())
    ankle = floor + height * 0.13
    knee = floor + height * 0.30
    already = {id(p) for _, p, _ in kept}
    extra = []
    for mi, mesh in enumerate(g.get("meshes", [])):
        for prim in mesh["primitives"]:
            index = prim.get("material")
            if id(prim) in already or index not in spans:
                continue
            if slots.get(index) not in ("tops", "bottoms", "onepiece", "accessory"):
                continue
            low, high = spans[index]
            # Reaches the ankle, and is not itself a full-length garment we
            # would only be taking a slice out of the middle of.
            if low <= ankle < high:
                extra.append((mi, prim, knee))
    return extra


def extract(g, binary, slots, wanted, kind):
    """Returns (json, binary) for the part, or None when the model lacks it."""
    kept_prims = []  # (mesh index, primitive, clip height or None)
    for mi, mesh in enumerate(g.get("meshes", [])):
        for prim in mesh["primitives"]:
            if slots.get(prim.get("material")) in wanted:
                kept_prims.append((mi, prim, None))
    if not kept_prims:
        return None
    if kind == "hair" and not any(slots.get(p.get("material")) == "hair" for _, p, _c in kept_prims):
        return None
    if kind in ("tops", "bottoms", "shoes"):
        spans, height = vertical_extents(g, binary)
        floor = min((v[0] for v in spans.values()), default=0.0)
        lows = [spans[p["material"]][0] for _, p, _c in kept_prims if p.get("material") in spans]
        highs = [spans[p["material"]][1] for _, p, _c in kept_prims if p.get("material") in spans]
        if lows and highs and height > 0 and (max(highs) - min(lows)) / height > 0.65:
            # Whole-look geometry wearing one garment's name — it stays
            # available under Outfit, but it isn't a single garment.
            return None

    # Socks come along AFTER the span check above: the stockings run from
    # ankle to knee, and counting them would make every shoe look like
    # whole-look geometry and drop it from the library entirely.
    if kind == "shoes":
        kept_prims += legwear(g, binary, slots, kept_prims)

    # An outfit needs at least one garment. Some VRoid models paint the
    # clothes into the body-skin texture and keep only shoes as geometry —
    # there the outfit IS "this model's skin + shoes".
    if kind == "outfit" and not any(
            slots.get(p.get("material")) in ("tops", "onepiece", "bottoms", "shoes", "accessory")
            for _, p, _c in kept_prims):
        return None
    part_slots = {slots.get(p.get("material")) for _, p, _c in kept_prims}
    if kind == "eyes" and not part_slots & {"eyeIris", "eyeWhite"}:
        return None

    b = Builder()
    materials = g.get("materials", [])
    vrm0 = g.get("extensions", {}).get("VRM", {})
    vrm0_props = vrm0.get("materialProperties", [])

    # Materials + textures actually used.
    mat_order = []
    for _, prim, _clip in kept_prims:
        if prim["material"] not in mat_order:
            mat_order.append(prim["material"])
    tex_order = []
    for mi in mat_order:
        prop = vrm0_props[mi] if mi < len(vrm0_props) else None
        for t in sorted(texture_refs(materials[mi], prop)):
            if t < len(g.get("textures", [])) and t not in tex_order:
                tex_order.append(t)
    tex_map = {old: new for new, old in enumerate(tex_order)}
    mat_map = {old: new for new, old in enumerate(mat_order)}

    new_textures, new_images = [], []
    for t in tex_order:
        tex = g["textures"][t]
        img = g["images"][tex["source"]]
        view = g["bufferViews"][img["bufferView"]]
        blob = binary[view.get("byteOffset", 0):view.get("byteOffset", 0) + view["byteLength"]]
        image = {"bufferView": b.add_bytes(blob), "mimeType": img.get("mimeType", "image/png")}
        if img.get("name"):
            image["name"] = img["name"]
        new_images.append(image)
        new_tex = {"source": len(new_images) - 1}
        if "sampler" in tex:
            new_tex["sampler"] = tex["sampler"]
        if tex.get("name"):
            new_tex["name"] = tex["name"]
        new_textures.append(new_tex)

    # Meshes: primitives grouped by original mesh, vertices re-indexed.
    new_meshes, mesh_map = [], {}
    for mi, prim, clip in kept_prims:
        if mi not in mesh_map:
            mesh_map[mi] = len(new_meshes)
            new_meshes.append({"name": g["meshes"][mi].get("name", f"mesh{mi}"), "primitives": []})
        indices, idx_acc = read_accessor(g, binary, prim["indices"])
        indices = indices.flatten()
        if clip is not None:
            positions = read_accessor(g, binary, prim["attributes"]["POSITION"])[0]
            tris = indices.reshape(-1, 3)
            below = positions[:, 1] <= clip
            tris = tris[np.all(below[tris], axis=1)]
            if len(tris) < 1:
                continue
            indices = tris.flatten()
        used, inverse = np.unique(indices, return_inverse=True)
        attributes = {}
        for attr, acc_index in prim["attributes"].items():
            if attr.startswith("TEXCOORD_") and attr != "TEXCOORD_0":
                continue
            values, acc = read_accessor(g, binary, acc_index)
            subset = values[used]
            attributes[attr] = b.add_array(
                subset, acc["type"], acc["componentType"], target=34962,
                normalized=acc.get("normalized", False), with_bounds=(attr == "POSITION"))
        index_dtype = 5123 if len(used) < 65536 else 5125
        new_prim = {
            "attributes": attributes,
            "indices": b.add_array(inverse.reshape(-1, 1), "SCALAR", index_dtype, target=34963),
            "material": mat_map[prim["material"]],
            "mode": prim.get("mode", 4),
        }
        new_meshes[mesh_map[mi]]["primitives"].append(new_prim)

    # Nodes: all kept; mesh/skin only on the kept mesh nodes.
    skin_map, new_skins = {}, []
    new_nodes = []
    for node in g.get("nodes", []):
        n = json.loads(json.dumps(node))
        n.pop("weights", None)
        if "mesh" in n and n["mesh"] in mesh_map:
            n["mesh"] = mesh_map[n["mesh"]]
            if "skin" in n:
                old_skin = n["skin"]
                if old_skin not in skin_map:
                    skin = g["skins"][old_skin]
                    new_skin = {"joints": skin["joints"]}
                    if "skeleton" in skin:
                        new_skin["skeleton"] = skin["skeleton"]
                    if skin.get("name"):
                        new_skin["name"] = skin["name"]
                    if "inverseBindMatrices" in skin:
                        ibm, _ = read_accessor(g, binary, skin["inverseBindMatrices"])
                        new_skin["inverseBindMatrices"] = b.add_array(ibm, "MAT4", 5126)
                    skin_map[old_skin] = len(new_skins)
                    new_skins.append(new_skin)
                n["skin"] = skin_map[old_skin]
        else:
            n.pop("mesh", None)
            n.pop("skin", None)
        new_nodes.append(n)

    # The head this part was modelled for. A hair part keeps no face
    # geometry, so without this the app cannot tell that a hairstyle cut for
    # a small head needs enlarging to fit a bigger one.
    head = slot_bounds(g, binary, slots, {"faceSkin"})
    out = {
        "asset": {"version": "2.0", "generator": f"NeuraLink extract_parts ({g.get('asset', {}).get('generator', '?')})"},
        "extras": {"NL_headSize": [round(v, 5) for v in head]} if head else {},
        "extensionsUsed": g.get("extensionsUsed", []),
        "scene": g.get("scene", 0),
        "scenes": g.get("scenes", [{"nodes": [0]}]),
        "nodes": new_nodes,
        "meshes": new_meshes,
        "materials": [remap_material(materials[mi], tex_map, slots.get(mi)) for mi in mat_order],
        "textures": new_textures,
        "images": new_images,
        "samplers": g.get("samplers", []),
        "skins": new_skins,
        "accessors": b.accessors,
        "bufferViews": b.views,
        "buffers": [{"byteLength": b.length}],
        "extensions": {},
    }
    if "extensionsRequired" in g:
        out["extensionsRequired"] = g["extensionsRequired"]

    # VRM extension, trimmed.
    exts = g.get("extensions", {})
    if "VRM" in exts:
        v = json.loads(json.dumps(exts["VRM"]))
        meta = v.get("meta", {})
        meta.pop("texture", None)
        v["meta"] = meta
        v["firstPerson"] = {**v.get("firstPerson", {}), "meshAnnotations": []}
        groups = []
        for group in v.get("blendShapeMaster", {}).get("blendShapeGroups", []):
            group = dict(group)
            group["binds"] = []  # morph targets are not exported
            groups.append(group)
        v["blendShapeMaster"] = {"blendShapeGroups": groups}
        props = []
        for mi in mat_order:
            prop = json.loads(json.dumps(vrm0_props[mi])) if mi < len(vrm0_props) else {"name": materials[mi].get("name"), "shader": "VRM/MToon"}
            prop["textureProperties"] = {k: tex_map[t] for k, t in prop.get("textureProperties", {}).items() if t in tex_map}
            slot = slots.get(mi)
            if slot and slot != "other" and is_generic(prop.get("name")):
                prop["name"] = CANONICAL[slot]
            props.append(prop)
        v["materialProperties"] = props
        out["extensions"]["VRM"] = v
    if "VRMC_vrm" in exts:
        v = json.loads(json.dumps(exts["VRMC_vrm"]))
        v.get("meta", {}).pop("thumbnailImage", None)
        if "firstPerson" in v:
            v["firstPerson"]["meshAnnotations"] = []
        for section in ("preset", "custom"):
            for expr in v.get("expressions", {}).get(section, {}).values():
                expr["morphTargetBinds"] = []
                expr["materialColorBinds"] = [
                    {**bind, "material": mat_map[bind["material"]]}
                    for bind in expr.get("materialColorBinds", []) if bind.get("material") in mat_map]
                expr["textureTransformBinds"] = [
                    {**bind, "material": mat_map[bind["material"]]}
                    for bind in expr.get("textureTransformBinds", []) if bind.get("material") in mat_map]
        out["extensions"]["VRMC_vrm"] = v
    for key in ("VRMC_springBone", "VRMC_node_constraint"):
        if key in exts:
            out["extensions"][key] = exts[key]
    return out, b.binary()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    total_in = total_out = 0
    for name in sorted(os.listdir(src)):
        if not name.lower().endswith((".vrm", ".glb")):
            continue
        path = os.path.join(src, name)
        stem = os.path.splitext(name)[0].lower()
        g, binary = read_glb(path)
        slots = material_slots(g, binary)
        total_in += os.path.getsize(path)
        written = []
        for kind, wanted in PARTS.items():
            result = extract(g, binary, slots, wanted, kind)
            if result is None:
                continue
            out_path = os.path.join(dst, f"{stem}__{kind}.vrm")
            write_glb(out_path, *result)
            size = os.path.getsize(out_path)
            total_out += size
            written.append(f"{kind} {size / 1e6:.1f} MB")
        print(f"{name:26} {os.path.getsize(path) / 1e6:5.1f} MB → {', '.join(written) or 'nothing (no recognisable parts)'}")
    print(f"total {total_in / 1e6:.0f} MB → {total_out / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
