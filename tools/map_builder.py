"""
Procedurally builds the Steal an Item town into Workspace.Map.

Layout (top-down, X = east, Z = south, the main street runs along Z = 0):

    west  [THE YARD: 6 garages in a U + spawn parking lot + 2 market stalls] -- [10 houses, alternating sides] -- [MANSION]  east

The yard is the spawn area. Two garages sit on each of three sides of a paved
parking lot, the two market stalls stand back to back in the middle and a cube
cliff wraps the three closed sides. Only the road east leaves the yard, and the
cliffs follow it, narrowing into the canyon street where the houses stand.
Every house uses the same design (only the paint changes) and backs onto the
same style of rocky cliff, so the street feels like a canyon that gets harder
the further east you go.

Everything the game scripts rely on is named/attributed exactly as the server
expects (see the header comments in src/server/*.luau).
"""

from __future__ import annotations

import math
import os
import random
import re

from rbxlx import C3, CF, V3, C3u8, Float, FontFace, Inst, Int, OptionalCF, Token, UD2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- Enum values (validated against the Roblox API by tools/validate_place.py) ---
MATERIALS = {
    "Plastic": 256, "SmoothPlastic": 272, "Neon": 288, "Wood": 512, "WoodPlanks": 528,
    "Marble": 784, "Slate": 800, "Concrete": 816, "Limestone": 820, "Granite": 832,
    "Pavement": 836, "Brick": 848, "Pebble": 864, "Cobblestone": 880, "Rock": 896,
    "Sandstone": 912, "CorrodedMetal": 1040, "DiamondPlate": 1056, "Metal": 1088,
    "Grass": 1280, "LeafyGrass": 1284, "Sand": 1296, "Fabric": 1312, "Asphalt": 1376,
    "Glass": 1568, "Carpet": 2305, "CeramicTiles": 2306, "ClayRoofTiles": 2307,
    "RoofShingles": 2308, "Plaster": 2310, "Rubber": 2311,
}
SHAPES = {"Ball": 0, "Block": 1, "Cylinder": 2, "Wedge": 3, "CornerWedge": 4}
FACES = {"Right": 0, "Top": 1, "Back": 2, "Left": 3, "Bottom": 4, "Front": 5}
FONTS = {
    "Fredoka": "rbxasset://fonts/families/FredokaOne.json",
    "Luckiest": "rbxasset://fonts/families/LuckiestGuy.json",
    "Builder": "rbxasset://fonts/families/BuilderSans.json",
}

# Yaw (degrees) that makes a piece whose front is local -Z face the given direction.
YAW = {"n": 0, "s": 180, "e": -90, "w": 90}

# --- Palette ---
WHITE = (245, 245, 242)
OFFWHITE = (232, 228, 218)
BLACK = (24, 24, 28)
DARK = (46, 48, 54)
GOLD = (255, 196, 54)
GLASS = (170, 210, 235)
WOOD = (150, 105, 66)
WOOD_DARK = (92, 60, 38)
WOOD_LIGHT = (196, 160, 112)
STONE = (150, 150, 155)
GRASS = (86, 156, 70)
LEAF = (64, 140, 58)
LEAF_DARK = (44, 112, 48)
ASPHALT = (48, 50, 55)
SIDEWALK = (196, 196, 190)
CONCRETE = (170, 170, 168)
YELLOW = (250, 205, 40)
RED = (200, 40, 40)


def _config_text() -> str:
    with open(os.path.join(ROOT, "src", "shared", "Config.luau"), encoding="utf-8") as handle:
        return handle.read()


def read_house_tiers() -> list[dict]:
    """Reads tier names / stars / lockpick times from Config.luau so signs always match the game."""
    text = _config_text()
    block = text[text.index("Config.HouseTiers = {"):]
    block = block[: block.index("} :: { HouseTier }")]
    tiers = []
    for chunk in block.split("Name = ")[1:]:
        tiers.append({
            "name": re.match(r'"([^"]+)"', chunk).group(1),
            "stars": int(re.search(r"Stars = (\d+)", chunk).group(1)),
            "lockpick": float(re.search(r"LockpickTime = ([\d.]+)", chunk).group(1)),
        })
    return tiers


def read_houses() -> list[dict]:
    """The street, in order, from Config.Houses (one house per line) joined with Config.Guards."""
    text = _config_text()
    guards = {}
    for gid, name, kind, icon, speed in re.findall(
            r'^\t(\w+) = \{ DisplayName = "([^"]+)", Kind = "(\w+)", Icon = "([^"]+)", Speed = (\d+) \},$',
            text, re.M):
        guards[gid] = {"id": gid, "name": name, "kind": kind, "icon": icon, "speed": int(speed)}
    houses = []
    for hid, display, tier, guard, count in re.findall(
            r'^\t\{ Id = "(\w+)", DisplayName = "([^"]+)", Tier = (\d+), Guard = "(\w+)"'
            r'(?:, GuardCount = (\d+))? \},$', text, re.M):
        houses.append({"id": hid, "display": display, "tier": int(tier), "guard": guards[guard],
                       "count": int(count) if count else 1})
    assert houses and houses[-1]["id"] == "Mansion", "Config.Houses must end with the Mansion"
    return houses


def speed_text(value: float) -> str:
    """Guard speeds on the yard signs: 10, 1,200, 17,500, 1.1M, 125M."""
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}".rstrip("0").rstrip(".") + "M"
    return f"{value:,.0f}"

def part(parent: Inst, name: str, size, cf: CF, color, material: str = "SmoothPlastic", *,
         cls: str = "Part", shape: str | None = None, collide: bool = True, transparency: float = 0.0,
         reflectance: float = 0.0, shadow: bool = True, query: bool = True, touch: bool = True) -> Inst:
    inst = Inst(cls, name, parent)
    props = {
        "size": _v3(size),
        "CFrame": cf,
        "Color3uint8": C3u8(*color),
        "Material": Token(MATERIALS[material]),
        "Anchored": True,
        "TopSurface": Token(0),
        "BottomSurface": Token(0),
    }
    if shape and cls == "Part":
        props["shape"] = Token(SHAPES[shape])
    if not collide:
        props["CanCollide"] = False
    if transparency:
        props["Transparency"] = Float(transparency)
    if reflectance:
        props["Reflectance"] = Float(reflectance)
    if not shadow:
        props["CastShadow"] = False
    if not query:
        props["CanQuery"] = False
    if not touch:
        props["CanTouch"] = False
    inst.set(**props)
    return inst


def _v3(size):
    return V3(float(size[0]), float(size[1]), float(size[2]))


def marker(parent: Inst, name: str, cf: CF, size=(0.5, 0.2, 0.5)) -> Inst:
    """Invisible, non-interactive helper part."""
    return part(parent, name, size, cf, (255, 220, 0), transparency=1, collide=False, query=False,
                touch=False, shadow=False)


def surface_text(target: Inst, face: str, text: str, *, color=(255, 255, 255), font: str = "Fredoka",
                 weight: int = 400, pixels_per_stud: float = 40, stroke: float | None = 0.6,
                 background=None, rich: bool = False, label_name: str = "Label", wrapped: bool = True) -> Inst:
    gui = Inst("SurfaceGui", "SurfaceGui", target)
    gui.set(
        Face=Token(FACES[face]),
        SizingMode=Token(1),  # PixelsPerStud
        PixelsPerStud=Float(pixels_per_stud),
        LightInfluence=Float(0),
    )
    if background is not None:
        backdrop = Inst("Frame", "Background", gui)
        backdrop.set(Size=UD2(1, 0, 1, 0), BackgroundColor3=C3.rgb(*background), BorderSizePixel=Int(0))
    label = Inst("TextLabel", label_name, gui)
    props = {
        "Size": UD2(0.92, 0, 0.86, 0),
        "Position": UD2(0.04, 0, 0.07, 0),
        "BackgroundTransparency": Float(1),
        "BorderSizePixel": Int(0),
        "Text": text,
        "TextColor3": C3.rgb(*color),
        "TextScaled": True,
        "TextWrapped": wrapped,
        "RichText": rich,
        "FontFace": FontFace(FONTS[font], weight, "Normal"),
    }
    if stroke is not None:
        props["TextStrokeTransparency"] = Float(stroke)
        props["TextStrokeColor3"] = C3.rgb(20, 20, 26)
    label.set(**props)
    return label


def point_light(parent: Inst, color=(255, 236, 200), brightness: float = 1.0, light_range: float = 18,
                shadows: bool = False) -> Inst:
    light = Inst("PointLight", "Light", parent)
    light.set(Color=C3.rgb(*color), Brightness=Float(brightness), Range=Float(light_range), Shadows=shadows)
    return light


def model(parent: Inst, name: str, pivot: CF | None = None) -> Inst:
    inst = Inst("Model", name, parent)
    if pivot is not None:
        inst.set(WorldPivotData=OptionalCF(pivot))
    return inst


def tree(parent: Inst, base: CF, scale: float = 1.0, kind: str = "round") -> Inst:
    m = model(parent, "Tree", base)
    trunk_h = 7 * scale
    part(m, "Trunk", (1.4 * scale, trunk_h, 1.4 * scale), base * CF(0, trunk_h / 2, 0), WOOD_DARK, "Wood")
    if kind == "pine":
        for i, (w, y) in enumerate(((8, 0.45), (6.2, 0.75), (4.2, 1.05))):
            part(m, "Leaves", (w * scale, 4 * scale, w * scale), base * CF(0, trunk_h * y + 3 * scale, 0) * CF.deg(0, 45 * i, 0),
                 LEAF_DARK, "LeafyGrass", collide=False)
    else:
        part(m, "Leaves", (9 * scale, 9 * scale, 9 * scale), base * CF(0, trunk_h + 3 * scale, 0), LEAF, "LeafyGrass",
             shape="Ball", collide=False)
        part(m, "Leaves", (6 * scale, 6 * scale, 6 * scale), base * CF(2.5 * scale, trunk_h + 1.5 * scale, 1.5 * scale),
             LEAF_DARK, "LeafyGrass", shape="Ball", collide=False)
        part(m, "Leaves", (6 * scale, 6 * scale, 6 * scale), base * CF(-2.2 * scale, trunk_h + 2.0 * scale, -1.8 * scale),
             (76, 150, 62), "LeafyGrass", shape="Ball", collide=False)
    return m


def bush(parent: Inst, base: CF, size: float = 3.0, color=LEAF) -> Inst:
    return part(parent, "Bush", (size, size * 0.8, size), base * CF(0, size * 0.3, 0), color, "LeafyGrass",
                shape="Ball", collide=False)


def street_lamp(parent: Inst, base: CF) -> Inst:
    m = model(parent, "StreetLamp", base)
    part(m, "Pole", (0.6, 15, 0.6), base * CF(0, 7.5, 0), DARK, "Metal")
    part(m, "Base", (1.4, 1, 1.4), base * CF(0, 0.5, 0), DARK, "Metal")
    part(m, "Arm", (0.4, 0.4, 4), base * CF(0, 14.8, -1.8), DARK, "Metal")
    lamp = part(m, "Lamp", (1.4, 0.6, 2.2), base * CF(0, 14.4, -3.6), (255, 236, 180), "Neon", collide=False)
    point_light(lamp, (255, 220, 160), 0.8, 26)
    return m


# ---------------------------------------------------------------------------
# House builder
# ---------------------------------------------------------------------------

def door_opening(at: float, width: float = 5.0, height: float = 8.0) -> dict:
    return {"at": at, "w": width, "bottom": 0.0, "top": height, "kind": "door"}


def window(at: float, width: float = 5.0, bottom: float = 3.4, top: float = 7.6) -> dict:
    return {"at": at, "w": width, "bottom": bottom, "top": top, "kind": "window"}


def doorway(at: float, width: float = 5.0, height: float = 8.5) -> dict:
    return {"at": at, "w": width, "bottom": 0.0, "top": height, "kind": "gap"}


class HouseBuilder:
    FLOOR_Y = 0.7  # top of the interior floor (sits on a 0.5 stud foundation)

    def __init__(self, folder: Inst, name: str, display: str, tier: int, lot_cf: CF, lot_w: float, lot_d: float,
                 house_w: float, house_d: float, wall_h: float, front_yard: float):
        self.lot_cf = lot_cf
        self.lot_w, self.lot_d = lot_w, lot_d
        self.W, self.D, self.H = house_w, house_d, wall_h
        self.hz = lot_d / 2 - front_yard - house_d / 2
        self.cf = lot_cf * CF(0, 0, self.hz)
        self.model = model(folder, name, self.cf)
        self.model.attr(Tier=tier, DisplayName=display)
        self.structure = model(self.model, "Structure", self.cf)
        self.furniture = model(self.model, "Furniture", self.cf)
        self.yard = model(self.model, "Yard", lot_cf)
        self.spots = Inst("Folder", "ItemSpots", self.model)
        self.docks = Inst("Folder", "GuardDocks", self.model)
        self.doors = Inst("Folder", "Doors", self.model)
        self.sirens = Inst("Folder", "Sirens", self.model)
        self.lasers = Inst("Folder", "Lasers", self.model)
        self.spot_count = 0
        self.spot_budget: int | None = None  # stop adding loot spots after this many (furniture stays)
        self.laser_count = 0
        zone = part(self.model, "Zone", (lot_w, 40, lot_d), lot_cf * CF(0, 20, 0), (255, 60, 60), transparency=1,
                    collide=False, query=False, touch=False, shadow=False)
        # How far the front wall sits inside the property: the server uses this to tell whether a
        # defender is still indoors (where everyone moves at the standard Roblox speed) or outside.
        zone.attr(FrontInset=front_yard)

    # -- generic placement -------------------------------------------------
    def p(self, name, size, pos, color, material="SmoothPlastic", rot=None, parent=None, frame=None, **kw) -> Inst:
        base = frame if frame is not None else self.cf
        cf = base * CF(*pos)
        if rot:
            cf = cf * CF.deg(*rot)
        return part(parent if parent is not None else self.structure, name, size, cf, color, material, **kw)

    def y(self, name, size, pos, color, material="SmoothPlastic", rot=None, **kw) -> Inst:
        """Part in lot coordinates (yard)."""
        return self.p(name, size, pos, color, material, rot, parent=self.yard, frame=self.lot_cf, **kw)

    def frame(self, x: float, z: float, facing: str, y: float | None = None) -> CF:
        return self.cf * CF(x, self.FLOOR_Y if y is None else y, z) * CF.deg(0, YAW[facing], 0)

    # -- shell ---------------------------------------------------------------
    @staticmethod
    def _segments(s0: float, s1: float, h: float, openings: list[dict]):
        out = []
        cursor = s0
        for o in sorted(openings, key=lambda item: item["at"]):
            a, b = o["at"] - o["w"] / 2, o["at"] + o["w"] / 2
            if a > cursor:
                out.append((cursor, a, 0.0, h, "solid"))
            if o["bottom"] > 0:
                out.append((a, b, 0.0, o["bottom"], "solid"))
            if o["top"] < h:
                out.append((a, b, o["top"], h, "solid"))
            if o["kind"] == "window":
                out.append((a, b, o["bottom"], o["top"], "window"))
            cursor = b
        if cursor < s1:
            out.append((cursor, s1, 0.0, h, "solid"))
        return out

    def wall_x(self, z, x0, x1, t, h, openings, color, material, name="Wall"):
        for a, b, y0, y1, kind in self._segments(x0, x1, h, openings):
            if b - a < 0.01 or y1 - y0 < 0.01:
                continue
            if kind == "window":
                self.p("Window", (b - a, y1 - y0, 0.3), ((a + b) / 2, (y0 + y1) / 2, z), GLASS, "Glass",
                       transparency=0.55, reflectance=0.15)
                self.p("Sill", (b - a + 0.6, 0.3, t + 0.5), ((a + b) / 2, y0 - 0.15, z), WHITE, "SmoothPlastic")
            else:
                self.p(name, (b - a, y1 - y0, t), ((a + b) / 2, (y0 + y1) / 2, z), color, material)

    def wall_z(self, x, z0, z1, t, h, openings, color, material, name="Wall"):
        for a, b, y0, y1, kind in self._segments(z0, z1, h, openings):
            if b - a < 0.01 or y1 - y0 < 0.01:
                continue
            if kind == "window":
                self.p("Window", (0.3, y1 - y0, b - a), (x, (y0 + y1) / 2, (a + b) / 2), GLASS, "Glass",
                       transparency=0.55, reflectance=0.15)
                self.p("Sill", (t + 0.5, 0.3, b - a + 0.6), (x, y0 - 0.15, (a + b) / 2), WHITE, "SmoothPlastic")
            else:
                self.p(name, (t, y1 - y0, b - a), (x, (y0 + y1) / 2, (a + b) / 2), color, material)

    def exterior(self, t, color, material, front, back, left, right):
        W, D, H = self.W, self.D, self.H
        self.t = t
        self.wall_x(D / 2 - t / 2, -W / 2, W / 2, t, H, front, color, material, "FrontWall")
        self.wall_x(-D / 2 + t / 2, -W / 2, W / 2, t, H, back, color, material, "BackWall")
        self.wall_z(-W / 2 + t / 2, -D / 2 + t, D / 2 - t, t, H, left, color, material, "SideWall")
        self.wall_z(W / 2 - t / 2, -D / 2 + t, D / 2 - t, t, H, right, color, material, "SideWall")
        # Foundation the floor sits on
        self.p("Foundation", (W + 0.6, 0.5, D + 0.6), (0, 0.25, 0), (120, 118, 112), "Concrete")

    def floor(self, color, material="WoodPlanks"):
        self.p("Floor", (self.W - 0.2, 0.2, self.D - 0.2), (0, self.FLOOR_Y - 0.1, 0), color, material)

    def room_floor(self, x0, x1, z0, z1, color, material):
        self.p("RoomFloor", (x1 - x0, 0.04, z1 - z0), ((x0 + x1) / 2, self.FLOOR_Y + 0.02, (z0 + z1) / 2), color,
               material, collide=False)

    def gable_roof(self, rise, overhang, color, material="RoofShingles", gable_color=None):
        W, D, H = self.W, self.D, self.H
        half = D / 2 + overhang
        roof_w = W + overhang * 2
        # Back slope (ridge at z=0): a WedgePart's tall face is on its local +Z side.
        self.p("Roof", (roof_w, rise, half), (0, H + rise / 2, -half / 2), color, material, cls="WedgePart")
        self.p("Roof", (roof_w, rise, half), (0, H + rise / 2, half / 2), color, material, rot=(0, 180, 0),
               cls="WedgePart")
        self.p("RoofRidge", (roof_w, 0.5, 0.9), (0, H + rise + 0.05, 0), DARK, "Slate")
        gable = gable_color or self.wall_color
        for sx in (-1, 1):
            x = sx * (W / 2 - self.t / 2)
            self.p("Gable", (self.t, rise, D / 2), (x, H + rise / 2, -D / 4), gable, self.wall_material,
                   cls="WedgePart")
            self.p("Gable", (self.t, rise, D / 2), (x, H + rise / 2, D / 4), gable, self.wall_material,
                   rot=(0, 180, 0), cls="WedgePart")

    def flat_roof(self, overhang, color, thickness=1.2):
        W, D, H = self.W, self.D, self.H
        self.p("Roof", (W + overhang * 2, thickness, D + overhang * 2), (0, H + thickness / 2, 0), color, "Concrete")
        self.p("RoofTrim", (W + overhang * 2 + 0.4, 0.5, D + overhang * 2 + 0.4), (0, H + thickness + 0.25, 0),
               (60, 62, 68), "Metal")

    def ceiling(self, color=(236, 234, 228)):
        self.p("Ceiling", (self.W - 0.2, 0.3, self.D - 0.2), (0, self.H - 0.15, 0), color, "Plaster")

    # -- doors, sirens, lasers, spots, docks ------------------------------------
    def door(self, axis, coord, at, width, top, outward, color=WOOD, hinge="low", name="Door", step=True):
        """A pickable door filling an opening (opening top = `top`). axis 'x' = wall along X at z=coord."""
        m = model(self.doors, name, self.cf)
        bottom = self.FLOOR_Y
        height = top - bottom - 0.05
        if step:
            # A low doorstep outside so walking in is smooth.
            depth = 1.6
            offset = outward * (self.t / 2 + depth / 2)
            if axis == "x":
                self.p("Doorstep", (width + 1.2, 0.35, depth), (at, 0.175, coord + offset), (140, 138, 132), "Concrete")
            else:
                self.p("Doorstep", (depth, 0.35, width + 1.2), (coord + offset, 0.175, at), (140, 138, 132), "Concrete")
        sign = -1 if hinge == "low" else 1
        hinge_at = at + sign * width / 2
        knob_at = at - sign * (width / 2 - 0.6)
        if axis == "x":
            self.p("Hinge", (0.2, 0.2, 0.2), (hinge_at, bottom + height / 2, coord), BLACK, parent=m, transparency=1,
                   collide=False, query=False, touch=False, shadow=False)
            self.p("Panel", (width - 0.12, height - 0.2, 0.35), (at, bottom + (height - 0.2) / 2, coord), color, "Wood",
                   parent=m)
            for side in (-1, 1):
                self.p("Knob", (0.35, 0.35, 0.35), (knob_at, bottom + 3.4, coord + side * 0.3), GOLD, "Metal", parent=m,
                       shape="Ball", collide=False)
            # Panel extends from the hinge toward +X (low hinge) or -X (high hinge).
            if hinge == "low":
                angle = -95 if outward > 0 else 95
            else:
                angle = 95 if outward > 0 else -95
        else:
            self.p("Hinge", (0.2, 0.2, 0.2), (coord, bottom + height / 2, hinge_at), BLACK, parent=m, transparency=1,
                   collide=False, query=False, touch=False, shadow=False)
            self.p("Panel", (0.35, height - 0.2, width - 0.12), (coord, bottom + (height - 0.2) / 2, at), color, "Wood",
                   parent=m)
            for side in (-1, 1):
                self.p("Knob", (0.35, 0.35, 0.35), (coord + side * 0.3, bottom + 3.4, knob_at), GOLD, "Metal", parent=m,
                       shape="Ball", collide=False)
            if hinge == "low":
                angle = 95 if outward > 0 else -95
            else:
                angle = -95 if outward > 0 else 95
        m.attr(OpenAngle=float(angle))
        return m

    def siren(self, pos, rot=None):
        s = self.p("Siren", (1.6, 0.8, 0.8), pos, (90, 10, 10), "Neon", rot=rot, parent=self.sirens, collide=False)
        return s

    def laser(self, start, end, phase):
        (x0, y, z0), (x1, _, z1) = start, end
        length = math.hypot(x1 - x0, z1 - z0)
        yaw = math.degrees(math.atan2(-(z1 - z0), x1 - x0))
        self.laser_count += 1
        beam = self.p(f"Laser{self.laser_count}", (length, 0.18, 0.18), ((x0 + x1) / 2, y, (z0 + z1) / 2),
                      (255, 30, 30), "Neon", rot=(0, yaw, 0), parent=self.lasers, collide=False, query=False,
                      transparency=0.2, shadow=False)
        beam.attr(Phase=float(phase))
        for (x, z) in ((x0, z0), (x1, z1)):
            self.p("LaserEmitter", (0.6, 0.6, 0.6), (x, y, z), DARK, "Metal", collide=False)
        return beam

    def spot(self, frame: CF):
        if self.spot_budget is not None and self.spot_count >= self.spot_budget:
            return
        self.spot_count += 1
        marker(self.spots, f"Spot{self.spot_count}", frame, (0.6, 0.1, 0.6))

    def dock(self, x, z, facing="n"):
        """A drone charging pad (the guard hovers above it)."""
        f = self.frame(x, z, facing)
        d = part(self.docks, "Dock", (2.6, 0.3, 2.6), f * CF(0, 0.15, 0), DARK, "Metal", collide=False)
        part(self.furniture, "DockRing", (0.1, 2.0, 2.0), f * CF(0, 0.33, 0) * CF.deg(0, 0, 90), (60, 200, 255), "Neon",
             shape="Cylinder", collide=False, query=False)
        return d

    def pet_bed(self, x, z, facing, kind, size=3.2, color=(170, 60, 60)):
        """A round pet bed; the (invisible) Dock part on top is where the cat/dog sleeps, facing `facing`."""
        f = self.frame(x, z, facing)
        fur = self.furniture
        cushion = tuple(min(255, c + 70) for c in color)
        part(fur, "PetBed", (0.55, size, size), f * CF(0, 0.275, 0) * CF.deg(0, 0, 90), color, "Fabric",
             shape="Cylinder", collide=False)
        part(fur, "PetCushion", (0.3, size * 0.74, size * 0.74), f * CF(0, 0.5, 0) * CF.deg(0, 0, 90), cushion,
             "Fabric", shape="Cylinder", collide=False)
        d = part(self.docks, "Dock", (size * 0.7, 0.2, size * 0.7), f * CF(0, 0.55, 0), cushion, transparency=1,
                 collide=False, query=False, touch=False, shadow=False)
        # Food bowl beside the bed
        bowl = f * CF(size / 2 + 1.0, 0, -0.6)
        part(fur, "PetBowl", (0.5, 1.2, 1.2), bowl * CF(0, 0.25, 0) * CF.deg(0, 0, 90), (60, 120, 220), "SmoothPlastic",
             shape="Cylinder", collide=False)
        part(fur, "PetFood", (0.1, 0.9, 0.9), bowl * CF(0, 0.48, 0) * CF.deg(0, 0, 90), (150, 96, 50), "Pebble",
             shape="Cylinder", collide=False)
        if kind == "Dog":
            toy = f * CF(-size / 2 - 0.8, 0.22, 0.4) * CF.deg(0, 30, 0)
            part(fur, "ChewBone", (1.1, 0.24, 0.24), toy, (245, 240, 225), collide=False)
            for sx in (-0.55, 0.55):
                for sz in (-0.13, 0.13):
                    part(fur, "ChewBone", (0.3, 0.3, 0.3), toy * CF(sx, 0, sz), (245, 240, 225), shape="Ball",
                         collide=False)
        else:
            post = f * CF(-size / 2 - 1.0, 0, 0.6)
            part(fur, "ScratchPost", (2.6, 0.6, 0.6), post * CF(0, 1.4, 0) * CF.deg(0, 0, 90), (214, 186, 140), "Fabric",
                 shape="Cylinder", collide=False)
            part(fur, "ScratchBase", (1.6, 0.2, 1.6), post * CF(0, 0.1, 0), cushion, "Fabric", collide=False)
            part(fur, "ScratchTop", (1.3, 0.2, 1.3), post * CF(0, 2.8, 0), cushion, "Fabric", collide=False)
        return d

    def chair_post(self, f: CF, wizard: bool):
        """A reading chair for the people; the wizard gets a cauldron and a shelf of books."""
        self.chair_at(f, (92, 64, 46) if wizard else WOOD_DARK)
        fur = self.furniture
        if wizard:
            part(fur, "Cauldron", (2.1, 1.8, 1.8), f * CF(3.4, 0.9, 0.4) * CF.deg(0, 0, 90), (48, 50, 58), "Metal",
                 shape="Cylinder")
            part(fur, "CauldronBrew", (0.3, 1.7, 1.7), f * CF(3.4, 1.55, 0.4) * CF.deg(0, 0, 90), (110, 240, 120),
                 "Neon", shape="Cylinder", collide=False)
            part(fur, "BrewLight", (0.4, 0.4, 0.4), f * CF(3.4, 2.4, 0.4), (150, 255, 170), "Neon", shape="Ball",
                 collide=False)
            for i in range(3):
                part(fur, "SpellBook", (0.5, 1.5, 1.9),
                     f * CF(-2.6, 0.3 + i * 0.32, 0.6) * CF.deg(0, 8 * i, 0),
                     (150, 60, 60) if i % 2 else (60, 90, 150), "SmoothPlastic")
        else:
            part(fur, "SideTable", (1.8, 2.0, 1.8), f * CF(2.6, 1.0, 0.4), WOOD, "Wood")
            part(fur, "SideLamp", (0.9, 0.9, 0.9), f * CF(2.6, 2.5, 0.4), (255, 226, 160), "Neon", shape="Ball")
            part(fur, "Fireplace", (4.4, 7.0, 1.6), f * CF(-4.2, 3.5, 1.2), (150, 82, 62), "Brick")
            part(fur, "FireGlow", (3.0, 2.6, 0.4), f * CF(-4.2, 1.9, 0.35), (255, 140, 60), "Neon", collide=False)

    def nest_post(self, f: CF):
        """A nest of rocks and bones for the T-Rex."""
        fur = self.furniture
        rng = random.Random(4242)
        for i in range(8):
            angle = i * 45.0
            size = rng.uniform(2.2, 3.6)
            part(fur, "NestRock", (size, size, size),
                 f * CF(math.cos(math.radians(angle)) * 6.0, size * 0.38, math.sin(math.radians(angle)) * 6.0) * CF.deg(0, angle, 0),
                 ROCK_COLORS[i % len(ROCK_COLORS)], "Rock")
        part(fur, "NestFloor", (0.5, 8.6, 8.6), f * CF(0, 0.25, 0) * CF.deg(0, 0, 90), (122, 104, 78), "Fabric",
             shape="Cylinder", collide=False)
        for x, z, yaw in ((-3.0, 2.4, 20), (3.6, -1.8, -35)):
            bone = f * CF(x, 0.3, z) * CF.deg(0, yaw, 0)
            part(fur, "Bone", (3.4, 0.42, 0.42), bone, (236, 232, 216), "SmoothPlastic", collide=False)
            for sx in (-1.6, 1.6):
                for sz in (-0.22, 0.22):
                    part(fur, "BoneKnob", (0.6, 0.6, 0.6), bone * CF(sx, 0, sz), (236, 232, 216), shape="Ball",
                         collide=False)

    def charger_post(self, f: CF):
        """A charging pad for a security bot."""
        fur = self.furniture
        part(fur, "ChargePad", (3.8, 0.3, 3.8), f * CF(0, 0.15, 0), DARK, "Metal", collide=False)
        part(fur, "ChargeRing", (0.14, 3.3, 3.3), f * CF(0, 0.36, 0) * CF.deg(0, 0, 90), (90, 220, 255), "Neon",
             shape="Cylinder", collide=False, query=False)
        for sx in (-1, 1):
            part(fur, "ChargePylon", (0.5, 2.6, 0.5), f * CF(sx * 2.2, 1.3, 1.9), DARK, "Metal")
            part(fur, "ChargeTip", (0.42, 0.42, 0.42), f * CF(sx * 2.2, 2.8, 1.9), (90, 220, 255), "Neon",
                 shape="Ball", collide=False)
        return part(self.docks, "Dock", (2.8, 0.2, 2.8), f * CF(0, 0.36, 0), DARK, transparency=1, collide=False,
                    query=False, touch=False, shadow=False)

    def bay_post(self, f: CF):
        """A marked parking bay for a security car."""
        fur = self.furniture
        part(fur, "BayPad", (7.0, 0.24, 12.0), f * CF(0, 0.12, 0), (152, 152, 148), "Concrete")
        for sx in (-1, 1):
            part(fur, "BayLine", (0.44, 0.3, 11.6), f * CF(sx * 3.2, 0.15, 0), WHITE, "SmoothPlastic",
                 collide=False, query=False)
        post = f * CF(-4.2, 0, 5.2)
        part(fur, "BayPost", (0.5, 7.0, 0.5), post * CF(0, 3.5, 0), DARK, "Metal")
        board = part(fur, "BaySign", (4.8, 2.0, 0.24), post * CF(0, 7.6, 0), (244, 244, 240), "SmoothPlastic")
        surface_text(board, "Front", "SECURITY", color=(200, 40, 40), pixels_per_stud=56)
        surface_text(board, "Back", "SECURITY", color=(200, 40, 40), pixels_per_stud=56)
        return part(self.docks, "Dock", (5.6, 0.2, 5.6), f * CF(0, 0.26, 0), (152, 152, 148), transparency=1,
                    collide=False, query=False, touch=False, shadow=False)

    def guard_post(self, x, z, facing, guard, tier, color):
        """Where one defender waits. Returns the invisible Dock part the server uses as its home."""
        kind = guard["kind"]
        f = self.frame(x, z, facing)
        if kind == "Cat":
            return self.pet_bed(x, z, facing, "Cat", PET_BED_SIZES.get(guard["id"], PET_BEDS["Cat"]), color)
        if kind == "Dog":
            return self.pet_bed(x, z, facing, "Dog", PET_BED_SIZES.get(guard["id"], PET_BEDS[tier]), color)
        if kind in ("Human", "Wizard"):
            self.chair_post(f, kind == "Wizard")
        elif kind == "Beast":
            self.nest_post(f)
        elif kind == "Robot":
            return self.charger_post(f)
        elif kind == "Vehicle":
            return self.bay_post(f)
        return part(self.docks, "Dock", (2.8, 0.2, 2.8), f * CF(0, 0.3, -2.6), color, transparency=1,
                    collide=False, query=False, touch=False, shadow=False)

    def lamp(self, x, z, light_range=22, brightness=0.9):
        f = self.cf * CF(x, self.H - 0.45, z)
        shade = part(self.furniture, "CeilingLamp", (0.6, 2.0, 2.0), f * CF.deg(0, 0, 90), (255, 240, 205), "Neon",
                     shape="Cylinder", collide=False)
        point_light(shade, (255, 236, 205), brightness, light_range)

    # -- furniture (front of each piece = local -Z, placed with a facing) --------
    def counter(self, x, z, facing, length=8.0, depth=2.6, height=3.2, spots=2, body=WHITE, top=(70, 72, 78)):
        f = self.frame(x, z, facing)
        self.p("Counter", (length, height - 0.3, depth), (0, (height - 0.3) / 2, 0), body, "WoodPlanks", frame=f,
               parent=self.furniture)
        self.p("CounterTop", (length + 0.2, 0.3, depth + 0.2), (0, height - 0.15, 0), top, "Granite", frame=f,
               parent=self.furniture)
        doors = max(1, int(length // 2.6))
        for i in range(doors):
            cx = -length / 2 + length * (i + 0.5) / doors
            self.p("Handle", (0.8, 0.12, 0.12), (cx, height - 0.8, -depth / 2 - 0.05), (180, 180, 186), "Metal",
                   frame=f, parent=self.furniture, collide=False)
        for i in range(spots):
            self.spot(f * CF(-length / 2 + length * (i + 0.5) / spots, height, 0))

    def table(self, x, z, facing, width=4.4, depth=2.8, height=2.9, spots=1, color=WOOD, legs=True, chairs=False):
        f = self.frame(x, z, facing)
        self.p("TableTop", (width, 0.3, depth), (0, height - 0.15, 0), color, "Wood", frame=f, parent=self.furniture)
        if legs:
            for sx in (-1, 1):
                for sz in (-1, 1):
                    self.p("TableLeg", (0.3, height - 0.3, 0.3), (sx * (width / 2 - 0.35), (height - 0.3) / 2,
                                                                  sz * (depth / 2 - 0.35)), color, "Wood", frame=f,
                           parent=self.furniture)
        if chairs:
            for sx in (-1, 1):
                for sz in (-1, 1):
                    self.chair_at(f * CF(sx * width / 4, 0, sz * (depth / 2 + 1.0)) * CF.deg(0, 0 if sz > 0 else 180, 0))
        for i in range(spots):
            self.spot(f * CF(-width / 2 + width * (i + 0.5) / spots, height, 0))

    def chair_at(self, f: CF, color=WOOD_DARK):
        # Front of the chair faces local -Z (toward the table when placed behind it).
        self.p("ChairSeat", (1.8, 0.3, 1.8), (0, 1.8, 0), color, "Wood", frame=f, parent=self.furniture)
        self.p("ChairBack", (1.8, 2.2, 0.25), (0, 3.0, 0.8), color, "Wood", frame=f, parent=self.furniture)
        for sx in (-1, 1):
            for sz in (-1, 1):
                self.p("ChairLeg", (0.22, 1.65, 0.22), (sx * 0.7, 0.82, sz * 0.7), color, "Wood", frame=f,
                       parent=self.furniture)

    def sofa(self, x, z, facing, length=8.0, color=(70, 110, 170)):
        f = self.frame(x, z, facing)
        fur = self.furniture
        self.p("SofaSeat", (length, 1.3, 3.0), (0, 0.65, 0), color, "Fabric", frame=f, parent=fur)
        self.p("SofaBack", (length, 2.6, 0.8), (0, 1.3, 1.1), color, "Fabric", frame=f, parent=fur)
        for sx in (-1, 1):
            self.p("SofaArm", (0.8, 2.0, 3.0), (sx * (length / 2 - 0.4), 1.0, 0), color, "Fabric", frame=f, parent=fur)
        cushion = tuple(min(255, c + 30) for c in color)
        for i in range(2):
            self.p("Cushion", (length / 2 - 1.0, 0.4, 2.2), ((i - 0.5) * (length / 2 - 0.6), 1.5, -0.2), cushion,
                   "Fabric", frame=f, parent=fur)

    def bed(self, x, z, facing, color=(90, 140, 220), headboard_h=3.0):
        f = self.frame(x, z, facing)
        fur = self.furniture
        self.p("BedFrame", (6.0, 1.2, 8.6), (0, 0.6, 0), WOOD_DARK, "Wood", frame=f, parent=fur)
        self.p("Mattress", (5.6, 0.7, 8.2), (0, 1.55, 0), WHITE, "Fabric", frame=f, parent=fur)
        self.p("Blanket", (5.8, 0.25, 5.2), (0, 1.95, -1.5), color, "Fabric", frame=f, parent=fur)
        self.p("Pillow", (4.2, 0.6, 1.6), (0, 2.15, 3.0), WHITE, "Fabric", frame=f, parent=fur)
        self.p("Headboard", (6.0, headboard_h, 0.5), (0, headboard_h / 2, 4.55), WOOD_DARK, "Wood", frame=f,
               parent=fur)

    def nightstand(self, x, z, facing):
        f = self.frame(x, z, facing)
        self.p("Nightstand", (2.2, 2.4, 2.2), (0, 1.2, 0), WOOD, "Wood", frame=f, parent=self.furniture)
        self.p("Knob", (0.3, 0.3, 0.2), (0, 1.5, -1.15), GOLD, "Metal", frame=f, parent=self.furniture, collide=False)
        self.spot(f * CF(0, 2.4, 0))

    def dresser(self, x, z, facing, color=WOOD):
        f = self.frame(x, z, facing)
        self.p("Dresser", (5.0, 3.4, 2.2), (0, 1.7, 0), color, "Wood", frame=f, parent=self.furniture)
        for row in range(3):
            self.p("Drawer", (4.6, 0.9, 0.1), (0, 0.6 + row * 1.05, -1.12), WOOD_LIGHT, "Wood", frame=f,
                   parent=self.furniture, collide=False)
        self.spot(f * CF(0, 3.4, 0))

    def tv_stand(self, x, z, facing):
        f = self.frame(x, z, facing)
        self.p("TVStand", (6.0, 1.8, 2.0), (0, 0.9, 0), DARK, "Wood", frame=f, parent=self.furniture)
        self.spot(f * CF(0, 1.8, 0))

    def desk(self, x, z, facing):
        f = self.frame(x, z, facing)
        self.p("DeskTop", (5.4, 0.3, 2.6), (0, 2.8, 0), WOOD_LIGHT, "Wood", frame=f, parent=self.furniture)
        for sx in (-1, 1):
            self.p("DeskSide", (0.3, 2.65, 2.4), (sx * 2.5, 1.33, 0), WOOD_LIGHT, "Wood", frame=f,
                   parent=self.furniture)
        self.chair_at(f * CF(0, 0, -2.6) * CF.deg(0, 180, 0), DARK)
        self.spot(f * CF(0, 2.95, 0))

    def low_shelf(self, x, z, facing):
        f = self.frame(x, z, facing)
        self.p("Shelf", (5.0, 3.4, 1.8), (0, 1.7, 0), WOOD_DARK, "Wood", frame=f, parent=self.furniture)
        colors = [(180, 50, 50), (50, 90, 170), (60, 140, 70), (200, 160, 40), (120, 60, 140)]
        for row, y in enumerate((0.9, 2.4)):
            for i in range(6):
                self.p("Book", (0.55, 1.1, 0.2), (-1.9 + i * 0.75, y, -0.92), colors[(i + row * 2) % len(colors)],
                       "SmoothPlastic", frame=f, parent=self.furniture, collide=False)
        self.spot(f * CF(0, 3.4, 0))

    def tall_bookcase(self, x, z, facing, width=6.0):
        f = self.frame(x, z, facing)
        self.p("Bookcase", (width, 9.0, 1.6), (0, 4.5, 0), WOOD_DARK, "Wood", frame=f, parent=self.furniture)
        colors = [(170, 40, 40), (40, 80, 160), (50, 130, 60), (190, 150, 40), (110, 50, 130), (150, 90, 50)]
        for row in range(4):
            self.p("Books", (width - 0.6, 1.4, 0.15), (0, 1.2 + row * 2.1, -0.83), colors[row % len(colors)],
                   "SmoothPlastic", frame=f, parent=self.furniture, collide=False)

    def pedestal(self, x, z, facing, color=(236, 236, 240)):
        f = self.frame(x, z, facing)
        self.p("PedestalBase", (2.8, 0.4, 2.8), (0, 0.2, 0), color, "Marble", frame=f, parent=self.furniture)
        self.p("Pedestal", (2.0, 2.8, 2.0), (0, 1.8, 0), color, "Marble", frame=f, parent=self.furniture)
        self.p("PedestalTop", (2.6, 0.3, 2.6), (0, 3.35, 0), color, "Marble", frame=f, parent=self.furniture)
        self.p("PedestalGlow", (2.62, 0.08, 2.62), (0, 3.2, 0), GOLD, "Neon", frame=f, parent=self.furniture,
               collide=False)
        self.spot(f * CF(0, 3.5, 0))

    def coffee_table(self, x, z, facing):
        self.table(x, z, facing, width=4.4, depth=2.6, height=1.6, spots=1, color=WOOD_DARK)

    def fridge(self, x, z, facing):
        f = self.frame(x, z, facing)
        self.p("Fridge", (3.0, 6.6, 2.8), (0, 3.3, 0), (236, 238, 242), "Metal", frame=f, parent=self.furniture)
        self.p("FridgeHandle", (0.2, 2.0, 0.2), (1.1, 4.4, -1.5), (150, 150, 155), "Metal", frame=f,
               parent=self.furniture, collide=False)
        self.p("FridgeLine", (3.0, 0.08, 0.05), (0, 4.6, -1.42), (190, 190, 196), "Metal", frame=f,
               parent=self.furniture, collide=False)

    def plant(self, x, z):
        f = self.frame(x, z, "n")
        self.p("Pot", (1.6, 1.4, 1.6), (0, 0.7, 0), (170, 90, 60), "Concrete", frame=f, parent=self.furniture)
        self.p("Leaves", (2.6, 2.6, 2.6), (0, 2.5, 0), LEAF, "LeafyGrass", frame=f, parent=self.furniture,
               shape="Ball", collide=False)

    def rug(self, x, z, width, depth, color):
        self.p("Rug", (width, 0.05, depth), (x, self.FLOOR_Y + 0.03, z), color, "Fabric", parent=self.furniture,
               collide=False)

    def painting(self, axis, coord, at, y, facing_sign, colors):
        """A framed picture on a wall (decor)."""
        if axis == "x":
            self.p("PictureFrame", (4.2, 3.2, 0.2), (at, y, coord + facing_sign * 0.1), GOLD, "Metal",
                   parent=self.furniture, collide=False)
            self.p("Picture", (3.6, 2.6, 0.05), (at, y, coord + facing_sign * 0.22), colors[0], "SmoothPlastic",
                   parent=self.furniture, collide=False)
            self.p("PictureDetail", (1.6, 1.2, 0.05), (at + 0.6, y + 0.3, coord + facing_sign * 0.26), colors[1],
                   "SmoothPlastic", parent=self.furniture, collide=False)
        else:
            self.p("PictureFrame", (0.2, 3.2, 4.2), (coord + facing_sign * 0.1, y, at), GOLD, "Metal",
                   parent=self.furniture, collide=False)
            self.p("Picture", (0.05, 2.6, 3.6), (coord + facing_sign * 0.22, y, at), colors[0], "SmoothPlastic",
                   parent=self.furniture, collide=False)
            self.p("PictureDetail", (0.05, 1.2, 1.6), (coord + facing_sign * 0.26, y + 0.3, at + 0.6), colors[1],
                   "SmoothPlastic", parent=self.furniture, collide=False)

    # -- yard -----------------------------------------------------------------
    def fence(self, style, gaps, back_z=None):
        """Fence around the lot. gaps = list of (x_center, width) on the front edge (z = +lot_d/2).
        back_z: the side runs stop there (lot coordinates) and there's no back run, e.g. where a cliff takes over."""
        hw, hd = self.lot_w / 2 - 0.6, self.lot_d / 2 - 0.6
        back = -hd if back_z is None else back_z
        runs = [
            ((-hw, back), (-hw, hd), []),  # left
            ((hw, back), (hw, hd), []),  # right
            ((-hw, hd), (hw, hd), gaps),  # front
        ]
        if back_z is None:
            runs.insert(0, ((-hw, -hd), (hw, -hd), []))  # back
        for (x0, z0), (x1, z1), run_gaps in runs:
            along_x = abs(x1 - x0) > abs(z1 - z0)
            s0, s1 = (x0, x1) if along_x else (z0, z1)
            pieces = []
            cursor = s0
            for at, width in sorted(run_gaps):
                if at - width / 2 > cursor:
                    pieces.append((cursor, at - width / 2))
                cursor = at + width / 2
            if cursor < s1:
                pieces.append((cursor, s1))
            for a, b in pieces:
                self._fence_piece(style, along_x, a, b, z0 if along_x else x0)

    def _fence_piece(self, style, along_x, a, b, fixed):
        length = b - a
        mid = (a + b) / 2
        center = (mid, 0, fixed) if along_x else (fixed, 0, mid)

        def at(y):
            return (center[0], y, center[2])

        size = (lambda w, h, d: (w, h, d)) if along_x else (lambda w, h, d: (d, h, w))
        if style == "picket":
            self.y("Fence", size(length, 2.6, 0.25), at(1.5), WHITE, "WoodPlanks")
            self.y("FenceCap", size(length, 0.3, 0.45), at(2.95), WHITE, "WoodPlanks")
        elif style == "hedge":
            self.y("Hedge", size(length, 4.2, 2.4), at(2.1), LEAF_DARK, "LeafyGrass")
        elif style == "modern":
            self.y("Fence", size(length, 4.6, 0.4), at(2.3), (60, 62, 68), "WoodPlanks")
            self.y("FenceTrim", size(length, 0.3, 0.6), at(4.75), (40, 42, 46), "Metal")
        elif style == "estate":
            self.y("EstateWall", size(length, 8.0, 1.6), at(4.0), (214, 200, 170), "Limestone")
            self.y("EstateWallCap", size(length, 0.6, 2.2), at(8.3), (190, 176, 150), "Limestone")
        # posts at the ends
        for s in (a, b):
            post = (s, 0, fixed) if along_x else (fixed, 0, s)
            if style == "picket":
                self.y("FencePost", (0.5, 3.4, 0.5), (post[0], 1.7, post[2]), WHITE, "WoodPlanks")
            elif style == "estate":
                self.y("WallPillar", (3.0, 9.6, 3.0), (post[0], 4.8, post[2]), (190, 176, 150), "Limestone")
            elif style == "modern":
                self.y("FencePost", (0.6, 5.0, 0.6), (post[0], 2.5, post[2]), (40, 42, 46), "Metal")

    def path(self, x, z0, z1, width=4.0, color=(150, 150, 156), material="Slate"):
        self.y("Path", (width, 0.12, z1 - z0), (x, 0.06, (z0 + z1) / 2), color, material)

    def sign(self, x, z, display, tier_info, tier, guard, guard_count):
        """The yard sign: house name, difficulty stars and who's guarding it."""
        stars = "★" * tier_info["stars"] + "☆" * (4 - tier_info["stars"])
        board = self.y("HouseSign", (7.6, 3.8, 0.3), (x, 5.0, z), WHITE, "WoodPlanks")
        self.y("SignPost", (0.4, 3.4, 0.4), (x, 1.7, z + 0.2), WOOD_DARK, "Wood")
        who = guard["name"] if guard_count == 1 else f'{guard_count} {guard["name"]}s'
        text = (f'<font color="#{_hex(TIER_COLORS[tier])}">{display.upper()}</font>\n'
                f'<font color="#E8B000">{stars}</font>  {tier_info["name"]}\n'
                f'{guard["icon"]} {who} · speed {speed_text(guard["speed"])}')
        surface_text(board, "Back", text, color=(40, 40, 46), rich=True, stroke=None, pixels_per_stud=50)
        surface_text(board, "Front", text, color=(40, 40, 46), rich=True, stroke=None, pixels_per_stud=50)


TIER_COLORS = {1: (60, 170, 60), 2: (40, 120, 220), 3: (150, 70, 220), 4: (220, 150, 0)}


def _hex(rgb) -> str:
    return "".join(f"{c:02X}" for c in rgb)


# ---------------------------------------------------------------------------
# The house (house-local coordinates: centre = origin, front door side = +Z).
# Every house on the street uses this one design; only the paint changes.
# ---------------------------------------------------------------------------

HOUSE_W, HOUSE_D, HOUSE_H = 56.0, 42.0, 12.0
FRONT_YARD = 18.0
LOT_W, LOT_D = 72.0, HOUSE_D + FRONT_YARD
CLIFF_SETBACK = 3.0  # the cliff face sits this far behind the front of each house
SIDEWALK_EDGE = 24.0  # |z| where the pavement ends and the front yards begin
HOUSE_FRONT_Z = SIDEWALK_EDGE + FRONT_YARD
CLIFF_FACE_Z = HOUSE_FRONT_Z + CLIFF_SETBACK
FENCE_STYLES = {1: "picket", 2: "hedge", 3: "modern"}
PET_BEDS = {"Cat": 2.8, 1: 2.8, 2: 3.4, 3: 4.2}
# Beds sized to the animal that sleeps in them (guard id -> bed size).
PET_BED_SIZES = {"TuxedoCat": 2.8, "Puppy": 2.6, "Labrador": 3.6, "GuardDog": 4.2}
# Where each kind of defender waits, in house coordinates (x, z, facing). The first post is the
# one a house with a single defender uses; a car defender parks on the drive instead.
GUARD_POSTS = {
    "Cat": ((-8.4, 16.4, "e"), (-22.5, 16.5, "e"), (-7.5, 5.0, "e")),
    "Dog": ((-8.4, 16.4, "e"), (9.2, -5.4, "w"), (-22.5, 16.5, "e")),
    "Human": ((-8.4, 16.4, "e"), (-22.5, 16.5, "e"), (-7.5, 5.0, "e")),
    "Wizard": ((-8.4, 16.4, "e"),),
    "Beast": ((-15.0, 11.0, "e"),),
    "Robot": ((-7.5, 5.0, "e"), (-7.5, 15.5, "e"), (-22.5, 16.5, "e")),
    "Vehicle": ((12.0, 29.0, "s"),),
}


def guard_posts(guard, count, tier) -> list[tuple[float, float, str]]:
    posts = list(GUARD_POSTS.get(guard["kind"], GUARD_POSTS["Dog"]))
    while len(posts) < count:
        posts.append(posts[-1])
    return posts[:count]


def build_house(folder, info, tier_info, lot_cf, palette):
    tier, guard = info["tier"], info["guard"]
    W, D, H = HOUSE_W, HOUSE_D, HOUSE_H
    hb = HouseBuilder(folder, info["id"], info["display"], tier, lot_cf, LOT_W, LOT_D, W, D, H, FRONT_YARD)
    hb.model.attr(Guard=guard["id"])
    hb.wall_color, hb.wall_material = palette["wall"], "Plaster"
    hb.spot_budget = 6 if tier == 1 else 10  # same loot count per house as before the street was rebuilt
    t = 0.8
    xi, zi = W / 2 - t, D / 2 - t  # interior half extents
    # The cliff hugs the sides and the back, so windows only go in the front.
    hb.exterior(t, palette["wall"], "Plaster",
                front=[door_opening(0, 5, 9), window(-20, 5, 3.6, 8.4), window(-11, 5, 3.6, 8.4),
                       window(11, 5, 3.6, 8.4), window(20, 5, 3.6, 8.4)],
                back=[], left=[], right=[])
    hb.floor(WOOD_LIGHT)
    hb.room_floor(-xi, -4.25, -zi, -0.25, (226, 226, 222), "CeramicTiles")  # kitchen
    hb.room_floor(4.25, xi, -zi, 1.75, palette["carpet"], "Carpet")  # bedroom
    hb.room_floor(4.25, xi, 2.25, zi, WOOD, "WoodPlanks")  # study
    hb.wall_z(-4, -zi, zi, 0.5, H, [doorway(10, 5, 9), doorway(-10, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_z(4, -zi, zi, 0.5, H, [doorway(11, 5, 9), doorway(-9, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(0, -xi, -4.25, 0.5, H, [doorway(-16, 8, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(2, 4.25, xi, 0.5, H, [], OFFWHITE, "Plaster", "InteriorWall")
    hb.gable_roof(8, 1.4, palette["roof"])
    hb.p("Chimney", (3.0, 9, 3.0), (-17, H + 5.5, -8), (150, 82, 62), "Brick")
    hb.door("x", D / 2 - t / 2, 0, 5, 9, +1, palette["door"], step=False)
    # Porch
    hb.p("PorchFloor", (12, 0.35, 4.6), (0, 0.175, D / 2 + 2.3), (170, 150, 120), "WoodPlanks")
    for x in (-5.4, 5.4):
        hb.p("PorchColumn", (9.8, 0.9, 0.9), (x, 0.35 + 4.9, D / 2 + 4.1), WHITE, "SmoothPlastic", rot=(0, 0, 90),
             shape="Cylinder")
    hb.p("PorchRoof", (13.4, 0.6, 5.4), (0, 10.4, D / 2 + 2.5), palette["roof"], "RoofShingles")
    porch_light = hb.p("PorchLight", (0.6, 0.9, 0.4), (3.6, 7.6, D / 2 + 0.25), (255, 222, 160), "Neon",
                       parent=hb.furniture, collide=False)
    point_light(porch_light, (255, 214, 150), 1.2, 18)

    # Loot furniture, most important first: cottages (6 spots) stop after the pedestal.
    hb.tv_stand(-26.0, 10, "e")  # living room
    hb.counter(-15, -18.9, "s", length=12, spots=2)  # kitchen
    hb.nightstand(12.6, -19.0, "s")  # bedroom
    hb.desk(25.9, 11, "w")  # study
    hb.pedestal(0, -17.4, "s")  # the display at the end of the hall
    hb.coffee_table(-19.5, 10, "e")
    hb.table(-15, -8.5, "s", width=7, depth=4, height=2.9, spots=1, chairs=True)
    hb.dresser(25.9, -6, "w", color=palette["accent"])
    hb.low_shelf(15, 3.3, "s")

    # Living room
    hb.p("TV", (0.3, 3.4, 6.0), (-26.95, 5.4, 10), BLACK, parent=hb.furniture)
    hb.p("TVScreen", (0.05, 3.0, 5.6), (-26.78, 5.4, 10), (40, 110, 220), "Neon", parent=hb.furniture, collide=False)
    hb.sofa(-13, 10, "w", length=9, color=palette["sofa"])
    hb.rug(-19, 10, 10, 9, palette["rug"])
    hb.plant(-25.8, 18.6)
    hb.plant(-6.2, 2.0)
    # Kitchen
    hb.fridge(-25.6, -18.7, "s")
    hb.p("Stove", (3.2, 3.0, 2.6), (-7.0, 0.7 + 1.5, -18.9), (60, 62, 68), "Metal", parent=hb.furniture)
    for bx in (-7.8, -6.2):
        hb.p("Burner", (0.06, 1.0, 1.0), (bx, 0.7 + 3.03, -18.9), BLACK, rot=(0, 0, 90), parent=hb.furniture,
             shape="Cylinder", collide=False)
    # Hallway
    hb.rug(0, 6, 3.6, 26, palette["rug"])
    hb.painting("z", -3.75, 3, 7, +1, (palette["accent"], (240, 220, 120)))
    hb.painting("z", 3.75, -3, 7, -1, ((80, 140, 200), palette["accent"]))
    # Bedroom
    hb.bed(18, -14.9, "s", color=palette["bed"])
    hb.rug(18, -7.2, 7, 5, palette["rug"])
    hb.p("Wardrobe", (6, 8, 2.2), (9, 0.7 + 4, 0.6), palette["accent"], "Wood", parent=hb.furniture)
    for hx in (8.6, 9.4):
        hb.p("WardrobeHandle", (0.15, 1.2, 0.15), (hx, 0.7 + 4.2, -0.55), GOLD, "Metal", parent=hb.furniture,
             collide=False)
    # Study
    hb.tall_bookcase(8, 3.1, "s")
    hb.sofa(14, 17.6, "n", length=5, color=palette["sofa"])
    hb.plant(26, 18.8)
    for x, z in ((-16, 10), (-15, -9), (0, 14), (0, -6), (16, -9), (16, 11)):
        hb.lamp(x, z)

    # The defenders wait at their own posts (pet beds, chairs, a nest, charging pads, a parking bay).
    guard_count = info.get("count", 1)
    for post_x, post_z, post_facing in guard_posts(guard, guard_count, tier):
        hb.guard_post(post_x, post_z, post_facing, guard, tier, palette["pet"])
    if tier >= 3:
        hb.laser((-3.6, 2.4, 0), (3.6, 2.4, 0), 0.0)  # across the hallway
        hb.laser((4, 3.4, -11.3), (4, 3.4, -6.7), 1.8)  # across the bedroom door
    hb.siren((0, 11.4, D / 2 + 0.45))
    hb.siren((0, H - 0.5, 6))

    # Front yard (lot coordinates)
    front = LOT_D / 2 - FRONT_YARD  # lot z of the house's front wall
    hb.path(0, front + 4.6, LOT_D / 2 - 0.6, 4)
    fence_gaps = [(0, 6)]  # the garden gate
    if guard["kind"] == "Vehicle":
        fence_gaps.append((12, 13))  # the driveway the security car pulls out of
    hb.fence(FENCE_STYLES.get(tier, "picket"), fence_gaps, back_z=front - CLIFF_SETBACK)
    hb.sign(-8.5, LOT_D / 2 - 3.2, info["display"], tier_info, tier, guard, guard_count)
    for x in (-24, -16, 16, 24):
        bush(hb.yard, lot_cf * CF(x, 0, front + 1.6), 2.6, palette["bush"])
    for x in (-29.5, 29.5):
        tree(hb.yard, lot_cf * CF(x, 0, front + 10.5), 0.85, "pine" if (tier + int(x > 0)) % 2 else "round")
    for i, color in enumerate(((240, 80, 120), (255, 210, 60), (180, 110, 255), (255, 140, 60))):
        for sx in (-1, 1):
            hb.y("Flower", (0.9, 0.9, 0.9), (sx * 3.4, 0.55, front + 7 + i * 2.6), color, "SmoothPlastic",
                 shape="Ball", collide=False)
    hb.y("MailboxPost", (0.3, 3.0, 0.3), (5.2, 1.5, LOT_D / 2 - 1.4), WOOD_DARK, "Wood")
    hb.y("Mailbox", (1.0, 0.9, 1.6), (5.2, 3.4, LOT_D / 2 - 1.4), palette["door"], "Metal")
    return hb


# ---------------------------------------------------------------------------
# Cliffs: stacks of different-sized rock cubes behind and between the houses
# ---------------------------------------------------------------------------

ROCK_COLORS = [(122, 114, 104), (136, 128, 116), (108, 102, 96), (146, 138, 124), (128, 118, 106), (100, 96, 94),
               (114, 108, 98)]


class CliffBuilder:
    """Builds cliff boxes in a frame where the cliff face is at z = 0 facing +Z and the rock goes back toward -Z.

    Cubes are always perfect cubes; a big cube is simply sunk into the ground so its top lands at the height we
    want, which lets neighbouring cubes of very different sizes form a ragged, natural-looking wall."""

    def __init__(self, parent: Inst, seed: int):
        self.parent = parent
        self.rng = random.Random(seed)
        self.count = 0

    def cube(self, frame: CF, size: float, x: float, z: float, top: float, yaw: float = 0.0):
        rng = self.rng
        color = rng.choice(ROCK_COLORS)
        material = "Rock" if rng.random() < 0.8 else "Slate"
        cf = frame * CF(x, top - size / 2, z)
        if yaw:
            cf = cf * CF.deg(0, yaw, 0)
        part(self.parent, "Rock", (size, size, size), cf, color, material)
        self.count += 1

    def split(self, length: float, lo: float, hi: float) -> list[float]:
        """Splits a length into random pieces of roughly lo..hi studs that add up exactly."""
        if length <= hi:
            return [length]
        n = max(1, round(length / ((lo + hi) / 2)))
        weights = [self.rng.uniform(0.7, 1.3) for _ in range(n)]
        total = sum(weights)
        return [length * w / total for w in weights]

    def stack(self, frame: CF, width: float, cx: float, z_front: float, target: float, shrink=(0.7, 1.0),
              step_back=(0.4, 2.2), trees: Inst | None = None, max_cubes: int = 6):
        """One column of cubes built up from the ground (every cube rests on the one below it) until it reaches
        `target`. Each cube is a bit smaller than the column and set back a little, so the column climbs in steps."""
        rng = self.rng
        # The bottom cube fills the column and is sunk into the ground if it would poke above the target.
        top = min(target, width * rng.uniform(0.8, 1.0))
        back = rng.uniform(0, 1.2)
        self.cube(frame, width, cx, z_front - back - width / 2, top)
        size, offset, count = width, 0.0, 1
        while top < target - 1.0 and count < max_cubes:
            size = max(3.0, width * rng.uniform(*shrink))
            back += rng.uniform(*step_back)
            offset = rng.uniform(-(width - size) / 2, (width - size) / 2)
            top = min(target, top + size * rng.uniform(0.7, 1.0))  # never leaves a gap under the cube
            self.cube(frame, size, cx + offset, z_front - back - size / 2, top)
            count += 1
        if trees is not None and rng.random() < 0.18:
            tree(trees, frame * CF(cx + offset, top, z_front - back - size / 2), rng.uniform(0.9, 1.3),
                 "pine" if rng.random() < 0.6 else "round")

    def face(self, frame: CF, x0: float, x1: float, heights, taper=None, z_face: float = 0.0):
        """The visible wall: columns of stacked cubes that step back as they climb."""
        cursor = x0
        for w in self.split(x1 - x0, 7, 14):
            cx = cursor + w / 2
            cursor += w
            target = self.rng.uniform(*heights) * (taper(cx) if taper else 1.0)
            self.stack(frame, w, cx, z_face, target)

    def fill(self, frame: CF, x0: float, x1: float, z0: float, z1: float, heights, taper=None, trees: Inst | None = None):
        """Big cube columns covering x0..x1 from z0 back to z1 (z1 < z0); only the far back edge may overhang."""
        rng = self.rng
        cursor = x0
        for w in self.split(x1 - x0, 18, 30):
            cx = cursor + w / 2
            cursor += w
            z = z0
            while z > z1 + 0.5:
                target = rng.uniform(*heights) * (taper(cx) if taper else 1.0)
                self.stack(frame, w, cx, z, target, shrink=(0.55, 0.9), step_back=(0.0, 1.5), trees=trees,
                           max_cubes=4)
                z -= w

    def rubble(self, frame: CF, x0: float, x1: float, per_stud: float = 0.22):
        """Small loose cubes along the foot of the wall (never further out than the house fronts)."""
        rng = self.rng
        for _ in range(int((x1 - x0) * per_stud)):
            size = rng.uniform(1.0, 2.3)
            if x1 - x0 < size + 2:
                return
            x = rng.uniform(x0 + size / 2 + 0.8, x1 - size / 2 - 0.8)
            front = rng.uniform(0.3, CLIFF_SETBACK - 0.4)
            self.cube(frame, size, x, front - size / 2, size * rng.uniform(0.6, 1.0), rng.uniform(-30, 30))


def build_street_cliffs(parent: Inst, decor: Inst, sides: dict[int, list[float]], x_start: dict[int, float],
                        x_end: float):
    """One continuous cliff per side of the street. `sides` maps side (-1 north, +1 south) to its house centre X."""
    folder = Inst("Folder", "Street", parent)
    depth = 76.0
    behind = HOUSE_D - CLIFF_SETBACK  # distance from the cliff face to the back of a house
    for side, xs in sides.items():
        cliff = CliffBuilder(folder, 1000 + side)
        # Local frame: face at z = 0 looking at the street. South side is turned around, so local x = -world x.
        frame = CF(0, 0, side * CLIFF_FACE_Z) * CF.deg(0, 0 if side < 0 else 180, 0)
        flip = -1 if side > 0 else 1
        west = x_start[side]

        def taper(local_x, west=west, flip=flip):
            world_x = local_x * flip
            return min(1.0, max(0.35, (world_x - west) / 26.0))

        def local(a, b, flip=flip):
            return (min(a * flip, b * flip), max(a * flip, b * flip))

        cursor = west
        gaps = []
        for hx in sorted(xs):
            gaps.append((cursor, hx - HOUSE_W / 2))
            cliff.fill(frame, *local(hx - HOUSE_W / 2, hx + HOUSE_W / 2), -behind, -depth, (25, 40), taper, decor)
            cursor = hx + HOUSE_W / 2
        gaps.append((cursor, x_end))
        for a, b in gaps:
            if b - a < 1:
                continue
            la, lb = local(a, b)
            cliff.face(frame, la, lb, (22, 34), taper)
            cliff.fill(frame, la, lb, -6, -depth, (26, 40), taper, decor)
            cliff.rubble(frame, la, lb)
    return folder


def build_mansion_cliff(parent: Inst, decor: Inst, lot_cf: CF):
    """The Grand Mansion backs onto the tallest cliff, which also closes off the end of the street."""
    folder = Inst("Folder", "Mansion", parent)
    cliff = CliffBuilder(folder, 4242)
    house_front, house_back, half_w = 25.0, -27.0, 42.0  # mansion lot coordinates (see build_mansion)
    face_z = house_front - CLIFF_SETBACK
    frame = lot_cf * CF(0, 0, face_z)
    back = -95.0 - face_z  # the east edge of the map
    for a, b in ((-130.0, -half_w), (half_w, 130.0)):
        cliff.face(frame, a, b, (30, 44))
        cliff.fill(frame, a, b, -6, back, (34, 50), None, decor)
        cliff.rubble(frame, a, b, 0.12)
    cliff.fill(frame, -half_w, half_w, house_back - face_z, back, (36, 52), None, decor)
    # Beyond the estate walls the cliff comes forward to meet the end of the street.
    lot_front = 75.0 - face_z
    for a, b in ((-130.0, -100.0), (100.0, 130.0)):
        cliff.face(frame, a, b, (28, 40), None, z_face=lot_front)
        cliff.fill(frame, a, b, lot_front - 6, 0, (30, 44))
    return folder


def cliff_wall(cliff: CliffBuilder, decor: Inst, centre: tuple[float, float], normal: tuple[float, float],
               length: float, heights, *, fill_heights=None, depth: float = 45.0, rubble: float = 0.0,
               taper=None, trees: Inst | None = None, z_face: float = 0.0):
    """One straight cliff: a face through `centre` perpendicular to `normal`, with cube rock behind it.

    `normal` points away from the rock, towards the open ground, so (0, 1) is a face looking south and
    (1, 0) one looking east. `taper`, if given, receives a world X and scales the column heights.
    """
    yaw = math.degrees(math.atan2(normal[0], normal[1]))
    frame = CF(centre[0], 0, centre[1]) * CF.deg(0, yaw, 0)
    if taper is not None:
        world_taper = taper
        cos_yaw = math.cos(math.radians(yaw))
        taper = lambda lx: world_taper(centre[0] + lx * cos_yaw)  # noqa: E731
    half = length / 2.0
    cliff.face(frame, -half, half, heights, taper, z_face)
    if depth > 0:
        cliff.fill(frame, -half, half, z_face - 6.0, z_face - 6.0 - depth, fill_heights or heights, taper, trees)
    if rubble:
        cliff.rubble(frame, -half, half, rubble)


def build_yard_cliffs(parent: Inst, decor: Inst):
    """Cube cliffs wrap the three closed sides of the yard, hugging the back of the garages."""
    folder = Inst("Folder", "Yard", parent)
    cliff = CliffBuilder(folder, 9100)
    mid_x = (YARD_FACE_X + YARD_MOUTH_X) / 2
    span = (YARD_MOUTH_X - YARD_FACE_X) + 60.0
    for z, normal in ((-YARD_FACE_Z, (0, 1)), (YARD_FACE_Z, (0, -1))):
        cliff_wall(cliff, decor, (mid_x, z), normal, span, YARD_CLIFF_H, fill_heights=(34, 52), depth=44,
                   trees=decor)
    cliff_wall(cliff, decor, (YARD_FACE_X, 0), (1, 0), YARD_FACE_Z * 2 + 60.0, YARD_CLIFF_H,
               fill_heights=(34, 52), depth=44, trees=decor)
    return folder


CORRIDOR_STEPS = 12
CORRIDOR_START_X = -180.0         # where the yard's own cliffs end, at |z| = YARD_FACE_Z
CORRIDOR_END_H = (9.0, 13.0)      # the street's cliffs are about this tall where the corridor meets them


def build_corridor_cliffs(parent: Inst, decor: Inst):
    """The cliffs that join the yard to the houses: a canyon that curves in from the yard's mouth until it is
    as tight as the street it runs into."""
    folder = Inst("Folder", "Corridor", parent)
    cliff = CliffBuilder(folder, 9200)
    end_x = {-1: -16.0, 1: 36.0}  # the street cliffs start at x = -20 on the north side and x = 30 on the south
    for side, x_end in end_x.items():
        for i in range(CORRIDOR_STEPS):
            t0, t1 = i / CORRIDOR_STEPS, (i + 1) / CORRIDOR_STEPS

            # The face swings in from |z| = YARD_FACE_Z to the street's CLIFF_FACE_Z, quickly at first.
            def z_at(t):
                return CLIFF_FACE_Z + (YARD_FACE_Z - CLIFF_FACE_Z) * (1 - t) ** 1.6

            def x_at(t):
                return CORRIDOR_START_X + (x_end - CORRIDOR_START_X) * t

            def heights_at(t):
                ease = (1 - t) ** 1.6
                return (CORRIDOR_END_H[0] + (YARD_CLIFF_H[0] - CORRIDOR_END_H[0]) * ease,
                        CORRIDOR_END_H[1] + (YARD_CLIFF_H[1] - CORRIDOR_END_H[1]) * ease)

            x0, x1 = x_at(t0), x_at(t1)
            p0, p1 = (x0, side * z_at(t0)), (x1, side * z_at(t1))
            dx, dz = p1[0] - p0[0], p1[1] - p0[1]
            # Outward is the perpendicular that points at the road (and back towards the yard).
            normal = (dz * side, -dx * side)
            length = math.hypot(dx, dz) * 1.25  # segments overlap, so the curve has no seams
            heights = heights_at((t0 + t1) / 2)
            cliff_wall(cliff, decor, ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2), normal, length, heights,
                       fill_heights=(heights[0] + 4, heights[1] + 6), depth=48.0, rubble=0.18, trees=decor)
            # A treeline along the foot of the wall, like the one in front of the street's cliffs.
            tree(decor, CF(x0 + dx * 0.35, 0, side * (z_at(t0) - 7.0)), 1.05 + 0.05 * i, "pine" if i % 2 else "round")
    return folder


def build_mansion(folder, info, tier_info, lot_cf):
    hb = HouseBuilder(folder, info["id"], info["display"], 4, lot_cf, 200, 150, 84, 52, 14, 50)
    hb.model.attr(Guard=info["guard"]["id"])
    wall = (232, 218, 186)
    hb.wall_color, hb.wall_material = wall, "Limestone"
    H = 14
    windows_front = [window(x, 6 if abs(x) < 30 else 5, 3.6, 10.4) for x in (-37, -27, -14, 14, 27, 37)]
    # The cliff wraps the sides and the back, so only the front has openings.
    hb.exterior(1.2, wall, "Limestone", front=[door_opening(0, 8, 11.5)] + windows_front, back=[], left=[], right=[])
    hb.floor((240, 236, 228), "Marble")
    hb.room_floor(-40.8, -14.4, 0.4, 24.8, (120, 40, 40), "Carpet")
    hb.room_floor(-40.8, -14.4, -24.8, -0.4, (70, 90, 150), "Carpet")
    hb.room_floor(14.4, 40.8, 0.4, 24.8, (150, 105, 66), "WoodPlanks")
    hb.room_floor(-13.6, 13.6, -24.8, -6.4, (120, 122, 128), "DiamondPlate")
    inner = (236, 228, 210)
    for x in (-14, 14):
        hb.wall_z(x, -24.8, 24.8, 0.8, H, [doorway(13, 5, 10.5), doorway(-13, 5, 10.5)], inner, "Plaster",
                  "InteriorWall")
    hb.wall_x(0, -40.8, -14.4, 0.8, H, [doorway(-28, 5, 10.5)], inner, "Plaster", "InteriorWall")
    hb.wall_x(0, 14.4, 40.8, 0.8, H, [doorway(28, 5, 10.5)], inner, "Plaster", "InteriorWall")
    hb.wall_x(-6, -13.6, 13.6, 1.2, H, [doorway(0, 6, 10)], (110, 112, 120), "DiamondPlate", "VaultWall")
    hb.gable_roof(12, 1.6, (150, 56, 44), "ClayRoofTiles")
    door_color = (90, 50, 30)
    hb.door("x", 25.4, -2, 4, 11.5, +1, door_color, hinge="low", name="FrontDoorLeft", step=False)
    hb.door("x", 25.4, 2, 4, 11.5, +1, door_color, hinge="high", name="FrontDoorRight", step=False)
    # Portico
    hb.p("Portico", (26, 0.4, 8.5), (0, 0.2, 30.3), (220, 210, 190), "Marble")
    for x in (-11, -4.5, 4.5, 11):
        hb.p("Column", (12.6, 1.7, 1.7), (x, 0.4 + 6.3, 33.4), WHITE, "Marble", rot=(0, 0, 90), shape="Cylinder")
    hb.p("PorticoRoof", (27, 1.0, 9.4), (0, 13.5, 30.4), WHITE, "Marble")
    hb.p("Pediment", (1.0, 5, 13.5), (-6.75, 16.5, 34.4), WHITE, "Marble", rot=(0, 90, 0), cls="WedgePart")
    hb.p("Pediment", (1.0, 5, 13.5), (6.75, 16.5, 34.4), WHITE, "Marble", rot=(0, -90, 0), cls="WedgePart")
    # Grand hall
    hb.rug(0, 9.6, 5, 29, (170, 20, 30))
    for x in (-8, 8):
        hb.pedestal(x, 14, "s")
    for x in (-11.4, 11.4):
        hb.table(x, 3, "s", width=2.6, depth=2.6, height=3.0, spots=1, color=WOOD_DARK)
        hb.plant(x, 22.6)
    chandelier = part(hb.furniture, "Chandelier", (0.5, 6, 6), hb.cf * CF(0, H - 2.4, 10) * CF.deg(0, 0, 90), GOLD,
                      "Metal", shape="Cylinder", collide=False)
    point_light(chandelier, (255, 230, 190), 1.2, 34)
    for angle in range(0, 360, 45):
        rad = math.radians(angle)
        part(hb.furniture, "Crystal", (0.7, 0.7, 0.7), hb.cf * CF(math.cos(rad) * 2.6, H - 3.2, 10 + math.sin(rad) * 2.6),
             (255, 250, 230), "Neon", shape="Ball", collide=False)
    # Library
    hb.tall_bookcase(-40.0, 5, "e", width=7)
    hb.tall_bookcase(-40.0, 20.5, "e", width=7)
    hb.desk(-27, 12, "s")
    hb.low_shelf(-27, 23.9, "n")
    hb.sofa(-20, 6, "w", length=4, color=(120, 40, 40))
    # Master bedroom
    hb.bed(-36.0, -12.5, "e", color=(200, 170, 60), headboard_h=4)
    hb.nightstand(-39.6, -17.0, "e")
    hb.nightstand(-39.6, -8.0, "e")
    hb.dresser(-24, -23.7, "s", color=WOOD_DARK)
    # Dining room
    hb.table(28, 12.5, "s", width=12, depth=4.5, height=3.0, spots=2, color=WOOD_DARK, chairs=True)
    hb.counter(39.5, 12.5, "w", length=6, depth=2.4, spots=1, body=WOOD_DARK, top=(240, 240, 240))
    # Gallery
    for x, z in ((21, -12), (28, -18.5), (35, -12)):
        hb.pedestal(x, z, "s")
    for i, x in enumerate((20, 28, 36)):
        hb.painting("x", -24.8, x, 7.5, +1, [((90, 112, 74), (232, 196, 156)), ((30, 50, 120), (240, 210, 60)),
                                             ((160, 40, 40), (40, 40, 40))][i])
    hb.laser((25.5, 2.4, 0), (30.5, 2.4, 0), 0.9)
    # The vault
    for x, z in ((-7, -12), (7, -12), (-7, -20.5), (7, -20.5)):
        hb.pedestal(x, z, "s", color=(60, 62, 70))
    for sx in (-1, 1):
        hb.p("VaultFrame", (1.4, 10.6, 2.0), (sx * 3.7, 0.7 + 5.3, -6), (80, 82, 90), "DiamondPlate")
        for i in range(3):
            hb.p("GoldPile", (1.6, 0.8, 3.2), (sx * 11.4, 0.7 + 0.4 + i * 0.8, -22 + (i % 2) * 0.4), GOLD, "Metal",
                 parent=hb.furniture, reflectance=0.3)
    hb.p("VaultFrame", (8.8, 1.4, 2.0), (0, 10.7, -6), (80, 82, 90), "DiamondPlate")
    hb.laser((-3, 1.6, -6), (3, 1.6, -6), 0.0)
    hb.laser((-3, 4.8, -6), (3, 4.8, -6), 1.8)
    hb.laser((-13, 1.4, -9.5), (13, 1.4, -9.5), 0.6)
    hb.laser((-13, 3.4, -16.2), (13, 3.4, -16.2), 2.4)
    for x, z in ((-27, 12), (-27, -12), (28, 12), (28, -12), (0, -15)):
        hb.lamp(x, z, 26, 1.0)
    # The museum's fleet of security cars, parked on the drive (see Config.Houses: GuardCount).
    for fleet_x in (-3.6, 3.6):
        for fleet_z in (42.0, 54.0):
            hb.guard_post(fleet_x, fleet_z, "s", info["guard"], 4, (30, 34, 46))
    hb.siren((0, 12.4, 26.6))
    hb.siren((0, H - 0.6, 18))
    hb.siren((0, H - 0.6, -12))
    # Grounds (house front wall at lot z = 25)
    hb.y("Driveway", (14, 0.14, 40.6), (0, 0.07, 54.7), (160, 150, 140), "Cobblestone")
    hb.fence("estate", [(0, 16)], back_z=25 - CLIFF_SETBACK)
    hb.sign(-15, 71, info["display"], tier_info, 4, info["guard"], info.get("count", 1))
    for sx in (-1, 1):
        hb.y("GatePillar", (3.6, 12, 3.6), (sx * 9.6, 6, 74.4), (190, 176, 150), "Limestone")
        lamp_part = hb.y("GateLamp", (1.6, 1.6, 1.6), (sx * 9.6, 12.8, 74.4), (255, 230, 170), "Neon", shape="Ball")
        point_light(lamp_part, (255, 220, 160), 1, 24)
        # Fountains on both sides of the driveway
        fx = sx * 45
        hb.y("FountainBasin", (1.6, 18, 18), (fx, 0.8, 52), (200, 196, 186), "Marble", rot=(0, 0, 90), shape="Cylinder")
        hb.y("FountainWater", (0.3, 16, 16), (fx, 1.5, 52), (70, 170, 235), "Glass", rot=(0, 0, 90), shape="Cylinder",
             transparency=0.25, collide=False, reflectance=0.2)
        hb.y("FountainColumn", (6, 1.6, 1.6), (fx, 3.6, 52), (220, 216, 206), "Marble", rot=(0, 0, 90), shape="Cylinder")
        hb.y("FountainBowl", (1.0, 6, 6), (fx, 6.8, 52), (220, 216, 206), "Marble", rot=(0, 0, 90), shape="Cylinder")
        hb.y("FountainSpray", (2.4, 2.4, 2.4), (fx, 8.0, 52), (150, 210, 255), "Glass", shape="Ball", transparency=0.4,
             collide=False)
        for z in (40, 50, 60, 70):
            hb.y("Hedge", (2.4, 3.2, 7), (sx * 10.5, 1.6, z), LEAF_DARK, "LeafyGrass")
        for z in (38, 58):
            street_lamp(hb.yard, lot_cf * CF(sx * 13, 0, z) * CF.deg(0, -90 * sx, 0))
        for x, z in ((80, 60), (55, 30), (88, 34)):
            tree(hb.yard, lot_cf * CF(sx * x, 0, z), 1.3, "pine" if (x + z) % 2 else "round")
    return hb


# ---------------------------------------------------------------------------
# Warehouses (plot-local coordinates: building centre = origin, door side = +Z)
# ---------------------------------------------------------------------------

PLOT_ACCENTS = [(230, 70, 60), (60, 140, 230), (70, 190, 90), (240, 170, 30), (170, 90, 220), (40, 190, 190)]
RACK_XS = (0, -12, 12, -24, 24)  # fill order: centre rack first so new players see their loot right away
SLOT_ZS = (0.4, -4.2, -8.8, -13.4, -18.0)


def build_warehouse(folder: Inst, ground: Inst, index: int, cf: CF) -> Inst:
    accent = PLOT_ACCENTS[(index - 1) % len(PLOT_ACCENTS)]
    plot = model(folder, f"Plot{index}", cf)
    plot.attr(PlotIndex=index)
    shell = model(plot, "Building", cf)

    def p(name, size, pos, color, material="SmoothPlastic", rot=None, parent=None, **kw):
        c = cf * CF(*pos)
        if rot:
            c = c * CF.deg(*rot)
        return part(parent if parent is not None else shell, name, size, c, color, material, **kw)

    W, D, H, t = 64, 48, 22, 1.0
    wall = (150, 154, 160)
    # Floor & walls
    p("Floor", (W, 0.4, D), (0, 0.2, 0), (128, 128, 126), "Concrete")
    for a, b in ((-W / 2, -13), (13, W / 2)):
        p("FrontWall", (b - a, H, t), ((a + b) / 2, H / 2, D / 2 - t / 2), wall, "CorrodedMetal")
    p("FrontWall", (26, H - 16, t), (0, 16 + (H - 16) / 2, D / 2 - t / 2), wall, "CorrodedMetal")
    p("DoorFrame", (27.2, 1.2, t + 0.4), (0, 16.6, D / 2 - t / 2), accent, "Metal")
    for x in (-13.6, 13.6):
        p("DoorFrame", (1.2, 16, t + 0.4), (x, 8, D / 2 - t / 2), accent, "Metal")
    p("RollerDoor", (26, 2.4, 1.4), (0, 15.2, D / 2 - 0.2), (90, 94, 100), "DiamondPlate")
    p("BackWall", (W, H, t), (0, H / 2, -D / 2 + t / 2), wall, "CorrodedMetal")
    for sx in (-1, 1):
        x = sx * (W / 2 - t / 2)
        p("SideWall", (t, 14, D - 2 * t), (x, 7, 0), wall, "CorrodedMetal")
        p("SideWall", (t, 3, D - 2 * t), (x, 20.5, 0), wall, "CorrodedMetal")
        p("Window", (0.3, 5, D - 2 * t), (x, 16.5, 0), GLASS, "Glass", transparency=0.5)
    p("Roof", (W + 2, 1.2, D + 2), (0, H + 0.6, 0), (110, 112, 118), "Metal")
    p("AccentStripe", (W + 0.4, 1.4, D + 0.4), (0, H - 0.7, 0), accent, "Metal")
    for x in (-18, 0, 18):
        lamp = p("CeilingLight", (8, 0.4, 2), (x, H - 0.4, -4), (255, 248, 230), "Neon", collide=False)
        point_light(lamp, (255, 244, 225), 1.1, 42)

    # Sign above the door (the server writes the owner's name on it)
    sign = p("OwnerSign", (34, 5, 0.6), (0, 19.2, D / 2 + 0.35), (30, 32, 40), "SmoothPlastic", parent=plot)
    surface_text(sign, "Back", "EMPTY WAREHOUSE", color=(255, 255, 255), label_name="OwnerText", stroke=0.4,
                 pixels_per_stud=30)
    number = p("PlotNumber", (6, 6, 0.6), (-24, 19.2, D / 2 + 0.35), accent, "SmoothPlastic", parent=plot)
    surface_text(number, "Back", str(index), color=(255, 255, 255), stroke=0.3, pixels_per_stud=30)

    # Stats board on the back wall
    board = p("StatsBoard", (18, 7, 0.4), (0, 15.5, -D / 2 + t + 0.2), (24, 26, 34), "SmoothPlastic", parent=plot)
    surface_text(board, "Back", "Waiting for a new owner...", color=(200, 255, 210), label_name="StatsText",
                 font="Builder", weight=700, stroke=None, pixels_per_stud=30)

    # Racks and slots
    slots = Inst("Folder", "Slots", plot)
    racks = model(plot, "Racks", cf)
    slot_index = 0
    for rx in RACK_XS:
        for sx in (-1, 1):
            for z in (2.7, -8.8, -20.3):
                p("RackPost", (0.4, 11.2, 0.4), (rx + sx * 1.9, 5.6 + 0.4, z), accent, "Metal", parent=racks)
        p("RackBeam", (0.3, 0.4, 23.4), (rx - 1.9, 11.4, -8.8), accent, "Metal", parent=racks)
        p("RackBeam", (0.3, 0.4, 23.4), (rx + 1.9, 11.4, -8.8), accent, "Metal", parent=racks)
        p("ShelfFrame", (4.2, 0.3, 23.4), (rx, 6.0, -8.8), (70, 74, 80), "Metal", parent=racks)
        for level, y in ((0, 0.7), (1, 6.3)):
            for z in SLOT_ZS:
                slot_index += 1
                size = (3.6, 0.6, 4.0) if level == 0 else (3.6, 0.2, 4.2)
                slot = part(slots, f"Slot{slot_index}", size, cf * CF(rx, y, z) * CF.deg(0, 180, 0),
                            WOOD_LIGHT if level == 0 else (190, 170, 130), "WoodPlanks")
                slot.attr(Index=slot_index)

    # Deposit pad (touch it while carrying loot)
    pad = p("DepositPad", (12, 0.25, 8), (0, 0.525, 13), (40, 230, 110), "Neon", parent=plot, collide=False,
            transparency=0.3)
    surface_text(pad, "Top", "⬇ DEPOSIT LOOT ⬇", color=(255, 255, 255), stroke=0.2, pixels_per_stud=20)
    for x, z, w, d in ((0, 17.4, 13.6, 0.8), (0, 8.6, 13.6, 0.8), (6.4, 13, 0.8, 8), (-6.4, 13, 0.8, 8)):
        p("PadBorder", (w, 0.3, d), (x, 0.55, z), YELLOW, "SmoothPlastic", parent=shell, collide=False)

    # Spawn point
    spawn = Inst("SpawnLocation", "Spawn", plot)
    spawn.set(**{
        "size": _v3((6, 0.4, 6)), "CFrame": cf * CF(-22, 0.6, 15) * CF.deg(0, 180, 0), "Color3uint8": C3u8(*accent),
        "Material": Token(MATERIALS["SmoothPlastic"]), "Anchored": True, "TopSurface": Token(0),
        "BottomSurface": Token(0), "Neutral": True, "Duration": Int(0), "AllowTeamChangeOnTouch": False,
    })

    # Crates (decor)
    for i, (x, z) in enumerate(((-28, 20), (-28, 16.5), (28, 20), (28, 16.4), (27.8, 12.8))):
        p("Crate", (3.2, 3.2, 3.2), (x, 2.0, z), (170, 130, 80), "WoodPlanks", rot=(0, (i * 17) % 30, 0))

    # Outside: apron and loading dock
    part(ground, "Apron", (80, 0.2, 40), cf * CF(0, 0.1, 44), (150, 150, 148), "Concrete")
    dock = p("Dock", (22, 2, 18), (0, 1, 35), (255, 220, 0), parent=plot, transparency=1, collide=False, query=False,
             touch=False, shadow=False)
    dock.attr(Purpose="Loading bay")
    for x, z, w, d in ((0, 26.4, 22.8, 0.8), (0, 43.6, 22.8, 0.8), (11, 35, 0.8, 18), (-11, 35, 0.8, 18)):
        p("DockStripe", (w, 0.06, d), (x, 0.23, z), YELLOW, "SmoothPlastic", parent=shell, collide=False, query=False)
    dock_label = p("DockLabel", (16, 0.05, 5), (0, 0.23, 35), (40, 40, 40), "SmoothPlastic", parent=shell,
                   collide=False, query=False, transparency=1)
    surface_text(dock_label, "Top", "LOADING BAY", color=YELLOW, stroke=0.3, pixels_per_stud=18)
    marker(plot, "Marker", cf * CF(0, 28, 0), (1, 1, 1))

    # The owner's personal treadmill, out front on the left. The runner faces the street.
    build_treadmill(plot, cf * CF(TREADMILL_X, 0.2, TREADMILL_Z) * CF.deg(0, 180, 0))
    return plot


# ---------------------------------------------------------------------------
# Personal treadmill (one per warehouse)
# ---------------------------------------------------------------------------

# Where the treadmill sits in warehouse-local coordinates (+Z points at the street).
TREADMILL_X, TREADMILL_Z = -27.0, 38.0
TREADMILL_TRIM = (200, 205, 215)  # level 1 colour; the server recolours Accent* parts per level


def build_treadmill(plot: Inst, tcf: CF) -> Inst:
    """A treadmill whose runner faces local -Z (towards the console), like a part's LookVector.

    The game scripts use: Belt (walk onto it to start running), RunPoint (where the runner is held),
    ExitPoint (where ESCAPE puts you), Console (upgrade prompt), the TreadmillText/TreadmillOwnerText
    labels and every part whose name starts with "Accent" (trim coloured by the treadmill's level).
    """
    m = model(plot, "Treadmill", tcf)

    def p(n, size, pos, col, mat="SmoothPlastic", **kw):
        return part(m, n, size, tcf * CF(*pos), col, mat, **kw)

    p("Mat", (8, 0.06, 17), (0, 0.03, 0.4), (44, 46, 52), "Rubber", collide=False, query=False)
    p("Deck", (5.4, 0.35, 12), (0, 0.175, 0), DARK, "Metal")
    p("Belt", (4.3, 0.12, 10.8), (0, 0.41, 0.1), (34, 34, 38), "Rubber")
    p("MotorHood", (5.4, 0.7, 1.2), (0, 0.35, -6.6), (40, 42, 50), "Metal")
    p("RearStep", (5.4, 0.25, 1.2), (0, 0.125, 6.6), (60, 62, 68), "DiamondPlate")
    for sx in (-1, 1):
        p("AccentRail", (0.55, 0.45, 12), (sx * 2.45, 0.575, 0), TREADMILL_TRIM, "Metal")
        p("Upright", (0.35, 4.6, 0.35), (sx * 2.3, 2.65, -5.5), (200, 200, 205), "Metal")
        p("Handrail", (0.25, 0.25, 4.4), (sx * 2.3, 4.0, -3.4), (200, 200, 205), "Metal")
    console = p("Console", (5.4, 1.8, 1.0), (0, 5.4, -5.7), (40, 42, 50), "Metal")
    surface_text(console, "Back", "WALK ON\nTO TRAIN", color=(120, 235, 255), label_name="TreadmillText",
                 stroke=0.3, pixels_per_stud=40)
    surface_text(console, "Front", "TREADMILL", color=(255, 255, 255), label_name="TreadmillOwnerText",
                 stroke=0.3, pixels_per_stud=40)
    p("AccentBar", (5.6, 0.25, 1.2), (0, 6.42, -5.7), TREADMILL_TRIM, "Neon", collide=False)

    # Script markers: the runner is held at RunPoint facing its LookVector; ESCAPE drops you at ExitPoint.
    marker(m, "RunPoint", tcf * CF(0, 3.5, -0.5), (1, 1, 1))
    marker(m, "ExitPoint", tcf * CF(-6, 3.2, 0.5), (1, 1, 1))

    # A sign on the far side so everyone knows what it is.
    for z in (-3.0, 4.0):
        p("SignPost", (0.4, 5, 0.4), (6.5, 2.5, z), DARK, "Metal")
    sign = p("Sign", (0.4, 4, 8), (6.5, 6.4, 0.5), (24, 26, 34), "SmoothPlastic")
    surface_text(sign, "Left", "🏃 TREADMILL\nWalk on to train speed.\nWorks while you're AFK!",
                 color=(120, 230, 255), font="Builder", weight=700, stroke=None, pixels_per_stud=30)
    return m


# ---------------------------------------------------------------------------
# The yard: the spawn area. Six garages in a U around a parking lot, the two
# back-to-back market stalls in the middle, cliffs on every closed side.
# ---------------------------------------------------------------------------

YARD_CX = -320.0                  # centre of the parking lot
YARD_HALF_W = 110.0               # the lot spans x = YARD_CX ± YARD_HALF_W
YARD_HALF_D = 100.0               # the lot spans z = ±YARD_HALF_D
GARAGE_HALF = 35.0                # a garage's centre sits this far from its row's middle (64 + a 6 stud gap)
GARAGE_FRONT = 24.0               # half of a garage's depth: the wall its door is in
YARD_SETBACK = 3.0                # the cliff face sits this far behind the garages' back walls
YARD_MOUTH_X = YARD_CX + YARD_HALF_W                          # -210: the lot's east edge, where the road starts
YARD_FACE_Z = YARD_HALF_D + 2 * GARAGE_FRONT + YARD_SETBACK   # 151: the cliff behind the north/south rows
YARD_FACE_X = YARD_CX - YARD_HALF_W - 2 * GARAGE_FRONT - YARD_SETBACK  # -481: the cliff behind the west row
YARD_ROW_X = YARD_FACE_X + YARD_SETBACK + GARAGE_FRONT        # -454: centre of the west row's garages
YARD_CLIFF_H = (30, 46)           # the yard's cliffs stand taller than the garages they sit behind
STALL_W, STALL_D, STALL_H = 24.0, 14.0, 8.0

# PlotIndex order: two garages on the north side, two on the west side, two on the south side.
YARD_PLOTS = (
    (YARD_CX - GARAGE_HALF, -(YARD_HALF_D + GARAGE_FRONT), 0),
    (YARD_CX + GARAGE_HALF, -(YARD_HALF_D + GARAGE_FRONT), 0),
    (YARD_ROW_X, -GARAGE_HALF, 90),
    (YARD_ROW_X, +GARAGE_HALF, 90),
    (YARD_CX + GARAGE_HALF, +(YARD_HALF_D + GARAGE_FRONT), 180),
    (YARD_CX - GARAGE_HALF, +(YARD_HALF_D + GARAGE_FRONT), 180),
)


def market_stall(parent: Inst, name: str, cf: CF, *, variant: str, counter_name: str, sign: str, sign_color,
                 blurb: str) -> Inst:
    """One wooden market stall: local +Z is the customer side, the back wall is at local -Z.

    `variant` is "shop" (shelves stacked with one crate per upgrade) or "sell" (the trader's
    counter: scales, a cash box and bags of money).
    """
    stall = model(parent, name, cf)
    W, D, H = STALL_W, STALL_D, STALL_H

    def p(n, size, pos, col, mat="WoodPlanks", rot=None, **kw):
        frame = cf * CF(*pos)
        if rot:
            frame = frame * CF.deg(*rot)
        return part(stall, n, size, frame, col, mat, **kw)

    p("Deck", (W, 0.3, D), (0, 0.15, 0), (150, 116, 82), "WoodPlanks")
    p("BackWall", (W, H, 0.7), (0, H / 2, -D / 2 + 0.35), (172, 122, 76), "WoodPlanks")
    for sx in (-1, 1):
        p("SideWall", (0.7, H, D - 0.7), (sx * (W / 2 - 0.35), H / 2, 0.35), (172, 122, 76), "WoodPlanks")
        p("Post", (0.75, H, 0.75), (sx * (W / 2 - 0.4), H / 2, D / 2 + 1.2), (120, 86, 56), "Wood")
    p("Roof", (W + 2.6, 0.6, D + 4), (0, H + 0.3, 0.6), (88, 60, 40), "Metal")
    for i in range(6):  # the striped awning valance over the counter
        p("AwningStripe", (4, 1.6, 0.4), (-W / 2 + 2 + i * 4, H - 0.9, D / 2 + 2.3),
          sign_color if i % 2 == 0 else (245, 245, 242), "Fabric")
    p(counter_name, (W - 3, 3.4, 3.2), (0, 1.85, D / 2 - 1.5), (198, 162, 114), "WoodPlanks")
    p("CounterTop", (W - 2, 0.3, 3.6), (0, 3.7, D / 2 - 1.5), (232, 226, 214), "Marble")
    p("CounterSkirt", (W - 3, 1.2, 0.4), (0, 1.0, D / 2 + 0.1), (120, 86, 56), "Wood")
    for y in (3.6, 6.2):  # shelves along the back wall
        p("Shelf", (W - 4, 0.3, 3.0), (0, y, -D / 2 + 2.0), (170, 128, 84), "WoodPlanks")
    board = p("StallSign", (W - 2, 3.4, 0.4), (0, H + 2.4, D / 2 + 2.3), (74, 54, 40), "Wood")
    for face in ("Front", "Back"):
        surface_text(board, face, sign, color=sign_color, font="Luckiest", stroke=None, pixels_per_stud=40)
    note = p("StallNote", (W - 6, 2.4, 0.3), (0, 4.7, -D / 2 + 0.75), (24, 26, 34), "SmoothPlastic")
    surface_text(note, "Front", blurb, color=(240, 240, 245), font="Builder", weight=700, stroke=None,
                 pixels_per_stud=34)

    if variant == "shop":
        for x, color in ((-8, (215, 90, 70)), (-4, (90, 150, 215)), (0, (110, 190, 110)), (4, (230, 180, 60)),
                         (8, (170, 110, 210))):  # one little crate per upgrade the shop sells
            p("Crate", (3.0, 2.4, 2.4), (x, 1.4, -D / 2 + 2.6), (170, 130, 80), "WoodPlanks")
            p("Goods", (1.7, 1.7, 1.7), (x, 3.4, -D / 2 + 2.6), color, "SmoothPlastic", shape="Ball", collide=False)
    else:
        # The trader's scales: a brass post with a beam and two pans.
        p("ScalesPost", (0.5, 3.2, 0.5), (6.0, 5.3, D / 2 - 1.6), (196, 158, 62), "Metal", shape="Cylinder")
        p("ScalesBeam", (4.6, 0.24, 0.24), (6.0, 6.9, D / 2 - 1.6), (222, 186, 88), "Metal", rot=(0, 0, 90),
          shape="Cylinder")
        for x in (3.8, 8.2):
            p("ScalesChain", (0.1, 1.0, 0.1), (x, 6.4, D / 2 - 1.6), (170, 140, 70), "Metal", collide=False)
            p("ScalesPan", (2.2, 0.24, 2.2), (x, 5.9, D / 2 - 1.6), (204, 170, 74), "Metal", shape="Cylinder")
        # A cash box, its lid open, and bags of takings.
        p("CashBox", (3.0, 2.0, 2.4), (-6.4, 4.85, D / 2 - 1.8), (70, 78, 92), "Metal")
        p("CashBoxLid", (3.0, 0.3, 2.4), (-6.4, 6.6, D / 2 - 2.6), (86, 96, 112), "Metal", rot=(-38, 0, 0))
        p("Banknotes", (2.4, 0.9, 1.8), (-6.4, 6.3, D / 2 - 1.8), (120, 190, 120), "Fabric", collide=False)
        for i, (x, z) in enumerate(((-9.2, D / 2 - 2.2), (-8.2, D / 2 - 3.4), (-10.0, D / 2 - 3.6))):
            p("MoneyBag", (2.0 - i * 0.2, 2.0 - i * 0.2, 2.0 - i * 0.2), (x, 4.6 + (2.0 - i * 0.2) / 2, z),
              (168, 132, 74), "Fabric", shape="Ball")
        p("MoneyBagKnot", (0.5, 0.5, 0.5), (-9.2, 5.9, D / 2 - 2.2), (128, 96, 50), "Fabric", shape="Ball",
          collide=False)
        p("Ledger", (2.4, 0.2, 3.0), (-2.0, 3.95, D / 2 - 1.4), (232, 226, 210), "SmoothPlastic", rot=(0, -14, 0))
        p("LedgerPen", (0.16, 0.16, 2.0), (-1.0, 4.1, D / 2 - 1.2), (40, 42, 52), "Metal", rot=(0, -20, 0),
          shape="Cylinder", collide=False)
        # A "WE BUY LOOT" board on the counter.
        buy = p("BuySign", (9, 2.6, 0.3), (0, 5.6, D / 2 - 0.9), (36, 92, 60), "SmoothPlastic")
        surface_text(buy, "Front", "WE BUY LOOT", color=(190, 255, 200), font="Builder", weight=700, stroke=None,
                     pixels_per_stud=44)
    lamp = p("StallLight", (W - 6, 0.4, 2), (0, H - 0.5, 2.0), (255, 246, 226), "Neon", collide=False)
    point_light(lamp, (255, 244, 224), 1.1, 26)
    return stall


def build_yard(map_folder: Inst, ground: Inst, decor: Inst):
    """The spawn area: the paved lot and its markings, the two market stalls and the yard's signage."""
    yard = model(map_folder, "Hub", CF(YARD_CX, 0, 0))

    # The paved site. Every garage keeps its own concrete apron and dock markings; one big asphalt slab
    # underneath fills the lot between them and the cliffs.
    part(ground, "LotPad", (YARD_MOUTH_X - YARD_FACE_X + 8.0, 0.2, YARD_FACE_Z * 2 + 8.0),
         CF((YARD_FACE_X + YARD_MOUTH_X) / 2 - 4.0, 0.0, 0), (74, 76, 80), "Asphalt")

    # Parking bays on both sides of the middle island
    for side in (-1, 1):
        for i in range(9):
            part(decor, "BayLine", (0.6, 0.06, 18.0), CF(YARD_CX - 56 + i * 14, 0.21, side * 29), WHITE,
                 collide=False, query=False, shadow=False)

    # The two market stalls, back to back in the middle of the lot: the upgrade shop faces the spawn, the
    # trader's sell point faces back towards the garages. They share the wall down the middle.
    market_stall(map_folder, "Shop", CF(YARD_CX + STALL_D / 2, 0, 0) * CF.deg(0, 90, 0), variant="shop",
                 counter_name="ShopCounter", sign="🛒 UPGRADE SHOP", sign_color=(255, 196, 54),
                 blurb="Bag, storage, treadmill")
    market_stall(map_folder, "SellPoint", CF(YARD_CX - STALL_D / 2, 0, 0) * CF.deg(0, -90, 0), variant="sell",
                 counter_name="SellCounter", sign="💰 SELL POINT", sign_color=(120, 235, 150),
                 blurb="Bag it, bring it, cash it in")

    # Spawn: in the drive lane at the mouth of the yard, looking at the stalls.
    spawn = Inst("SpawnLocation", "HubSpawn", yard)
    spawn.set(**{
        "size": _v3((10, 0.5, 10)), "CFrame": CF(YARD_CX + 70, 0.45, 0) * CF.deg(0, 90, 0),
        "Color3uint8": C3u8(255, 196, 54), "Material": Token(MATERIALS["SmoothPlastic"]), "Anchored": True,
        "TopSurface": Token(0), "BottomSurface": Token(0), "Neutral": True, "Duration": Int(0),
        "AllowTeamChangeOnTouch": False,
    })

    # How to play board, in the open corner by the way in, facing the arriving players.
    board = part(yard, "HowToPlay", (1, 15, 26), CF(YARD_MOUTH_X - 3, 8.6, -52), (28, 30, 44), "SmoothPlastic")
    for z in (-61, -43):
        part(yard, "BoardPost", (0.8, 3.4, 0.8), CF(YARD_MOUTH_X - 3, 1.7, z), DARK, "Metal")
    howto = ('<font color="#FFC83C">HOW TO PLAY</font>\n'
             '1. Run down the street to a house\n'
             '2. Hold E to pick the lock, then steal loot\n'
             '3. Stealing trips the alarm! They chase you back to the yard\n'
             '4. Sprint home with the loot — inside a house everyone moves at the same speed\n'
             '5. Drop it on your warehouse\'s green DEPOSIT pad\n'
             '6. Stored loot earns 💰 every second!\n'
             '7. Buy upgrades at the market stall, and run on the treadmill outside your warehouse')
    surface_text(board, "Right", howto, color=(240, 240, 250), font="Builder", weight=700, rich=True, stroke=None,
                 pixels_per_stud=34)

    # The game's title arch, over the road where it leaves the yard.
    gate = YARD_MOUTH_X + 8.0
    arch = model(yard, "TitleArch", CF(gate, 0, 0))
    for z in (-21.5, 21.5):
        part(arch, "ArchPillar", (3.5, 26, 3.5), CF(gate, 13, z), (60, 40, 90), "Brick")
        part(arch, "ArchLight", (3.7, 1, 3.7), CF(gate, 24, z), (255, 196, 54), "Neon", collide=False)
    beam = part(arch, "ArchBeam", (3.5, 7, 47), CF(gate, 29.5, 0), (40, 28, 64), "SmoothPlastic")
    for face in ("Right", "Left"):
        surface_text(beam, face, "🦝 STEAL AN ITEM 🦝", color=(255, 210, 60), font="Luckiest", stroke=0.2,
                     pixels_per_stud=30)

    # Lamps and planters around the lot
    for x in (YARD_CX - 65, YARD_CX + 45):
        for z in (-50.0, 50.0):
            street_lamp(decor, CF(x, 0.3, z))
    for sx in (-1, 1):  # a planter at each corner of the island
        for sz in (-1, 1):
            x, z = YARD_CX + sx * (STALL_D + 2.0), sz * (STALL_W / 2 - 1.5)
            part(decor, "Planter", (3.6, 2.0, 3.6), CF(x, 1.0, z), (110, 82, 56), "WoodPlanks")
            bush(decor, CF(x, 2.0, z), 3.0, LEAF)  # bush() grows its leaves upward from the given base
    return yard


# ---------------------------------------------------------------------------
# Roads, decor, boundaries
# ---------------------------------------------------------------------------

ROAD_X0, ROAD_X1 = -252.0, 530.0  # the asphalt starts inside the yard's mouth and runs to the Mansion gate
WALK_X0 = -204.0                  # the pavements start where the parking lot ends
CROSSWALK_X = -190.0              # where the yard's drive lane empties onto the street
MAP_X0, MAP_X1, MAP_Z = -580.0, 700.0, 215.0


def build_roads(ground: Inst, decor: Inst, entrances: list[tuple[float, float]]):
    length = ROAD_X1 - ROAD_X0
    mid = (ROAD_X0 + ROAD_X1) / 2
    walk_length = ROAD_X1 - WALK_X0
    walk_mid = (WALK_X0 + ROAD_X1) / 2
    part(ground, "MainStreet", (length, 0.2, 32), CF(mid, 0.1, 0), ASPHALT, "Asphalt")
    for z in (-20, 20):
        part(ground, "Sidewalk", (walk_length, 0.3, 8), CF(walk_mid, 0.15, z), SIDEWALK, "Concrete")
        part(ground, "Curb", (walk_length, 0.34, 0.6), CF(walk_mid, 0.17, z - math.copysign(3.7, z)),
             (150, 150, 146), "Concrete")
    x = ROAD_X0 + 10
    while x < ROAD_X1 - 10:
        if not (CROSSWALK_X - 15 < x < CROSSWALK_X + 15):
            part(decor, "LaneDash", (9, 0.04, 0.6), CF(x, 0.22, 0), YELLOW, collide=False, query=False, shadow=False)
        x += 20
    # Crosswalk where the yard's drive lane meets the street
    for i in range(11):
        part(decor, "Crosswalk", (6, 0.04, 1.4), CF(CROSSWALK_X, 0.22, -14 + i * 2.8), WHITE, collide=False,
             query=False, shadow=False)
    # Road end at the mansion gate
    part(decor, "RoadEnd", (1.2, 0.3, 32), CF(ROAD_X1 - 0.6, 0.25, 0), (200, 200, 196), "Concrete")

    # Street lamps (skip spots in front of driveways and gates)
    def blocked(px: float) -> bool:
        return any(abs(px - ex) < half + 5 for ex, half in entrances)

    x = WALK_X0 + 21
    side = 1
    while x < ROAD_X1 - 10:
        z = 23.0 * side
        if not blocked(x):
            street_lamp(decor, CF(x, 0.3, z) * CF.deg(0, 0 if side > 0 else 180, 0))
        x += 45
        side = -side


def road_sign(parent: Inst, x: float, z: float, text: str, facing_yaw: float):
    m = model(parent, "RoadSign", CF(x, 0, z))
    part(m, "Post", (0.5, 9, 0.5), CF(x, 4.5, z), DARK, "Metal")
    board = part(m, "Board", (10, 3, 0.4), CF(x, 8, z) * CF.deg(0, facing_yaw, 0), (30, 120, 60), "SmoothPlastic")
    surface_text(board, "Front", text, color=(255, 255, 255), stroke=None, pixels_per_stud=30)
    surface_text(board, "Back", text, color=(255, 255, 255), stroke=None, pixels_per_stud=30)


def build_boundary(map_folder: Inst, decor: Inst):
    walls = Inst("Folder", "Boundary", map_folder)
    w = MAP_X1 - MAP_X0
    mid = (MAP_X0 + MAP_X1) / 2
    for z in (-MAP_Z, MAP_Z):
        part(walls, "InvisibleWall", (w, 120, 2), CF(mid, 60, z), (255, 255, 255), transparency=1, shadow=False)
    for x in (MAP_X0, MAP_X1):
        part(walls, "InvisibleWall", (2, 120, MAP_Z * 2), CF(x, 60, 0), (255, 255, 255), transparency=1, shadow=False)
    # Tree lines along the north and south edges
    x = MAP_X0 + 15
    i = 0
    while x < MAP_X1 - 10:
        for z in (-MAP_Z + 10, MAP_Z - 10):
            tree(decor, CF(x, 0, z + (i % 3 - 1) * 3), 1.2 + (i % 4) * 0.1, "pine" if i % 2 else "round")
        x += 26
        i += 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Paint for the ten identical houses (street order). "pet" is the colour of the guard's bed.
HOUSE_PALETTES = [
    {"wall": (240, 228, 196), "roof": (150, 70, 52), "door": (130, 60, 40), "carpet": (190, 120, 120),
     "sofa": (90, 130, 180), "rug": (200, 160, 90), "bed": (220, 120, 140), "bush": LEAF, "accent": WOOD,
     "pet": (200, 70, 80)},
    {"wall": (200, 230, 210), "roof": (80, 90, 110), "door": (60, 90, 130), "carpet": (140, 170, 200),
     "sofa": (170, 90, 80), "rug": (120, 160, 120), "bed": (110, 170, 230), "bush": (90, 160, 70), "accent": WOOD_DARK,
     "pet": (70, 110, 190)},
    {"wall": (250, 214, 214), "roof": (110, 60, 60), "door": (90, 50, 40), "carpet": (210, 190, 150),
     "sofa": (100, 150, 110), "rug": (220, 200, 160), "bed": (240, 200, 90), "bush": LEAF_DARK, "accent": WOOD,
     "pet": (150, 80, 160)},
    {"wall": (255, 238, 170), "roof": (60, 100, 70), "door": (50, 80, 60), "carpet": (170, 140, 200),
     "sofa": (200, 120, 60), "rug": (150, 120, 180), "bed": (150, 200, 120), "bush": LEAF, "accent": WOOD_DARK,
     "pet": (60, 150, 110)},
    {"wall": (150, 190, 220), "roof": (70, 72, 80), "door": (180, 40, 40), "carpet": (170, 160, 150),
     "sofa": (60, 70, 90), "rug": (180, 60, 60), "bed": (70, 110, 170), "bush": LEAF, "accent": WOOD,
     "pet": (180, 50, 50)},
    {"wall": (230, 225, 210), "roof": (90, 60, 50), "door": (40, 70, 120), "carpet": (120, 140, 120),
     "sofa": (160, 150, 130), "rug": (60, 90, 140), "bed": (190, 80, 80), "bush": LEAF_DARK, "accent": WOOD_DARK,
     "pet": (60, 90, 160)},
    {"wall": (190, 210, 170), "roof": (60, 64, 70), "door": (240, 240, 240), "carpet": (200, 180, 170),
     "sofa": (110, 60, 60), "rug": (90, 130, 90), "bed": (230, 200, 120), "bush": LEAF, "accent": WOOD,
     "pet": (200, 130, 50)},
    {"wall": (210, 180, 160), "roof": (70, 50, 46), "door": (30, 60, 40), "carpet": (150, 160, 190),
     "sofa": (70, 110, 140), "rug": (200, 150, 80), "bed": (120, 90, 170), "bush": (80, 150, 60), "accent": WOOD_DARK,
     "pet": (90, 70, 60)},
    {"wall": (242, 242, 238), "roof": (54, 56, 62), "door": (60, 60, 66), "carpet": (190, 190, 200),
     "sofa": (230, 230, 225), "rug": (40, 42, 48), "bed": (40, 40, 46), "bush": LEAF_DARK, "accent": (60, 62, 70),
     "pet": (50, 52, 60)},
    {"wall": (225, 222, 214), "roof": (40, 42, 48), "door": (120, 40, 40), "carpet": (170, 150, 130),
     "sofa": (60, 62, 70), "rug": (200, 180, 140), "bed": (150, 120, 90), "bush": LEAF, "accent": (90, 60, 40),
     "pet": (130, 40, 40)},
]
FIRST_HOUSE_X = 30.0
HOUSE_PITCH = 50.0  # houses alternate sides, so neighbours on the same side are 100 studs apart


def build_map(workspace: Inst) -> Inst:
    tiers = read_house_tiers()
    street = read_houses()
    mansion = street.pop()
    map_folder = Inst("Folder", "Map", workspace)
    # West of the canyon mouth is the yard, where a chase is over (the server reads this).
    map_folder.attr(SafeX=YARD_MOUTH_X)
    ground = Inst("Folder", "Ground", map_folder)
    decor = Inst("Folder", "Decor", map_folder)
    houses = Inst("Folder", "Houses", map_folder)
    warehouses = Inst("Folder", "Warehouses", map_folder)
    cliffs = Inst("Folder", "Cliffs", map_folder)

    # Ground extends well past the invisible boundary walls (2048 = max part size) so the edge of the
    # world fades into the atmosphere instead of looking like a cliff.
    mid = (MAP_X0 + MAP_X1) / 2
    part(ground, "Grass", (2048, 4, 2048), CF(mid, -2, 0), GRASS, "Grass")

    entrances: list[tuple[float, float]] = []

    # The yard at the west end of the street: six garages around the spawn parking lot. Each one sits a
    # hair higher than the last so the aprons that overlap in the corners never fight over one plane.
    for index, (x, z, yaw) in enumerate(YARD_PLOTS, start=1):
        build_warehouse(warehouses, ground, index, CF(x, 0.003 * index, z) * CF.deg(0, yaw, 0))
    build_yard(map_folder, ground, decor)
    build_yard_cliffs(cliffs, decor)
    build_corridor_cliffs(cliffs, decor)

    # The street: one house design, alternating sides, harder the further east you go.
    sides: dict[int, list[float]] = {-1: [], 1: []}
    for i, info in enumerate(street):
        x = FIRST_HOUSE_X + i * HOUSE_PITCH
        side = -1 if i % 2 == 0 else 1
        lot_cf = CF(x, 0, side * (SIDEWALK_EDGE + LOT_D / 2)) * CF.deg(0, 0 if side < 0 else 180, 0)
        build_house(houses, info, tiers[info["tier"] - 1], lot_cf, HOUSE_PALETTES[i % len(HOUSE_PALETTES)])
        sides[side].append(x)
        entrances.append((x, 4))
    starts = {side: min(xs) - HOUSE_PITCH for side, xs in sides.items()}
    build_street_cliffs(cliffs, decor, sides, starts, ROAD_X1)
    build_frontage(decor, sides, starts)

    # The Mansion at the end of the street (front faces west, toward the road)
    mansion_cf = CF(ROAD_X1 + 75, 0, 0) * CF.deg(0, -90, 0)
    build_mansion(houses, mansion, tiers[3], mansion_cf)
    build_mansion_cliff(cliffs, decor, mansion_cf)

    build_roads(ground, decor, entrances)
    road_sign(decor, -30, -23, "RICH NEIGHBORHOOD ➜", 0)
    road_sign(decor, -170, 23, "⬅ YOUR GARAGE", 0)
    build_boundary(map_folder, decor)

    # Street trees on the grass between the yard and the neighbourhood
    for x in (-170.0, -110.0):
        for z in (-34.0, 34.0):
            tree(decor, CF(x, 0, z), 1.1)
    return map_folder


def build_frontage(decor: Inst, sides: dict[int, list[float]], starts: dict[int, float]):
    """Trees, bushes and boulders on the grass between the pavement and the cliff opposite each house."""
    rng = random.Random(77)
    for side, xs in sides.items():
        edges = [starts[side]] + [x for hx in sorted(xs) for x in (hx - LOT_W / 2, hx + LOT_W / 2)] + [ROAD_X1]
        for a, b in zip(edges[0::2], edges[1::2]):
            if b - a < 12:
                continue
            mid_x = (a + b) / 2
            z = side * (SIDEWALK_EDGE + (CLIFF_FACE_Z - SIDEWALK_EDGE) * 0.55)
            tree(decor, CF(mid_x, 0, z), rng.uniform(1.0, 1.25), "pine" if rng.random() < 0.5 else "round")
            for _ in range(3):
                bx = rng.uniform(a + 3, b - 3)
                bush(decor, CF(bx, 0, side * (CLIFF_FACE_Z - 2.2)), rng.uniform(2.2, 3.2),
                     LEAF if rng.random() < 0.5 else LEAF_DARK)
            size = rng.uniform(2.5, 4.5)
            part(decor, "Boulder", (size, size, size),
                 CF(rng.uniform(a + 4, b - 4), size * 0.4, side * (CLIFF_FACE_Z - 5)) * CF.deg(0, rng.uniform(0, 90), 0),
                 rng.choice(ROCK_COLORS), "Rock")
