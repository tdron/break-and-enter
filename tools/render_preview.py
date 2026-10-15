#!/usr/bin/env python3
"""
Renders preview images of StealAnItem.rbxlx with a tiny software rasterizer,
so the map can be eyeballed without opening Roblox Studio.

Requires Pillow + NumPy (dev only):  pip install pillow numpy

    python3 tools/render_preview.py                       # default set of views -> docs/
    python3 tools/render_preview.py --view top --out map.png
    python3 tools/render_preview.py --camera 0,80,150 --target 60,0,-40 --out custom.png
"""

from __future__ import annotations

import argparse
import math
import os
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PART_CLASSES = {"Part", "WedgePart", "SpawnLocation", "VehicleSeat", "Seat", "TrussPart", "CornerWedgePart"}
SKY_TOP = np.array([110, 165, 230], dtype=np.float32)
SKY_BOTTOM = np.array([200, 225, 245], dtype=np.float32)


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_parts(path: str, skip_names: set[str]):
    tree = ET.parse(path)
    parts = []

    def walk(item, path_names):
        cls = item.get("class")
        props = item.find("Properties")
        values = {}
        name = ""
        if props is not None:
            for prop in props:
                values[prop.get("name")] = prop
            name_prop = values.get("Name")
            name = name_prop.text if name_prop is not None and name_prop.text else ""
        if cls in PART_CLASSES and name not in skip_names:
            cf = values.get("CFrame")
            size = values.get("size")
            if cf is not None and size is not None:
                pos = np.array([float(cf.find(k).text) for k in ("X", "Y", "Z")])
                rot = np.array([[float(cf.find(f"R{i}{j}").text) for j in range(3)] for i in range(3)])
                sz = np.array([float(size.find(k).text) for k in ("X", "Y", "Z")])
                color_prop = values.get("Color3uint8")
                packed = int(color_prop.text) if color_prop is not None else 0xFFA3A2A5
                color = np.array([(packed >> 16) & 255, (packed >> 8) & 255, packed & 255], dtype=np.float32)
                transparency = float(values["Transparency"].text) if "Transparency" in values else 0.0
                shape = int(values["shape"].text) if "shape" in values else 1
                material = int(values["Material"].text) if "Material" in values else 256
                if cls == "WedgePart":
                    shape = 3
                if transparency < 0.98:
                    parts.append((pos, rot, sz, color, transparency, shape, material))
        for child in item.findall("Item"):
            walk(child, path_names + [name])

    for root_item in tree.getroot().findall("Item"):
        walk(root_item, [])
    return parts


# ---------------------------------------------------------------------------
# Meshes in unit space (-0.5..0.5)
# ---------------------------------------------------------------------------

def box_mesh():
    v = np.array([[x, y, z] for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)])
    # index = xi*4 + yi*2 + zi
    faces = [
        (0, 1, 3, 2), (4, 6, 7, 5),  # -X, +X
        (0, 4, 5, 1), (2, 3, 7, 6),  # -Y, +Y
        (0, 2, 6, 4), (1, 5, 7, 3),  # -Z, +Z
    ]
    tris = []
    for a, b, c, d in faces:
        tris += [(a, b, c), (a, c, d)]
    return v, np.array(tris)


def wedge_mesh():
    # Bottom 4 corners, top edge along the back (+Z)
    v = np.array([
        [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5],
        [-0.5, 0.5, 0.5], [0.5, 0.5, 0.5],
    ])
    tris = [(0, 2, 1), (0, 3, 2),  # bottom
            (3, 4, 5), (3, 5, 2),  # back
            (0, 1, 5), (0, 5, 4),  # slope
            (0, 4, 3), (1, 2, 5)]  # sides
    return v, np.array(tris)


def cylinder_mesh(segments=14):
    verts = []
    for side in (-0.5, 0.5):
        for i in range(segments):
            a = 2 * math.pi * i / segments
            verts.append([side, math.cos(a) * 0.5, math.sin(a) * 0.5])
    verts.append([-0.5, 0, 0])
    verts.append([0.5, 0, 0])
    tris = []
    for i in range(segments):
        j = (i + 1) % segments
        tris += [(i, segments + i, segments + j), (i, segments + j, j)]
        tris.append((2 * segments, j, i))
        tris.append((2 * segments + 1, segments + i, segments + j))
    return np.array(verts), np.array(tris)


def sphere_mesh(rings=7, segments=12):
    verts = [[0, 0.5, 0]]
    for r in range(1, rings):
        phi = math.pi * r / rings
        for s in range(segments):
            theta = 2 * math.pi * s / segments
            verts.append([0.5 * math.sin(phi) * math.cos(theta), 0.5 * math.cos(phi), 0.5 * math.sin(phi) * math.sin(theta)])
    verts.append([0, -0.5, 0])
    tris = []
    for s in range(segments):
        tris.append((0, 1 + (s + 1) % segments, 1 + s))
    for r in range(rings - 2):
        for s in range(segments):
            a = 1 + r * segments + s
            b = 1 + r * segments + (s + 1) % segments
            c = a + segments
            d = b + segments
            tris += [(a, b, d), (a, d, c)]
    last = len(verts) - 1
    base = 1 + (rings - 2) * segments
    for s in range(segments):
        tris.append((last, base + s, base + (s + 1) % segments))
    return np.array(verts), np.array(tris)


MESHES = {1: box_mesh(), 3: wedge_mesh(), 2: cylinder_mesh(), 0: sphere_mesh(), 4: wedge_mesh()}


# ---------------------------------------------------------------------------
# Rasterizer
# ---------------------------------------------------------------------------

class Camera:
    def __init__(self, eye, target, fov=55.0, ortho=None, width=1600, height=1000):
        self.eye = np.array(eye, dtype=np.float64)
        self.target = np.array(target, dtype=np.float64)
        forward = self.target - self.eye
        forward /= np.linalg.norm(forward)
        up = np.array([0.0, 1.0, 0.0])
        if abs(forward @ up) > 0.99:
            up = np.array([0.0, 0.0, -1.0])
        right = np.cross(forward, up)
        right /= np.linalg.norm(right)
        true_up = np.cross(right, forward)
        self.basis = np.stack([right, true_up, forward])  # rows
        self.fov = fov
        self.ortho = ortho  # half-height in studs for orthographic views
        self.w, self.h = width, height

    def to_view(self, pts):
        return (pts - self.eye) @ self.basis.T  # x right, y up, z forward

    def project(self, view):
        if self.ortho:
            scale = self.h / 2 / self.ortho
            sx = self.w / 2 + view[:, 0] * scale
            sy = self.h / 2 - view[:, 1] * scale
        else:
            f = self.h / 2 / math.tan(math.radians(self.fov) / 2)
            sx = self.w / 2 + view[:, 0] * f / view[:, 2]
            sy = self.h / 2 - view[:, 1] * f / view[:, 2]
        return sx, sy


def clip_triangle(tri, near):
    """Clip a view-space triangle against z = near. Returns a list of triangles."""
    inside = [p for p in tri if p[2] >= near]
    if len(inside) == 3:
        return [tri]
    if not inside:
        return []
    poly = []
    for i in range(3):
        a, b = tri[i], tri[(i + 1) % 3]
        a_in, b_in = a[2] >= near, b[2] >= near
        if a_in:
            poly.append(a)
        if a_in != b_in:
            t = (near - a[2]) / (b[2] - a[2])
            poly.append(a + (b - a) * t)
    return [np.array([poly[0], poly[i], poly[i + 1]]) for i in range(1, len(poly) - 1)]


def render(parts, camera: Camera, out_path: str, sun=(-0.45, 0.8, -0.35)):
    w, h = camera.w, camera.h
    zbuf = np.full((h, w), np.inf, dtype=np.float32)
    img = np.zeros((h, w, 3), dtype=np.float32)
    grad = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    img[:] = SKY_TOP * (1 - grad) + SKY_BOTTOM * grad
    sun_dir = np.array(sun) / np.linalg.norm(sun)
    near = 0.5
    transparent = []

    def draw(tri_view, color, alpha):
        for tri in clip_triangle(tri_view, near) if not camera.ortho else [tri_view]:
            sx, sy = camera.project(tri)
            depth = tri[:, 2]
            x0, x1 = int(max(0, math.floor(sx.min()))), int(min(w - 1, math.ceil(sx.max())))
            y0, y1 = int(max(0, math.floor(sy.min()))), int(min(h - 1, math.ceil(sy.max())))
            if x0 > x1 or y0 > y1:
                continue
            xs = np.arange(x0, x1 + 1) + 0.5
            ys = np.arange(y0, y1 + 1) + 0.5
            px, py = np.meshgrid(xs, ys)
            (ax, bx, cx), (ay, by, cy) = sx, sy
            denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(denom) < 1e-9:
                continue
            l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / denom
            l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / denom
            l3 = 1 - l1 - l2
            mask = (l1 >= -1e-4) & (l2 >= -1e-4) & (l3 >= -1e-4)
            if not mask.any():
                continue
            if camera.ortho:
                z = l1 * depth[0] + l2 * depth[1] + l3 * depth[2]
            else:
                inv = l1 / depth[0] + l2 / depth[1] + l3 / depth[2]
                z = 1 / np.maximum(inv, 1e-9)
            region = zbuf[y0:y1 + 1, x0:x1 + 1]
            visible = mask & (z < region)
            if not visible.any():
                continue
            target = img[y0:y1 + 1, x0:x1 + 1]
            if alpha >= 0.999:
                region[visible] = z[visible]
                target[visible] = color
            else:
                target[visible] = target[visible] * (1 - alpha) + color * alpha

    for pos, rot, size, color, transparency, shape, material in parts:
        verts, tris = MESHES.get(shape, MESHES[1])
        if shape == 0:
            size = np.full(3, size.min())
        world = (verts * size) @ rot.T + pos
        view = camera.to_view(world)
        normals_world = []
        for tri in tris:
            a, b, c = world[tri[0]], world[tri[1]], world[tri[2]]
            n = np.cross(b - a, c - a)
            norm = np.linalg.norm(n)
            normals_world.append(n / norm if norm > 1e-12 else np.array([0, 1, 0]))
        base = color.copy()
        if material == 288:  # Neon glows
            base = np.minimum(base * 1.25 + 30, 255)
        for tri, n in zip(tris, normals_world):
            tv = view[tri]
            # back-face culling (meshes are wound consistently enough; keep both for thin parts)
            light = 0.55 + 0.45 * max(0.0, float(n @ sun_dir)) + 0.1 * abs(float(n[1]))
            if material == 288:
                light = 1.0
            shade = np.clip(base * light, 0, 255)
            if transparency > 0.05:
                transparent.append((float(tv[:, 2].mean()), tv, shade, 1 - transparency))
            else:
                draw(tv, shade, 1.0)
    transparent.sort(key=lambda item: -item[0])
    for _, tv, shade, alpha in transparent:
        draw(tv, shade, max(0.15, alpha))

    # Distance fog for depth
    if not camera.ortho:
        fog = np.clip((zbuf - 250) / 900, 0, 0.55)[..., None]
        fog[np.isinf(zbuf)] = 0
        img = img * (1 - fog) + SKY_BOTTOM * fog
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_path)
    print(f"wrote {os.path.relpath(out_path, ROOT)}")


ROOF_PARTS = ["Roof", "Gable", "RoofRidge", "RoofTrim", "Chimney", "PorchRoof", "Chandelier", "Crystal", "CeilingLamp",
              "PorticoRoof", "Pediment", "Leaves"]

VIEWS = {
    "overview": dict(eye=(-780, 340, 470), target=(-40, 0, -20), fov=40),
    "top": dict(eye=(45, 900, 0.01), target=(45, 0, 0), ortho=230),
    "yard": dict(eye=(-96, 138, 196), target=(-322, 0, -8), fov=55),
    "warehouse": dict(eye=(-296, 34, -18), target=(-357, 8, -114), fov=55),
    "treadmill": dict(eye=(-344, 12, -66), target=(-384, 3, -110), fov=52),
    "houses": dict(eye=(-12, 42, 8), target=(170, 4, -8), fov=55),
    "interior": dict(eye=(230, 64, -6), target=(230, 0, -62), fov=62, hide=ROOF_PARTS),
    "mansion": dict(eye=(452, 58, 8), target=(600, 8, 0), fov=55),
    "cutaway": dict(eye=(545, 85, 0.01), target=(606, 0, 0), fov=66, hide=ROOF_PARTS),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--place", default=os.path.join(ROOT, "StealAnItem.rbxlx"))
    parser.add_argument("--view", choices=sorted(VIEWS), action="append")
    parser.add_argument("--camera", help="eye x,y,z")
    parser.add_argument("--target", help="target x,y,z")
    parser.add_argument("--fov", type=float, default=55)
    parser.add_argument("--hide", action="append", default=[], help="part names to skip (e.g. Roof)")
    parser.add_argument("--out", help="output file (single view)")
    parser.add_argument("--outdir", default=os.path.join(ROOT, "docs"))
    parser.add_argument("--size", default="1600x1000")
    args = parser.parse_args()

    width, height = (int(v) for v in args.size.split("x"))
    parse_cache: dict[tuple, list] = {}

    def parts_for(hidden: list[str]):
        key = tuple(sorted(set(args.hide) | set(hidden)))
        if key not in parse_cache:
            parse_cache[key] = parse_parts(args.place, set(key) | {"Zone"})
        return parse_cache[key]

    parts = parts_for([])
    print(f"{len(parts)} visible parts")
    os.makedirs(args.outdir, exist_ok=True)
    if args.camera:
        eye = [float(v) for v in args.camera.split(",")]
        target = [float(v) for v in args.target.split(",")]
        render(parts, Camera(eye, target, args.fov, width=width, height=height), args.out or "custom.png")
        return
    for name in args.view or ["overview", "top", "yard", "warehouse", "houses", "interior", "mansion"]:
        cfg = VIEWS[name]
        cam = Camera(cfg["eye"], cfg["target"], cfg.get("fov", 55), cfg.get("ortho"), width, height)
        out = args.out if (args.out and args.view and len(args.view) == 1) else os.path.join(args.outdir, f"preview-{name}.png")
        render(parts_for(cfg.get("hide", [])), cam, out)


if __name__ == "__main__":
    main()
