"""Top-down pictures of every landmark model, for drawing on the map flat on the ground at true size, turning with
the map. Also records each model's footprint in metres (from its proportions and real height) in models.json.

    D:/daldal-tools/TripoSR/.venv/Scripts/python.exe -X utf8 scripts/models/top_views.py D:/daldal-tools/models-out
"""
import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from pxr import Usd, UsdGeom, UsdShade

SIZE = 256


def meshes(usdz):
    """Triangles of a USDZ with a colour per triangle (texture sampled at the centre, or the material colour)."""
    archive = zipfile.ZipFile(usdz)
    stage = Usd.Stage.Open(str(usdz))
    tris, cols = [], []
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh) or UsdGeom.Imageable(prim).ComputeVisibility() == "invisible":
            continue
        mesh = UsdGeom.Mesh(prim)
        points = np.array(mesh.GetPointsAttr().Get(), dtype=float)
        counts = np.array(mesh.GetFaceVertexCountsAttr().Get())
        indices = np.array(mesh.GetFaceVertexIndicesAttr().Get())
        if len(points) == 0 or not (counts == 3).all():
            continue
        faces = indices.reshape(-1, 3)
        colour = np.array([200, 190, 170], dtype=float)
        texture = None
        material = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()[0]
        if material:
            for shader_prim in Usd.PrimRange(material.GetPrim()):
                shader = UsdShade.Shader(shader_prim)
                if not shader:
                    continue
                kind = shader.GetIdAttr().Get()
                if kind == "UsdPreviewSurface":
                    value = shader.GetInput("diffuseColor").Get()
                    if value is not None:
                        colour = np.array(value) * 255
                elif kind == "UsdUVTexture":
                    asset = shader.GetInput("file").Get()
                    name = Path(str(asset.path)).name if asset else None
                    member = next((m for m in archive.namelist() if name and m.endswith(name)), None)
                    if member:
                        texture = np.asarray(Image.open(io.BytesIO(archive.read(member))).convert("RGB"))
        st = UsdGeom.PrimvarsAPI(mesh).GetPrimvar("st")
        if texture is not None and st and st.Get() is not None:
            uv = np.array(st.Get())[faces].mean(1)
            th, tw = texture.shape[:2]
            px = np.clip((uv[:, 0] * (tw - 1)).astype(int), 0, tw - 1)
            py = np.clip(((1 - uv[:, 1]) * (th - 1)).astype(int), 0, th - 1)
            cols.append(texture[py, px].astype(float))
        else:
            cols.append(np.tile(colour, (len(faces), 1)))
        tris.append(points[faces])
    return np.concatenate(tris), np.concatenate(cols)


def top_view(tri, col, path):
    """Looking straight down (-y): x to the right, z towards the bottom of the picture (north up on the map)."""
    lo, hi = tri.reshape(-1, 3).min(0), tri.reshape(-1, 3).max(0)
    span = max(hi[0] - lo[0], hi[2] - lo[2])
    scale = (SIZE - 4) / span
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    light = np.array([-0.35, 0.85, -0.4]) / np.linalg.norm([-0.35, 0.85, -0.4])
    shade = 0.6 + 0.4 * np.clip(n @ light, 0, 1)
    image = Image.new("RGBA", (SIZE, SIZE))
    draw = ImageDraw.Draw(image)
    for i in np.argsort(tri[:, :, 1].mean(1)):  # Lowest first, so roofs and domes cover the ground.
        draw.polygon([(SIZE / 2 + (p[0] - cx) * scale, SIZE / 2 + (p[2] - cz) * scale) for p in tri[i]],
                     fill=tuple(int(v) for v in np.clip(col[i] * shade[i], 0, 255)) + (255,))
    image.save(path, optimize=True)
    return hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1]


def main(out_dir):
    out = Path(out_dir)
    catalog = json.load(open(out / "models.json", encoding="utf-8"))
    for entry in catalog:
        usdz = out / entry["file"]
        if not usdz.exists():
            continue
        tri, col = meshes(usdz)
        width, depth, tall = top_view(tri, col, out / "icons" / f"{entry['id']}-top.png")
        metres = (entry.get("height") or 20.0) / max(tall, 1e-6)
        entry["top"] = f"{entry['id']}-top.png"
        entry["footprint"] = [round(width * metres, 1), round(depth * metres, 1)]
        print(f"{entry['id']:12} footprint {entry['footprint']} m")
    json.dump(catalog, open(out / "models.json", "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
