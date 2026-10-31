"""Writes textured triangle meshes into a USDZ that RealityKit loads (UsdPreviewSurface materials, Y-up, metres).

A model is a list of parts. Parts can be grouped (e.g. one group per animation frame), and groups can start hidden;
the app shows one frame group at a time to play an animation like a flip-book.
"""
import hashlib
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt


@dataclass
class Part:
    name: str
    vertices: np.ndarray  # (n, 3)
    normals: np.ndarray  # (n, 3)
    indices: np.ndarray  # (m, 3)
    uvs: np.ndarray | None = None  # (n, 2), with texture
    texture: bytes | None = None  # PNG
    color: tuple = (0.8, 0.8, 0.8)  # used when there's no texture
    group: str = ""
    hidden_group: bool = False
    extra: dict = field(default_factory=dict)


def _safe(name):
    cleaned = "".join(c if c.isalnum() else "_" for c in name)
    return cleaned if cleaned and not cleaned[0].isdigit() else "_" + cleaned


def write_usdz(path, parts, roughness=0.85):
    path = Path(path)
    work = path.parent / (path.stem + "_usd")
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    usd = work / "model.usdc"

    stage = Usd.Stage.CreateNew(str(usd))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, "/Model")
    stage.SetDefaultPrim(root.GetPrim())

    materials = {}

    def material_for(part):
        key = hashlib.sha1(part.texture).hexdigest()[:12] if part.texture else "c" + "_".join(f"{c:.3f}" for c in part.color)
        if key in materials:
            return materials[key]
        mpath = f"/Model/Materials/{_safe('m' + key)}"
        material = UsdShade.Material.Define(stage, mpath)
        shader = UsdShade.Shader.Define(stage, mpath + "/Surface")
        shader.CreateIdAttr("UsdPreviewSurface")
        shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(roughness)
        shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
        if part.texture:
            name = f"tex_{key}.png"
            (work / name).write_bytes(part.texture)
            reader = UsdShade.Shader.Define(stage, mpath + "/StReader")
            reader.CreateIdAttr("UsdPrimvarReader_float2")
            reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
            image = UsdShade.Shader.Define(stage, mpath + "/Texture")
            image.CreateIdAttr("UsdUVTexture")
            image.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(name)
            image.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(reader.ConnectableAPI(), "result")
            image.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)
            shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(image.ConnectableAPI(), "rgb")
        else:
            shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*part.color[:3]))
        material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
        materials[key] = material
        return material

    used = set()
    for part in parts:
        parent = "/Model"
        if part.group:
            parent = f"/Model/{_safe(part.group)}"
            group = UsdGeom.Xform.Define(stage, parent)
            if part.hidden_group:
                group.MakeInvisible()
        name = _safe(part.name)
        while f"{parent}/{name}" in used:
            name += "_"
        used.add(f"{parent}/{name}")
        mesh = UsdGeom.Mesh.Define(stage, f"{parent}/{name}")
        mesh.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(np.ascontiguousarray(part.vertices, dtype=np.float32)))
        mesh.CreateFaceVertexCountsAttr(Vt.IntArray([3] * len(part.indices)))
        mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(np.ascontiguousarray(part.indices.reshape(-1), dtype=np.int32)))
        mesh.CreateNormalsAttr(Vt.Vec3fArray.FromNumpy(np.ascontiguousarray(part.normals, dtype=np.float32)))
        mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
        mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
        lo, hi = part.vertices.min(0), part.vertices.max(0)
        mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, lo)), Gf.Vec3f(*map(float, hi))]))
        if part.uvs is not None and part.texture:
            st = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
            st.Set(Vt.Vec2fArray.FromNumpy(np.ascontiguousarray(part.uvs, dtype=np.float32)))
        UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material_for(part))

    stage.GetRootLayer().Save()
    if path.exists():
        path.unlink()
    assert UsdUtils.CreateNewARKitUsdzPackage(Sdf.AssetPath(str(usd)), str(path)), f"usdz packaging failed: {path}"
    shutil.rmtree(work)
    return path
