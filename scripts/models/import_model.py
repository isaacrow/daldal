"""Brings a supplied 3D model (GLB, Y-up, uncompressed; decode Draco first with gltf-transform) into the landmark
catalogue: writes <QID>.usdz (1 unit tall, standing on y = 0, centred), a textured map icon, and its models.json
entry with the real height and credit.

    D:/daldal-tools/TripoSR/.venv/Scripts/python.exe -X utf8 scripts/models/import_model.py \
        model.glb Q773704 57 "Hand-built 3D model supplied by ..." D:/daldal-tools/models-out
"""
import hashlib
import io
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from kenney_to_usdz import Gltf, parts, pose  # noqa: E402
from usd_writer import write_usdz  # noqa: E402


def icon(part_list, path, preview=None):
    """A 3/4 view from above, coloured from the texture (one colour per triangle), on transparency."""
    tris, cols = [], []
    for p in part_list:
        if p.texture is not None and p.uvs is not None:
            tex = np.asarray(Image.open(io.BytesIO(p.texture)).convert("RGB"))
            th, tw = tex.shape[:2]
            uv = p.uvs[p.indices].mean(1)
            px = np.clip((uv[:, 0] * (tw - 1)).astype(int), 0, tw - 1)
            py = np.clip(((1 - uv[:, 1]) * (th - 1)).astype(int), 0, th - 1)
            cols.append(tex[py, px].astype(float))
        else:
            cols.append(np.tile(np.array(p.color[:3]) * 255, (len(p.indices), 1)))
        tris.append(p.vertices[p.indices])
    tri, col = np.concatenate(tris), np.concatenate(cols)
    yaw, pitch = np.radians(35), np.radians(28)
    ry = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
    rx = np.array([[1, 0, 0], [0, np.cos(pitch), -np.sin(pitch)], [0, np.sin(pitch), np.cos(pitch)]])
    q = tri @ ry.T @ rx.T
    flat = q.reshape(-1, 3)
    size = 640
    s = size * 0.9 / max(np.ptp(flat[:, 0]), np.ptp(flat[:, 1]))
    cx, cy = (flat[:, 0].max() + flat[:, 0].min()) / 2, (flat[:, 1].max() + flat[:, 1].min()) / 2
    n = np.cross(q[:, 1] - q[:, 0], q[:, 2] - q[:, 0])
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    light = np.array([0.3, 0.8, 0.5]) / np.linalg.norm([0.3, 0.8, 0.5])
    shade = 0.55 + 0.45 * np.abs(n @ light)
    image = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(image)
    for i in np.argsort(q[:, :, 2].mean(1)):
        draw.polygon([(size / 2 + (a[0] - cx) * s, size / 2 - (a[1] - cy) * s) for a in q[i]],
                     fill=tuple(int(x) for x in np.clip(col[i] * shade[i], 0, 255)) + (255,))
    image = image.crop(image.getbbox())
    if preview:
        image.save(preview)
    image.thumbnail((160, 160), Image.LANCZOS)
    out = Image.new("RGBA", (160, 160))
    out.paste(image, ((160 - image.width) // 2, 160 - image.height), image)
    out.save(path)


def main(glb, qid, height, credit, out_dir):
    out = Path(out_dir)
    g = Gltf(glb)
    model = parts(g, pose(g))
    allv = np.concatenate([p.vertices for p in model])
    lo, hi = allv.min(0), allv.max(0)
    scale = 1.0 / (hi[1] - lo[1])
    for p in model:
        p.vertices = (p.vertices - [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]) * scale
        if p.texture:  # 2048 px is plenty on a phone, and keeps the download small.
            image = Image.open(io.BytesIO(p.texture)).convert("RGB")
            image.thumbnail((2048, 2048), Image.LANCZOS)
            buffer = io.BytesIO()
            image.save(buffer, "PNG", optimize=True)
            p.texture = buffer.getvalue()
    target = out / f"{qid}.usdz"
    write_usdz(target, model, roughness=0.6)
    icon(model, out / "icons" / f"{qid}.png", preview=Path(glb).with_name("preview.png"))
    data = target.read_bytes()
    catalog = json.load(open(out / "models.json", encoding="utf-8"))
    entry = next((e for e in catalog if e["id"] == qid), None)
    if entry is None:
        entry = {"id": qid}
        catalog.append(entry)
    entry.update({"file": target.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                  "icon": f"{qid}.png", "height": float(height), "generator": credit, "photo": ""})
    json.dump(catalog, open(out / "models.json", "w", encoding="utf-8"), indent=1)
    print(f"{qid}: {sum(len(p.indices) for p in model)} triangles, {len(data) // 1024} KB, {height} m")


if __name__ == "__main__":
    main(*sys.argv[1:6])
