"""Converts Kenney's CC0 model kits (car-kit, mini-characters, castle-kit; https://kenney.nl) into the USDZ models
that Drive Scan and History in AR draw.

GLB files are read directly. Characters are skinned and animated: each animation is baked into a few posed frames
(groups named "<animation>_<frame>"), which the app shows one at a time. That keeps the USDZ simple (no skeletons)
and lets the app play walk or fight cycles at any speed.

    python -X utf8 scripts/models/kenney_to_usdz.py D:/daldal-tools/kenney Daldal/Resources/Models3D
"""
import io
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from usd_writer import Part, write_usdz  # noqa: E402

# What the app uses, by kit. Characters get their walk cycle; soldiers also get a sword swing.
VEHICLES = ["sedan", "sedan-sports", "suv", "suv-luxury", "taxi", "police", "ambulance", "hatchback-sports",
            "van", "delivery", "truck", "truck-flat", "garbage-truck", "firetruck", "tractor"]
PEOPLE = [f"character-{s}-{c}" for s in ("male", "female") for c in "abcdef"]
CASTLE = ["siege-tower", "siege-ram", "siege-catapult", "siege-trebuchet", "siege-ballista",
          "wall", "wall-half", "wall-corner", "wall-doorway", "tower-square", "tower-hexagon-base",
          "tower-hexagon-roof", "gate", "flag-banner-long", "flag-pennant", "rocks-large", "tree-large", "ground-hills"]
ANIMATIONS = {"walk": 8, "attack-melee-right": 8, "idle": 4}
# CC0 models by Quaternius from poly.pizza, for the Battle of Karbala scene: robed warriors, horses, camp.
# (file in the download folder, model name, animations to bake)
KARBALA = [
    ("hooded.glb", "warrior-hooded", {"sword_slash": 6, "run": 6, "idle_sword": 2}),
    ("white-horse.glb", "horse-white", {"gallop": 6, "walk": 6, "idle": 2}),
    ("horse.glb", "horse-brown", {"gallop": 6, "walk": 6, "idle": 2}),
    ("camel.glb", "camel", None),
    ("tent.glb", "tent", None),
    ("spear.glb", "spear", None),
]


class Gltf:
    def __init__(self, path):
        data = Path(path).read_bytes()
        length = struct.unpack("<I", data[12:16])[0]
        self.json = json.loads(data[20:20 + length])
        rest = data[20 + length:]
        self.bin = rest[8:8 + struct.unpack("<I", rest[:4])[0]] if rest else b""
        self.dir = Path(path).parent

    def accessor(self, index):
        a = self.json["accessors"][index]
        view = self.json["bufferViews"][a["bufferView"]]
        kinds = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
        dtype = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8, 5120: np.int8, 5122: np.int16}[a["componentType"]]
        n, k = a["count"], kinds[a["type"]]
        start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = view.get("byteStride")
        item = np.dtype(dtype).itemsize * k
        if stride and stride != item:
            raw = np.frombuffer(self.bin, np.uint8, count=stride * (n - 1) + item, offset=start)
            out = np.stack([np.frombuffer(raw[i * stride:i * stride + item].tobytes(), dtype) for i in range(n)])
        else:
            out = np.frombuffer(self.bin, dtype, count=n * k, offset=start).reshape(n, k)
        if a.get("normalized"):
            out = out.astype(np.float32) / np.iinfo(dtype).max
        return out.reshape(n, 4, 4).transpose(0, 2, 1) if k == 16 else out

    def texture(self, material_index):
        material = self.json["materials"][material_index]
        pbr = material.get("pbrMetallicRoughness", {})
        if "baseColorTexture" not in pbr:
            return None, tuple(pbr.get("baseColorFactor", [0.8, 0.8, 0.8, 1])[:3])
        texture = self.json["textures"][pbr["baseColorTexture"]["index"]]
        # WebP textures (EXT_texture_webp) name their image in the extension instead of "source".
        source = texture.get("source", texture.get("extensions", {}).get("EXT_texture_webp", {}).get("source"))
        image = self.json["images"][source]
        if "bufferView" in image:
            view = self.json["bufferViews"][image["bufferView"]]
            raw = self.bin[view.get("byteOffset", 0):view.get("byteOffset", 0) + view["byteLength"]]
        else:
            raw = (self.dir / image["uri"]).read_bytes()
        png = io.BytesIO()
        Image.open(io.BytesIO(raw)).convert("RGB").save(png, "PNG")
        return png.getvalue(), (1, 1, 1)


def quat_matrix(q):
    x, y, z, w = q / np.linalg.norm(q)
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def local_matrix(trs):
    m = np.eye(4)
    m[:3, :3] = quat_matrix(np.array(trs["rotation"])) * np.array(trs["scale"])
    m[:3, 3] = trs["translation"]
    return m


def sample(g, animation, t):
    """Each animated node's translation/rotation/scale at time t (seconds)."""
    out = {}
    for channel in animation["channels"]:
        sampler = animation["samplers"][channel["sampler"]]
        times = g.accessor(sampler["input"]).reshape(-1)
        values = g.accessor(sampler["output"])
        i = int(np.clip(np.searchsorted(times, t) - 1, 0, len(times) - 1))
        j = min(i + 1, len(times) - 1)
        f = 0.0 if j == i or sampler.get("interpolation") == "STEP" else float(np.clip((t - times[i]) / (times[j] - times[i]), 0, 1))
        path = channel["target"]["path"]
        a, b = values[i].astype(float), values[j].astype(float)
        if path == "rotation":
            if np.dot(a, b) < 0:
                b = -b
            value = a * (1 - f) + b * f
            value /= np.linalg.norm(value)
        else:
            value = a * (1 - f) + b * f
        out.setdefault(channel["target"]["node"], {})[path] = value
    return out


def pose(g, animation=None, t=0.0):
    """World matrix of every node."""
    nodes = g.json["nodes"]
    animated = sample(g, animation, t) if animation else {}
    world = [None] * len(nodes)

    def visit(index, parent):
        node = nodes[index]
        if "matrix" in node:
            local = np.array(node["matrix"]).reshape(4, 4).T
        else:
            trs = {"translation": node.get("translation", [0, 0, 0]), "rotation": node.get("rotation", [0, 0, 0, 1]),
                   "scale": node.get("scale", [1, 1, 1])}
            trs.update(animated.get(index, {}))
            local = local_matrix(trs)
        world[index] = parent @ local
        for child in node.get("children", []):
            visit(child, world[index])

    scene = g.json["scenes"][g.json.get("scene", 0)]
    for root in scene["nodes"]:
        visit(root, np.eye(4))
    return world


def vertex_normals(vertices, faces):
    normals = np.zeros_like(vertices)
    tri = vertices[faces]
    face_normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    for k in range(3):
        np.add.at(normals, faces[:, k], face_normals)
    return normals / np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-9)


def parts(g, world, group="", hidden=False):
    out = []
    for index, node in enumerate(g.json["nodes"]):
        if "mesh" not in node or world[index] is None:
            continue
        skin = g.json["skins"][node["skin"]] if "skin" in node else None
        if skin:
            joints = skin["joints"]
            inverse = g.accessor(skin["inverseBindMatrices"])
            matrices = np.stack([world[j] @ inverse[k] for k, j in enumerate(joints)])
        for p, primitive in enumerate(g.json["meshes"][node["mesh"]]["primitives"]):
            attributes = primitive["attributes"]
            v = g.accessor(attributes["POSITION"]).astype(float)
            homogeneous = np.c_[v, np.ones(len(v))]
            if skin:
                ids = g.accessor(attributes["JOINTS_0"]).astype(int)
                weights = g.accessor(attributes["WEIGHTS_0"]).astype(float)
                weights /= np.maximum(weights.sum(1, keepdims=True), 1e-9)
                skinned = np.einsum("nk,nkij->nij", weights, matrices[ids])
                v = np.einsum("nij,nj->ni", skinned, homogeneous)[:, :3]
            else:
                v = (homogeneous @ world[index].T)[:, :3]
            faces = g.accessor(primitive["indices"]).reshape(-1, 3).astype(np.int64) if "indices" in primitive \
                else np.arange(len(v)).reshape(-1, 3)
            uvs = g.accessor(attributes["TEXCOORD_0"]).astype(float) if "TEXCOORD_0" in attributes else None
            if uvs is not None:
                uvs = np.c_[uvs[:, 0], 1 - uvs[:, 1]]  # glTF's v runs down, USD's up.
            texture, color = g.texture(primitive["material"]) if "material" in primitive else (None, (0.8, 0.8, 0.8))
            out.append(Part(f"{node.get('name', 'mesh')}_{p}", v, vertex_normals(v, faces), faces, uvs, texture, color,
                            group, hidden))
    return out


def convert(source, target, animations=None):
    g = Gltf(source)
    if not animations:
        return write_usdz(target, parts(g, pose(g)), roughness=0.6)
    # Exporters prefix names ("CharacterArmature|Sword_Slash"); match on the plain, lower-case name.
    by_name = {}
    for a in g.json.get("animations", []):
        by_name.setdefault(a.get("name", "").split("|")[-1].lower().replace("-", "_"), a)
    model = []
    first = True
    for name, frames in animations.items():
        animation = by_name.get(name.replace("-", "_"))
        if not animation:
            continue
        end = max(float(g.accessor(s["input"]).max()) for s in animation["samplers"])
        for k in range(frames):
            model += parts(g, pose(g, animation, end * k / frames), f"{name.replace('-', '_')}_{k}", hidden=not first)
            first = False
    return write_usdz(target, model, roughness=0.6)


def main(kenney, out, polypizza=None):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    if polypizza:
        for file, name, animations in KARBALA:
            target = out / f"{name}.usdz"
            convert(Path(polypizza) / file, target, animations)
            print(f"{name:24} {target.stat().st_size // 1024} KB")
        return
    kits = {"car-kit": (VEHICLES, None), "mini-characters": (PEOPLE, ANIMATIONS), "castle-kit": (CASTLE, None)}
    for kit, (names, animations) in kits.items():
        folder = Path(kenney) / kit / "Models" / "GLB format"
        for name in names:
            source = folder / f"{name}.glb"
            if not source.exists():
                print("missing", source)
                continue
            target = out / f"{name}.usdz"
            convert(source, target, animations)
            print(f"{name:24} {target.stat().st_size // 1024} KB")


if __name__ == "__main__":
    # kenney_to_usdz.py <kenney folder> <out> [<poly.pizza folder>: convert the Karbala set instead]
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
