"""Hand-built 3D models of Iraq's most famous monuments, from their documented shapes and dimensions.

The photo-to-3D models (build_models.py) guess at hidden sides; for the monuments everyone knows, a clean model
built from real proportions looks far better: the Malwiya's spiral, the vault of Ctesiphon, the golden domes and
minarets of the shrines, the terraces of the Ziggurat of Ur. Geometry is generated here, faceted on purpose
(flat shading reads well at map and AR scale), and written as USDZ in metres, scaled to 1 unit tall like the
generated models, with the real height recorded in models.json.

    D:/daldal-tools/TripoSR/.venv/Scripts/python.exe -X utf8 scripts/models/hero_models.py D:/daldal-tools/models-out
"""
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from usd_writer import Part, write_usdz  # noqa: E402

# Materials: (colour, roughness, metallic)
BRICK = ((0.71, 0.54, 0.37), 0.95, 0.0)
MUD = ((0.80, 0.68, 0.50), 1.0, 0.0)
STONE = ((0.82, 0.76, 0.64), 0.9, 0.0)
GOLD = ((0.95, 0.74, 0.28), 0.25, 1.0)
TILE = ((0.13, 0.52, 0.62), 0.35, 0.0)  # turquoise glazed tile
TILE_DARK = ((0.10, 0.25, 0.48), 0.35, 0.0)  # lapis blue (Ishtar)
WHITE = ((0.93, 0.92, 0.88), 0.7, 0.0)
SHADOW = ((0.22, 0.18, 0.14), 1.0, 0.0)  # arch recesses
PAVING = ((0.86, 0.84, 0.80), 0.8, 0.0)


class Builder:
    """Collects flat-shaded triangles per material."""

    def __init__(self):
        self.tris = {}

    def tri(self, material, a, b, c):
        self.tris.setdefault(material, []).append((a, b, c))

    def quad(self, material, a, b, c, d):
        self.tri(material, a, b, c)
        self.tri(material, a, c, d)

    def box(self, material, centre, size, yaw=0.0):
        cx, cy, cz = centre
        w, h, d = (s / 2 for s in size)
        cos, sin = math.cos(yaw), math.sin(yaw)

        def p(x, y, z):
            return (cx + x * cos + z * sin, cy + y, cz - x * sin + z * cos)
        v = [p(x, y, z) for x in (-w, w) for y in (-h, h) for z in (-d, d)]
        # v index = xi*4 + yi*2 + zi
        faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
        for f in faces:
            self.quad(material, *(v[i] for i in f))

    def lathe(self, material, profile, centre=(0, 0, 0), segments=24):
        """Spins a (radius, height) profile, bottom to top, around a vertical axis."""
        cx, cy, cz = centre
        rings = [[(cx + r * math.cos(2 * math.pi * k / segments), cy + y, cz + r * math.sin(2 * math.pi * k / segments))
                  for k in range(segments)] for r, y in profile]
        for lower, upper in zip(rings, rings[1:]):
            for k in range(segments):
                k2 = (k + 1) % segments
                self.quad(material, lower[k], lower[k2], upper[k2], upper[k])
        for ring, top in ((rings[0], False), (rings[-1], True)):
            centre_point = (cx, ring[0][1], cz)
            for k in range(segments):
                a, b = ring[k], ring[(k + 1) % segments]
                self.tri(material, centre_point, b, a) if not top else self.tri(material, centre_point, a, b)

    def arch_shell(self, material, span, rise, thickness, depth, centre=(0, 0, 0), yaw=0.0, steps=20, parabolic=True):
        """A vault: a parabolic (or round) arch extruded `depth` along its axis, `thickness` thick."""
        cx, cy, cz = centre
        cos, sin = math.cos(yaw), math.sin(yaw)

        def curve(t, inset):
            half = span / 2 + thickness - inset
            x = -half + 2 * half * t
            y = (rise + thickness - inset) * (1 - (x / half) ** 2) if parabolic else math.sqrt(max(half ** 2 - x ** 2, 0)) * (rise / (span / 2))
            return x, y

        def p(x, y, z):
            return (cx + x * cos + z * sin, cy + y, cz - x * sin + z * cos)
        for i in range(steps):
            for inset, flip in ((0, False), (thickness, True)):
                x0, y0 = curve(i / steps, inset)
                x1, y1 = curve((i + 1) / steps, inset)
                a, b, c, d = p(x0, y0, -depth / 2), p(x1, y1, -depth / 2), p(x1, y1, depth / 2), p(x0, y0, depth / 2)
                self.quad(material, *((a, b, c, d) if not flip else (a, d, c, b)))
            for z, flip in ((-depth / 2, False), (depth / 2, True)):
                o0, o1 = curve(i / steps, 0), curve((i + 1) / steps, 0)
                n0, n1 = curve(i / steps, thickness), curve((i + 1) / steps, thickness)
                a, b, c, d = p(*o0, z), p(*o1, z), p(*n1, z), p(*n0, z)
                self.quad(material, *((a, b, c, d) if flip else (a, d, c, b)))

    def helix_ramp(self, material, radius_at, height, turns, width, thickness, steps=360, centre=(0, 0, 0)):
        """A ramp spiralling up around a tapering core (the Malwiya's)."""
        cx, cy, cz = centre
        prev = None
        for i in range(steps + 1):
            t = i / steps
            angle = -2 * math.pi * turns * t  # counter-clockwise going up, as at Samarra
            y = height * t
            r_in = radius_at(y) - 0.05
            r_out = r_in + width
            ring = [(cx + r * math.cos(angle), cy + yy, cz + r * math.sin(angle))
                    for r, yy in ((r_in, y), (r_out, y), (r_out, y - thickness), (r_in, y - thickness))]
            if prev:
                for k in range(4):
                    self.quad(material, prev[k], prev[(k + 1) % 4], ring[(k + 1) % 4], ring[k])
            prev = ring

    def parts(self):
        out = []
        for (colour, rough, metal), tris in self.tris.items():
            v = np.array([p for t in tris for p in t], dtype=float)
            faces = np.arange(len(v)).reshape(-1, 3)
            n = np.cross(v[faces[:, 1]] - v[faces[:, 0]], v[faces[:, 2]] - v[faces[:, 0]])
            n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
            normals = np.repeat(n, 3, axis=0)
            out.append(Part(f"m{len(out)}", v, normals, faces, color=colour, roughness=rough, metallic=metal))
        return out


# MARK: Pieces

def onion_dome(b, centre, radius, material=GOLD, drum=0.0, drum_material=TILE, finial=True):
    cx, cy, cz = centre
    if drum:
        b.lathe(drum_material, [(radius * 0.95, 0), (radius * 0.95, drum)], (cx, cy, cz))
    base = cy + drum
    profile = []
    for k in range(13):
        t = k / 12
        # Bulges past the drum, then draws into a point: the Shia shrine dome.
        r = radius * (1.0 + 0.18 * math.sin(math.pi * min(t * 1.6, 1))) * math.cos(t * math.pi / 2) ** 0.8
        profile.append((max(r, 0.02), radius * 1.35 * t))
    b.lathe(material, profile, (cx, base, cz))
    if finial:
        b.lathe(material, [(0.06 * radius, 0), (0.04 * radius, radius * 0.45)], (cx, base + radius * 1.35, cz), segments=8)


def minaret(b, base, height, radius, material=GOLD, base_material=TILE):
    cx, cy, cz = base
    b.lathe(base_material, [(radius * 1.25, 0), (radius * 1.2, height * 0.3)], base)
    b.lathe(material, [(radius, height * 0.3), (radius * 0.85, height * 0.78)], base, segments=16)
    # The muezzin's balcony, then the lantern and cap.
    b.lathe(material, [(radius * 0.85, height * 0.78), (radius * 1.6, height * 0.8), (radius * 1.6, height * 0.83),
                       (radius * 0.8, height * 0.84)], base, segments=16)
    b.lathe(material, [(radius * 0.8, height * 0.84), (radius * 0.7, height * 0.93), (radius * 0.75, height * 0.94),
                       (0.02, height)], base, segments=16)


def arcade_wall(b, start, end, height, thickness, arches, wall=TILE, recess=SHADOW):
    """A courtyard wall with a row of pointed arch recesses (drawn as dark insets on the face)."""
    (x0, z0), (x1, z1) = start, end
    length = math.hypot(x1 - x0, z1 - z0)
    yaw = math.atan2(-(z1 - z0), x1 - x0)
    mid = ((x0 + x1) / 2, height / 2, (z0 + z1) / 2)
    b.box(wall, mid, (length, height, thickness), yaw)
    nx, nz = math.sin(yaw), math.cos(yaw)  # wall normal
    for k in range(arches):
        t = (k + 0.5) / arches
        ax, az = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
        for side in (1, -1):
            off = side * (thickness / 2 + 0.02)
            b.box(recess, (ax + nx * off, height * 0.42, az + nz * off), (length / arches * 0.55, height * 0.6, 0.04), yaw)


def shrine(b, size, domes, minarets, minaret_height, dome_radius, gold_iwan=True):
    """A Shia holy shrine: tiled courtyard walls with arcades, the sanctuary, golden dome(s) and minarets."""
    half = size / 2
    b.box(PAVING, (0, 0.15, 0), (size, 0.3, size))
    for corner in ((-half, -half), (half, -half), (half, half), (-half, half), (-half, -half)):
        pass
    corners = [(-half, -half), (half, -half), (half, half), (-half, half)]
    for i in range(4):
        arcade_wall(b, corners[i], corners[(i + 1) % 4], size * 0.11, size * 0.04, 9)
    # The main gate (iwan) in the middle of the front wall, taller, gilded around the arch.
    b.box(TILE, (0, size * 0.09, half), (size * 0.18, size * 0.18, size * 0.06))
    b.box(GOLD if gold_iwan else TILE, (0, size * 0.075, half + size * 0.031), (size * 0.09, size * 0.13, 0.05))
    # Sanctuary block.
    sanctuary = size * 0.36
    b.box(TILE, (0, size * 0.11, 0), (sanctuary, size * 0.22, sanctuary))
    b.box(GOLD, (0, size * 0.12, sanctuary / 2 + 0.03), (sanctuary * 0.45, size * 0.2, 0.06))  # golden portico
    roof = size * 0.22
    offsets = [(0, 0)] if domes == 1 else [(-sanctuary * 0.25, 0), (sanctuary * 0.25, 0)]
    for dx, dz in offsets:
        onion_dome(b, (dx, roof, dz), dome_radius, drum=dome_radius * 0.5)
    spots = {2: [(-sanctuary * 0.45, sanctuary * 0.45), (sanctuary * 0.45, sanctuary * 0.45)],
             4: [(-sanctuary * 0.45, sanctuary * 0.45), (sanctuary * 0.45, sanctuary * 0.45),
                 (-sanctuary * 0.45, -sanctuary * 0.45), (sanctuary * 0.45, -sanctuary * 0.45)]}[minarets]
    for x, z in spots:
        minaret(b, (x, roof, z), minaret_height, size * 0.018)


# MARK: Monuments

def malwiya():
    """The spiral minaret of the Great Mosque of Samarra (848-852): 52 m, a square plinth 33 m wide,
    five counter-clockwise turns of ramp around a tapering core, a pavilion on top."""
    b = Builder()
    b.box(BRICK, (0, 1.5, 0), (33, 3, 33))
    b.box(BRICK, (0, 4, 0), (31, 2, 31))
    core = lambda y: 15.5 - (15.5 - 3.4) * min(y / 46.0, 1.0)  # noqa: E731
    b.lathe(BRICK, [(core(y), 5 + y) for y in np.linspace(0, 46, 24)], segments=40)
    b.helix_ramp(BRICK, lambda y: core(y - 5) if y >= 5 else core(0), 51, 5, 2.3, 2.2, steps=600, centre=(0, 0, 0))
    b.lathe(BRICK, [(3.6, 51), (3.6, 54.5), (3.2, 54.5)], segments=16)
    for k in range(8):
        a = 2 * math.pi * k / 8
        b.box(SHADOW, (3.62 * math.cos(a), 52.8, 3.62 * math.sin(a)), (0.9, 2.4, 0.3), -a + math.pi / 2)
    return b, 52.0


def ctesiphon():
    """Taq Kasra, Ctesiphon: the largest single-span brick vault, 37 m high and 25.5 m wide, 50 m deep,
    with the surviving south wing of its facade, a wall of tiered blind arcades."""
    b = Builder()
    b.box(MUD, (0, 0.5, 0), (70, 1, 60))
    b.arch_shell(BRICK, 25.5, 35.0, 3.0, 50, centre=(0, 1, -5), yaw=0)
    # Facade wing beside the arch, with five storeys of blind arches.
    b.box(BRICK, (-27, 1 + 17.5, 20), (26, 35, 4))
    for row in range(5):
        for col in range(6):
            b.box(SHADOW, (-37 + col * 4.1, 1 + 3.5 + row * 6.6, 22.05), (2.2, 4.2, 0.2))
    return b, 37.0


def ziggurat_ur():
    """The Ziggurat of Ur (21st century BC): a mud-brick base 64 x 46 m with sloping walls, two upper terraces,
    and three stairways meeting at a gate on the first terrace."""
    b = Builder()
    def terrace(w, d, y0, h, shrink):
        b.lathe(MUD, [(1, 0)], segments=4)  # placeholder to keep material ordering stable
    b.tris.pop(MUD, None)
    for (w, d, y0, h) in ((64, 46, 0, 11), (40, 28, 11, 5), (22, 16, 16, 4)):
        # A frustum with sloping sides, built as a 4-segment lathe stretched to the footprint.
        prof = [(1.0, 0), (0.93, h)]
        verts = []
        for r, y in prof:
            verts.append([((-w / 2) * r, y0 + y, (-d / 2) * r), ((w / 2) * r, y0 + y, (-d / 2) * r),
                          ((w / 2) * r, y0 + y, (d / 2) * r), ((-w / 2) * r, y0 + y, (d / 2) * r)])
        lo, hi = verts
        for k in range(4):
            b.quad(BRICK, lo[k], lo[(k + 1) % 4], hi[(k + 1) % 4], hi[k])
        b.quad(MUD, hi[3], hi[2], hi[1], hi[0])
    # Three stairways: one straight up the front, two along the facade.
    for k in range(20):
        y = k * 0.55
        b.box(MUD, (0, y + 0.27, 23 + 18 - k * 0.9), (7, 0.55, 0.9))
        b.box(MUD, (-20 + k * 0.85, y + 0.27, 23.6), (0.85, 0.55, 5))
        b.box(MUD, (20 - k * 0.85, y + 0.27, 23.6), (0.85, 0.55, 5))
    b.box(BRICK, (0, 13.5, 14), (8, 5, 3))  # the gatehouse
    b.box(SHADOW, (0, 13, 15.55), (3, 3.5, 0.2))
    return b, 24.0


def imam_husayn():
    b = Builder()
    shrine(b, 95, domes=1, minarets=2, minaret_height=36, dome_radius=10)
    return b, 57.0


def al_abbas():
    b = Builder()
    shrine(b, 80, domes=1, minarets=2, minaret_height=34, dome_radius=9)
    return b, 52.0


def imam_ali():
    b = Builder()
    shrine(b, 100, domes=1, minarets=2, minaret_height=38, dome_radius=11)
    return b, 60.0


def kadhimiya():
    b = Builder()
    shrine(b, 110, domes=2, minarets=4, minaret_height=38, dome_radius=8.5)
    return b, 58.0


def askari():
    b = Builder()
    shrine(b, 80, domes=1, minarets=2, minaret_height=36, dome_radius=11)
    return b, 68.0


def babylon_ishtar():
    """Babylon's Ishtar Gate (575 BC, reconstruction): twin crenellated towers in lapis-glazed brick
    flanking an arched passage, with bands of yellow-and-white tiles."""
    b = Builder()
    b.box(MUD, (0, 0.25, 0), (40, 0.5, 24))
    for x in (-8.5, 8.5):
        b.box(TILE_DARK, (x, 0.5 + 12, 0), (9, 24, 12))
        for k in range(6):
            b.box(TILE_DARK, (x - 3.6 + k * 1.45, 24.5 + 0.9, -6), (0.9, 1.8, 0.9))
            b.box(TILE_DARK, (x - 3.6 + k * 1.45, 24.5 + 0.9, 6), (0.9, 1.8, 0.9))
        for row in range(4):
            b.box(WHITE, (x, 3 + row * 5, 6.02), (8.6, 0.5, 0.1))
    b.box(TILE_DARK, (0, 0.5 + 15.5, 0), (8, 9, 12))  # above the passage, which stays open
    b.arch_shell(SHADOW, 5.0, 11.0, 0.3, 12.2, centre=(0, 0.5, 0), parabolic=False)
    return b, 25.0


HEROES = {
    "Q170047": malwiya, "Q593115": malwiya,  # Samarra and its Great Mosque
    "Q192541": ctesiphon,
    "Q5699": ziggurat_ur,
    "Q773704": imam_husayn,
    "Q3250647": al_abbas,
    "Q838359": imam_ali,
    "Q154116": kadhimiya,
    "Q309484": askari,
    "Q5684": babylon_ishtar,
}


def main(out_dir):
    out = Path(out_dir)
    catalog_path = out / "models.json"
    catalog = {e["id"]: e for e in json.load(open(catalog_path, encoding="utf-8"))}
    for qid, build in HEROES.items():
        builder, height = build()
        parts = builder.parts()
        # Normalise to 1 unit tall standing on y = 0, centred, like the generated models.
        allv = np.concatenate([p.vertices for p in parts])
        lo, hi = allv.min(0), allv.max(0)
        scale = 1.0 / (hi[1] - lo[1])
        for p in parts:
            p.vertices = (p.vertices - [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]) * scale
        target = out / f"{qid}.usdz"
        write_usdz(target, parts, roughness=0.9)
        data = target.read_bytes()
        entry = catalog.get(qid, {"id": qid, "photo": ""})
        entry.update({"file": target.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "height": height, "generator": "Hand-built from the monument's documented proportions"})
        catalog[qid] = entry
        tris = sum(len(p.indices) for p in parts)
        print(f"{qid:10} {build.__name__:16} {tris:6} triangles {len(data) // 1024:5} KB, {height} m")
    json.dump(list(catalog.values()), open(catalog_path, "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
