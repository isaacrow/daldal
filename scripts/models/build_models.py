"""Builds 3D models of Iraq's monuments and places to visit from one photo each, with TripoSR (MIT licence).

For every heritage site and city-guide place that has a Wikimedia Commons photo:
  1. download the photo and cut the monument out of its background (rembg),
  2. reconstruct it in 3D with TripoSR and bake its colours into a texture,
  3. simplify the mesh so it loads fast on a phone, stand it upright on the ground, one unit tall,
  4. package it as a USDZ (what RealityKit and AR Quick Look load), plus a preview render for review.

The shapes are an AI's best guess from a single photo: the hidden sides are invented. Use them as 3D landmarks
on the map and in AR, not as surveys. The photos are CC BY-SA (or similar) on Commons, so each model credits
its photo in models.json.

Run with the Python that has TripoSR installed (see scripts/models/README.md):

    D:/daldal-tools/TripoSR/.venv/Scripts/python.exe -X utf8 scripts/models/build_models.py out/models
"""
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

TRIPOSR = Path(os.environ.get("TRIPOSR_DIR", "D:/daldal-tools/TripoSR"))
sys.path.insert(0, str(TRIPOSR))

import numpy as np  # noqa: E402
import rembg  # noqa: E402
import torch  # noqa: E402
import trimesh  # noqa: E402
import xatlas  # noqa: E402
from PIL import Image  # noqa: E402
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt  # noqa: E402
from tsr.bake_texture import bake_texture  # noqa: E402
from tsr.system import TSR  # noqa: E402
from tsr.utils import remove_background, resize_foreground  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
UA = {"User-Agent": "Daldal/0.1 (https://github.com/isaacrow/daldal; 3D model builder)"}
# Landscapes and whole cities can't be cut out of a photo as one object.
SKIP_KINDS = {"park", "market"}
SKIP_IDS = set(os.environ.get("SKIP_IDS", "").split(",")) - {""}
FACES = 24_000
TEXTURE = 1024


def sites():
    """Every place with a photo, heritage catalogue first (it has the World Heritage sites)."""
    found = {}
    for s in json.load(open(ROOT / "Daldal/Resources/Data/iraq-heritage.json", encoding="utf-8")):
        if s.get("imageURL"):
            found[s["id"]] = {"id": s["id"], "name": s.get("nameEn") or s.get("nameAr"), "image": s["imageURL"]}
    for city in json.load(open(ROOT / "Daldal/Resources/Data/city-guides.json", encoding="utf-8")):
        for p in city["places"]:
            if p.get("image") and p["kind"] not in SKIP_KINDS and p["id"] not in found:
                found[p["id"]] = {"id": p["id"], "name": p.get("name_en") or p.get("name_ar"), "image": p["image"]}
    return [s for s in found.values() if s["id"] not in SKIP_IDS]


def download(url, path):
    if path.exists():
        return True
    for attempt in range(4):
        try:
            data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()
            path.write_bytes(data)
            return True
        except Exception:
            time.sleep(2 + attempt * 4)
    return False


def commons_file(url):
    """The Commons file name in a Special:FilePath URL, for the credit link."""
    name = urllib.parse.unquote(url.split("Special:FilePath/")[-1].split("?")[0])
    return "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name.replace(" ", "_"))


def upright(mesh):
    """TripoSR is Z-up and faces +X; RealityKit is Y-up and faces +Z. Stand it on y = 0, one unit tall."""
    rotate = trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0])
    turn = trimesh.transformations.rotation_matrix(-np.pi / 2, [0, 1, 0])
    mesh.apply_transform(turn @ rotate)
    lo, hi = mesh.bounds
    mesh.apply_translation([-(lo[0] + hi[0]) / 2, -lo[1], -(lo[2] + hi[2]) / 2])
    mesh.apply_scale(1.0 / max(hi[1] - lo[1], 1e-6))
    return mesh


def write_usdz(path, vertices, normals, indices, uvs, texture_png):
    work = path.with_suffix("")
    work.mkdir(exist_ok=True)
    usda = work / "model.usdc"
    (work / "texture.png").write_bytes(texture_png.read_bytes())

    stage = Usd.Stage.CreateNew(str(usda))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, "/Model")
    stage.SetDefaultPrim(root.GetPrim())

    mesh = UsdGeom.Mesh.Define(stage, "/Model/Mesh")
    mesh.CreatePointsAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, v)) for v in vertices]))
    mesh.CreateFaceVertexCountsAttr(Vt.IntArray([3] * len(indices)))
    mesh.CreateFaceVertexIndicesAttr(Vt.IntArray([int(i) for i in indices.reshape(-1)]))
    mesh.CreateNormalsAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, n)) for n in normals]))
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    st = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
    st.Set(Vt.Vec2fArray([Gf.Vec2f(float(u), float(v)) for u, v in uvs]))

    material = UsdShade.Material.Define(stage, "/Model/Material")
    shader = UsdShade.Shader.Define(stage, "/Model/Material/Surface")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.85)
    shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    reader = UsdShade.Shader.Define(stage, "/Model/Material/StReader")
    reader.CreateIdAttr("UsdPrimvarReader_float2")
    reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
    image = UsdShade.Shader.Define(stage, "/Model/Material/Texture")
    image.CreateIdAttr("UsdUVTexture")
    image.CreateInput("file", Sdf.ValueTypeNames.Asset).Set("texture.png")
    image.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(reader.ConnectableAPI(), "result")
    image.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(image.ConnectableAPI(), "rgb")
    material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
    stage.GetRootLayer().Save()

    if path.exists():
        path.unlink()
    assert UsdUtils.CreateNewARKitUsdzPackage(Sdf.AssetPath(str(usda)), str(path)), f"usdz packaging failed: {path}"


def main(out_dir):
    out = Path(out_dir)
    (out / "photos").mkdir(parents=True, exist_ok=True)
    (out / "review").mkdir(exist_ok=True)
    (out / "work").mkdir(exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = TSR.from_pretrained("stabilityai/TripoSR", config_name="config.yaml", weight_name="model.ckpt")
    model.renderer.set_chunk_size(8192)
    model.to(device)
    session = rembg.new_session()

    catalog = []
    todo = sites()
    only = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None
    for n, site in enumerate(todo, 1):
        if only and site["id"] not in only:
            continue
        usdz = out / f"{site['id']}.usdz"
        photo = out / "photos" / f"{site['id']}.jpg"
        print(f"[{n}/{len(todo)}] {site['id']} {site['name']}", flush=True)
        if usdz.exists():  # Built by an earlier run.
            data = usdz.read_bytes()
            catalog.append({
                "id": site["id"], "file": usdz.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "photo": commons_file(site["image"]), "generator": "TripoSR (MIT), from one photo",
            })
            continue
        if not download(site["image"], photo):
            print("   photo download failed")
            continue
        try:
            cutout = resize_foreground(remove_background(Image.open(photo).convert("RGB"), session), 0.85)
            cutout.save(out / "review" / f"{site['id']}-cutout.png")
            rgba = np.array(cutout).astype(np.float32) / 255.0
            # Grey background behind the cut-out, as TripoSR was trained.
            rgb = rgba[:, :, :3] * rgba[:, :, 3:4] + (1 - rgba[:, :, 3:4]) * 0.5
            with torch.no_grad():
                codes = model([Image.fromarray((rgb * 255).astype(np.uint8))], device=device)
                model.render(codes, n_views=1, elevation_deg=15, return_type="pil")[0][0] \
                    .save(out / "review" / f"{site['id']}-render.png")
                mesh = model.extract_mesh(codes, False, resolution=256)[0]
                if len(mesh.faces) > FACES:
                    mesh = mesh.simplify_quadric_decimation(face_count=FACES)
                baked = bake_texture(mesh, model, codes[0], TEXTURE)
            texture = out / "work" / f"{site['id']}.png"
            Image.fromarray((baked["colors"] * 255.0).astype(np.uint8)).transpose(Image.FLIP_TOP_BOTTOM).save(texture)

            placed = upright(trimesh.Trimesh(mesh.vertices[baked["vmapping"]], baked["indices"], process=False))
            write_usdz(usdz, placed.vertices, placed.vertex_normals, baked["indices"], baked["uvs"], texture)
        except Exception as error:  # One bad photo shouldn't stop the batch.
            print("   failed:", error)
            continue
        finally:
            torch.cuda.empty_cache()

        data = usdz.read_bytes()
        catalog.append({
            "id": site["id"], "file": usdz.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "photo": commons_file(site["image"]), "generator": "TripoSR (MIT), from one photo",
        })
        print(f"   {len(data) // 1024} KB")

    json.dump(catalog, open(out / "models.json", "w", encoding="utf-8"), indent=1)
    print(len(catalog), "models")


if __name__ == "__main__":
    main(sys.argv[1])
