"""
Procedurally builds the Steal an Item city into Workspace.Map.

Layout (top-down, X = east, Z = south, the main street runs along Z = 0):

    west [THE YARD: 6 garages + spawn parking lot] -canyon- [CITY: avenues and
         cross streets in a grid, 10 named houses on the main street plus about
         forty numbered city houses] ... [MUSEUM on its hill] east

The trip from the warehouses to the museum is ten times longer than the old
street was: the museum still stands at the far east end (and keeps the best
loot), and a city fills the space between. The guide's named houses stand on
the main street on a progression curve (the first a short walk from the yard,
then ever further apart); numbered city houses fill the
grid, each at the difficulty level its straight-line distance from the
warehouses earns it (within the guide's 3% slack), borrowing that level's
guard and loot table. Three house shapes keep the streets varied: cottages,
ranch houses and two-storey town houses with the best pieces upstairs (the
defenders cannot climb stairs - they wait below).

Everything the game scripts rely on is named/attributed exactly as the server
expects (see the header comments in src/server/*.luau); the street network is
published as the Map's "Lanes" attribute for the chase routing.
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

# --- Palette: bright pastel "candy town" — cream bases, sorbet accents, nothing murky ---
WHITE = (245, 245, 242)
OFFWHITE = (238, 234, 224)
BLACK = (24, 24, 28)
DARK = (88, 94, 110)        # soft slate instead of near-black (small accents only)
GOLD = (255, 196, 54)
GLASS = (196, 226, 247)
WOOD = (208, 158, 98)
WOOD_DARK = (158, 110, 70)
WOOD_LIGHT = (232, 198, 152)
STONE = (150, 150, 155)
GRASS = (98, 190, 80)
LEAF = (92, 200, 82)
LEAF_DARK = (68, 168, 66)
ASPHALT = (120, 124, 136)   # light bluish pavement
SIDEWALK = (234, 228, 214)  # cream pavement
CONCRETE = (210, 208, 200)
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
        # Nothing collides with it, so nothing should feel it either: a cast that stopped on a
        # flower would have every defender in the front yard walking round the flowerbeds.
        props["CanQuery"] = False
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


# Keep practical lights at one restrained street-light level.  Previously the
# three wide warehouse lights overlapped at high intensity, while nearby lamps
# used several unrelated values, making exposure jump sharply between areas.
LIGHT_BRIGHTNESS_MAX = 0.55
LIGHT_RANGE_MAX = 24


def point_light(parent: Inst, color=(255, 226, 180), brightness: float = LIGHT_BRIGHTNESS_MAX,
                light_range: float = 22, shadows: bool = False) -> Inst:
    light = Inst("PointLight", "Light", parent)
    light.set(
        Color=C3.rgb(*color),
        Brightness=Float(min(brightness, LIGHT_BRIGHTNESS_MAX)),
        Range=Float(min(light_range, LIGHT_RANGE_MAX)),
        Shadows=shadows,
    )
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
             (110, 198, 92), "LeafyGrass", shape="Ball", collide=False)
    return m


def bush(parent: Inst, base: CF, size: float = 3.0, color=LEAF) -> Inst:
    return part(parent, "Bush", (size, size * 0.8, size), base * CF(0, size * 0.3, 0), color, "LeafyGrass",
                shape="Ball", collide=False)


def street_lamp(parent: Inst, base: CF) -> Inst:
    m = model(parent, "StreetLamp", base)
    part(m, "Pole", (0.6, 15, 0.6), base * CF(0, 7.5, 0), WHITE, "SmoothPlastic")
    part(m, "Base", (1.4, 1, 1.4), base * CF(0, 0.5, 0), WHITE, "SmoothPlastic")
    part(m, "Arm", (0.4, 0.4, 4), base * CF(0, 14.8, -1.8), WHITE, "SmoothPlastic")
    lamp = part(m, "Lamp", (1.4, 0.6, 2.2), base * CF(0, 14.4, -3.6), (255, 240, 200), "Neon", collide=False)
    point_light(lamp, (255, 226, 170), 0.8, 26)
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
                 house_w: float, house_d: float, wall_h: float, front_yard: float, scale: float = 1.0):
        self.lot_cf = lot_cf
        self.lot_w, self.lot_d = lot_w, lot_d
        self.W, self.D, self.H = house_w, house_d, wall_h
        # Everything written below is in the plan's own units; `scale` blows the plan up to the size
        # the house really is (rooms get bigger, the furniture keeps its size).
        self.scale = scale
        out_d = house_d * scale
        self.hz = lot_d / 2 - front_yard - out_d / 2
        self.cf = lot_cf * CF(0, 0, self.hz)
        self.model = model(folder, name, self.cf)
        self.model.attr(Tier=tier, DisplayName=display)
        self.structure = model(self.model, "Structure", self.cf)
        self.furniture = model(self.model, "Furniture", self.cf)
        self.yard = model(self.model, "Yard", lot_cf)
        self.spots = Inst("Folder", "ItemSpots", self.model)
        self.docks = Inst("Folder", "GuardDocks", self.model)
        self.route = Inst("Folder", "Route", self.model)
        self.rooms = Inst("Folder", "Rooms", self.model)
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
        if frame is None and self.scale != 1.0:
            # Plan coordinates: widen them with the house. (Anything placed inside a furniture frame
            # or in lot coordinates is already real-world sized, so it is left alone - and stays as
            # roomy as the bigger rooms around it.)
            size = (size[0] * self.scale, size[1], size[2] * self.scale)
            pos = (pos[0] * self.scale, pos[1], pos[2] * self.scale)
        cf = base * CF(*pos)
        if rot:
            cf = cf * CF.deg(*rot)
        return part(parent if parent is not None else self.structure, name, size, cf, color, material, **kw)

    def y(self, name, size, pos, color, material="SmoothPlastic", rot=None, **kw) -> Inst:
        """Part in lot coordinates (yard)."""
        return self.p(name, size, pos, color, material, rot, parent=self.yard, frame=self.lot_cf, **kw)

    def route_node(self, name: str, x: float, z: float):
        """An invisible marker on the way in or out of a room: where a guard has to thread a
        doorway. Sized and placed in plan coordinates like everything else (so it scales with the
        house), and queryable by nothing: it is a signpost, not furniture."""
        return self.p(name, (0.6, 0.6, 0.6), (x, self.FLOOR_Y, z), (255, 60, 60),
                      parent=self.route, transparency=1, collide=False, query=False, touch=False, shadow=False)

    def route_lot(self, name: str, x: float, z: float):
        """A route marker in the lot's own frame, for a signpost that is not part of the house plan:
        the gate in the front fence, the pavement outside it, and the middle of the front doorway -
        the way in and out of the lot for a defender that walks it."""
        return self.p(name, (0.6, 0.6, 0.6), (x, self.FLOOR_Y, z), (255, 60, 60), parent=self.route,
                      frame=self.lot_cf, transparency=1, collide=False, query=False, touch=False, shadow=False)

    def room(self, name: str, x0: float, z0: float, x1: float, z1: float, via: str | None = None):
        """A box over one room's floor, invisible and unqueryable, with the room's name on it. The
        server asks which room a defender (or its quarry) is standing in, so that a doorway only
        ever counts as the way to something in *another* room - a table in the way of something in
        the same room is just a table, and is walked around. `via` names the route node that is
        that room's way out (every room here opens off the hall)."""
        box = self.p(name, (abs(x1 - x0), ROOM_BOX_H, abs(z1 - z0)),
                     ((x0 + x1) / 2, self.FLOOR_Y + ROOM_BOX_H / 2, (z0 + z1) / 2),
                     (60, 200, 255), parent=self.rooms, transparency=1, collide=False, query=False, touch=False,
                     shadow=False)
        if via:
            box.attr(Via=via)
        return box

    def frame(self, x: float, z: float, facing: str, y: float | None = None) -> CF:
        """A spot on the plan's floor, scaled up with the house: furniture and guard posts land where
        the plan puts them, inside the bigger rooms."""
        return self.cf * CF(x * self.scale, self.FLOOR_Y if y is None else y, z * self.scale) \
            * CF.deg(0, YAW[facing], 0)

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
                # A white frame ring is hidden inside the wall and peeks out around the opening
                # (thinner than the wall, so it only shows as the border of the hole).
                self.p("WindowFrame", (b - a + 0.55, y1 - y0 + 0.55, 0.45), ((a + b) / 2, (y0 + y1) / 2, z),
                       WHITE, "SmoothPlastic")
                self.p("Window", (b - a - 0.2, y1 - y0 - 0.2, 0.2), ((a + b) / 2, (y0 + y1) / 2, z), GLASS, "Glass",
                       transparency=0.55, reflectance=0.15)
                self.p("Sill", (b - a + 0.6, 0.3, t + 0.5), ((a + b) / 2, y0 - 0.15, z), WHITE, "SmoothPlastic")
                self.p("Lintel", (b - a + 0.6, 0.3, t + 0.5), ((a + b) / 2, y1 + 0.15, z), WHITE, "SmoothPlastic")
            else:
                self.p(name, (b - a, y1 - y0, t), ((a + b) / 2, (y0 + y1) / 2, z), color, material)
                if name != "InteriorWall" and material == "Plaster" and b - a > 4 and y1 - y0 > 4:
                    # Clapboard siding: thin shadowed seams every few studs of height, so the flat
                    # pastel wall reads as painted boards instead of one plastic slab.
                    groove = tuple(max(0, int(c * 0.88)) for c in color)
                    face = z + math.copysign(t / 2, z)
                    gy = y0 + 3.2
                    while gy < y1 - 1.4:
                        self.p("Siding", (b - a, 0.16, 0.18), ((a + b) / 2, gy, face), groove, material,
                               collide=False, shadow=False)
                        gy += 3.2

    def wall_z(self, x, z0, z1, t, h, openings, color, material, name="Wall"):
        for a, b, y0, y1, kind in self._segments(z0, z1, h, openings):
            if b - a < 0.01 or y1 - y0 < 0.01:
                continue
            if kind == "window":
                self.p("WindowFrame", (0.45, y1 - y0 + 0.55, b - a + 0.55), (x, (y0 + y1) / 2, (a + b) / 2),
                       WHITE, "SmoothPlastic")
                self.p("Window", (0.2, y1 - y0 - 0.2, b - a - 0.2), (x, (y0 + y1) / 2, (a + b) / 2), GLASS, "Glass",
                       transparency=0.55, reflectance=0.15)
                self.p("Sill", (t + 0.5, 0.3, b - a + 0.6), (x, y0 - 0.15, (a + b) / 2), WHITE, "SmoothPlastic")
                self.p("Lintel", (t + 0.5, 0.3, b - a + 0.6), (x, y1 + 0.15, (a + b) / 2), WHITE, "SmoothPlastic")
            else:
                self.p(name, (t, y1 - y0, b - a), (x, (y0 + y1) / 2, (a + b) / 2), color, material)
                if name != "InteriorWall" and material == "Plaster" and b - a > 4 and y1 - y0 > 4:
                    groove = tuple(max(0, int(c * 0.88)) for c in color)
                    face = x + math.copysign(t / 2, x)
                    gy = y0 + 3.2
                    while gy < y1 - 1.4:
                        self.p("Siding", (0.18, 0.16, b - a), (face, gy, (a + b) / 2), groove, material,
                               collide=False, shadow=False)
                        gy += 3.2

    def exterior(self, t, color, material, front, back, left, right):
        W, D, H = self.W, self.D, self.H
        self.t = t
        self.wall_x(D / 2 - t / 2, -W / 2, W / 2, t, H, front, color, material, "FrontWall")
        self.wall_x(-D / 2 + t / 2, -W / 2, W / 2, t, H, back, color, material, "BackWall")
        self.wall_z(-W / 2 + t / 2, -D / 2 + t, D / 2 - t, t, H, left, color, material, "SideWall")
        self.wall_z(W / 2 - t / 2, -D / 2 + t, D / 2 - t, t, H, right, color, material, "SideWall")
        # Foundation the floor sits on
        self.p("Foundation", (W + 0.6, 0.5, D + 0.6), (0, 0.25, 0), (172, 168, 160), "Concrete")
        # White painted trim: corner boards covering the wall seams and a skirting board along the
        # base. This is what turns the flat pastel walls from "plastic block" into a painted house.
        for sx in (-1, 1):
            for sz in (-1, 1):
                self.p("CornerTrim", (t + 0.35, H, t + 0.35), (sx * (W / 2 - t / 2), H / 2, sz * (D / 2 - t / 2)),
                       WHITE, "SmoothPlastic")
        self.p("BaseTrim", (W, 0.6, t + 0.3), (0, 0.3, D / 2 - t / 2), WHITE, "SmoothPlastic")
        self.p("BaseTrim", (W, 0.6, t + 0.3), (0, 0.3, -D / 2 + t / 2), WHITE, "SmoothPlastic")
        self.p("BaseTrim", (t + 0.3, 0.6, D), (-W / 2 + t / 2, 0.3, 0), WHITE, "SmoothPlastic")
        self.p("BaseTrim", (t + 0.3, 0.6, D), (W / 2 - t / 2, 0.3, 0), WHITE, "SmoothPlastic")
        # Stone wainscot band above the white board: gives the lower wall a masonry texture.
        stone = (216, 198, 172)
        self.p("StoneBand", (W, 0.55, t + 0.26), (0, 0.86, D / 2 - t / 2), stone, "Limestone")
        self.p("StoneBand", (W, 0.55, t + 0.26), (0, 0.86, -D / 2 + t / 2), stone, "Limestone")
        self.p("StoneBand", (t + 0.26, 0.55, D), (-W / 2 + t / 2, 0.86, 0), stone, "Limestone")
        self.p("StoneBand", (t + 0.26, 0.55, D), (W / 2 - t / 2, 0.86, 0), stone, "Limestone")

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
        # Painted fascia boards along the eaves (white edge against the sorbet roof).
        for sz in (-1, 1):
            self.p("EaveFascia", (roof_w + 0.2, 1.0, 0.35), (0, H + 0.3, sz * (half - 0.12)), WHITE, "SmoothPlastic")
        # Verge boards: thin white wedges at the outer roof edges that follow each slope.
        for sx in (-1, 1):
            x = sx * (roof_w / 2 - 0.45)
            self.p("VergeBoard", (0.9, rise + 0.4, half), (x, H + (rise + 0.4) / 2, -half / 2), WHITE, "SmoothPlastic",
                   cls="WedgePart")
            self.p("VergeBoard", (0.9, rise + 0.4, half), (x, H + (rise + 0.4) / 2, half / 2), WHITE, "SmoothPlastic",
                   rot=(0, 180, 0), cls="WedgePart")
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
                self.p("Doorstep", (width + 1.2, 0.35, depth), (at, 0.175, coord + offset), (190, 184, 174), "Concrete")
            else:
                self.p("Doorstep", (depth, 0.35, width + 1.2), (coord + offset, 0.175, at), (190, 184, 174), "Concrete")
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

    def pet_bed(self, x, z, facing, kind, size=3.2, color=(235, 105, 110)):
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
        part(fur, "PetBowl", (0.5, 1.2, 1.2), bowl * CF(0, 0.25, 0) * CF.deg(0, 0, 90), (90, 150, 240), "SmoothPlastic",
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
                     (225, 130, 150) if i % 2 else (140, 180, 235), "SmoothPlastic")
        else:
            part(fur, "SideTable", (1.8, 2.0, 1.8), f * CF(2.6, 1.0, 0.4), WOOD, "Wood")
            part(fur, "SideLamp", (0.9, 0.9, 0.9), f * CF(2.6, 2.5, 0.4), (255, 226, 160), "Neon", shape="Ball")
            part(fur, "Fireplace", (4.4, 7.0, 1.6), f * CF(-4.2, 3.5, 1.2), (196, 118, 96), "Brick")
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
    def counter(self, x, z, facing, length=8.0, depth=2.6, height=3.2, spots=2, body=WHITE, top=(158, 162, 170)):
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

    def sofa(self, x, z, facing, length=8.0, color=(120, 170, 230)):
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

    def bed(self, x, z, facing, color=(140, 180, 240), headboard_h=3.0):
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
        colors = [(238, 120, 118), (110, 160, 235), (118, 208, 142), (242, 198, 92), (185, 138, 235)]
        for row, y in enumerate((0.9, 2.4)):
            for i in range(6):
                self.p("Book", (0.55, 1.1, 0.2), (-1.9 + i * 0.75, y, -0.92), colors[(i + row * 2) % len(colors)],
                       "SmoothPlastic", frame=f, parent=self.furniture, collide=False)
        self.spot(f * CF(0, 3.4, 0))

    def tall_bookcase(self, x, z, facing, width=6.0):
        f = self.frame(x, z, facing)
        self.p("Bookcase", (width, 9.0, 1.6), (0, 4.5, 0), WOOD_DARK, "Wood", frame=f, parent=self.furniture)
        colors = [(235, 120, 110), (120, 165, 235), (120, 205, 140), (242, 202, 100), (190, 140, 235), (235, 160, 110)]
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
        self.p("Pot", (1.6, 1.4, 1.6), (0, 0.7, 0), (230, 136, 94), "Concrete", frame=f, parent=self.furniture)
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
            self.y("Fence", size(length, 4.6, 0.4), at(2.3), (150, 156, 172), "WoodPlanks")
            self.y("FenceTrim", size(length, 0.3, 0.6), at(4.75), (118, 124, 142), "Metal")
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
                self.y("FencePost", (0.6, 5.0, 0.6), (post[0], 2.5, post[2]), (118, 124, 142), "Metal")

    def path(self, x, z0, z1, width=4.0, color=(212, 206, 194), material="Slate"):
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

# One house design, drawn in its own units (56 x 42) and then built bigger: every house on the
# street is HOUSE_SCALE times that footprint. The plan's coordinates are what build_house() writes;
# HouseBuilder scales them, so the layout stays in one piece.
HOUSE_W, HOUSE_D, HOUSE_H = 56.0, 42.0, 12.0
HOUSE_SCALE = 1.35                    # the houses are built this much bigger than the plan
HOUSE_WALL_H = 15.0                   # ...and the rooms are this tall (12 before)
HOUSE_SPOTS = 5                       # items a house puts out at a time (bigger houses, same loot)
OUT_W, OUT_D = HOUSE_W * HOUSE_SCALE, HOUSE_D * HOUSE_SCALE
FRONT_YARD = 18.0
LOT_W, LOT_D = OUT_W + 16.0, OUT_D + FRONT_YARD
CLIFF_SETBACK = 3.0  # the cliff face sits this far behind the front of each house
SIDEWALK_EDGE = 24.0  # |z| where the pavement ends and the front yards begin
HOUSE_FRONT_Z = SIDEWALK_EDGE + FRONT_YARD
CLIFF_FACE_Z = HOUSE_FRONT_Z + CLIFF_SETBACK
FENCE_STYLES = {1: "picket", 2: "hedge", 3: "modern"}
PET_BEDS = {"Cat": 2.8, 1: 2.8, 2: 3.4, 3: 4.2}
# Beds sized to the animal that sleeps in them (guard id -> bed size).
ROOM_BOX_H = 20.0  # tall enough that anywhere on a room's floor is inside its box
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
    W, D, H = HOUSE_W, HOUSE_D, HOUSE_WALL_H
    hb = HouseBuilder(folder, info["id"], info["display"], tier, lot_cf, LOT_W, LOT_D, W, D, H, FRONT_YARD,
                      HOUSE_SCALE)
    hb.model.attr(Guard=guard["id"])
    hb.wall_color, hb.wall_material = palette["wall"], "Plaster"
    hb.spot_budget = HOUSE_SPOTS  # bigger rooms, same five items on show
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
    # The doorway in each wall of the middle rooms, and the middle of the hall by the front door.
    # A defender posted in one of the side rooms can see none of the front door from where it
    # sleeps, so those doorways are what it aims at to get out (and back in) without nosing along
    # the walls looking for a way round. They stand where the walls above have their openings.
    hb.route_node("WestFront", -4, 10)
    hb.route_node("WestRear", -4, -10)
    hb.route_node("EastFront", 4, 11)
    hb.route_node("EastRear", 4, -9)
    hb.route_node("Hall", 0, 16)
    # And the rooms themselves, so the server can tell "the other side of that wall" from "the far
    # side of the table" - and which doorway is the way out of each one. They are inset from the
    # walls they share, so standing in a doorway counts as being in the hall, which is what the
    # routes through a house are all built on.
    hb.room("Living", -xi + 0.3, 0.3, -4.6, zi - 0.3, "WestFront")
    hb.room("Kitchen", -xi + 0.3, -zi + 0.3, -4.6, -0.3, "WestRear")
    hb.room("Study", 4.6, 2.6, xi - 0.3, zi - 0.3, "EastFront")
    hb.room("Bedroom", 4.6, -zi + 0.3, xi - 0.3, 2.0, "EastRear")
    hb.room("Hall", -4.6, -zi + 0.3, 4.6, zi - 0.3)
    hb.gable_roof(9.5, 1.4, palette["roof"])
    hb.p("Chimney", (3.0, 9, 3.0), (-17, H + 5.5, -8), (186, 108, 88), "Brick")
    hb.door("x", D / 2 - t / 2, 0, 5, 9, +1, palette["door"], step=False)
    # White door frame around the front door (painted trim against the pastel wall).
    for sx in (-1, 1):
        hb.p("DoorTrim", (0.55, 9, 0.35), (sx * 2.78, 4.5, D / 2 + 0.1), WHITE, "SmoothPlastic")
    hb.p("DoorTrim", (6.2, 0.55, 0.35), (0, 9.28, D / 2 + 0.1), WHITE, "SmoothPlastic")
    # Porch (its roof sits just under the eaves, whatever the walls are built to)
    porch_h = H - 2.6
    hb.p("PorchFloor", (12, 0.35, 4.6), (0, 0.175, D / 2 + 2.3), (202, 172, 132), "WoodPlanks")
    for x in (-5.4, 5.4):
        hb.p("PorchColumn", (porch_h, 0.9, 0.9), (x, 0.35 + porch_h / 2, D / 2 + 4.1), WHITE, "SmoothPlastic",
             rot=(0, 0, 90), shape="Cylinder")
    hb.p("PorchRoof", (13.4, 0.6, 5.4), (0, 0.35 + porch_h + 0.3, D / 2 + 2.5), palette["roof"], "RoofShingles")
    porch_light = hb.p("PorchLight", (0.6, 0.9, 0.4), (3.6, 7.6, D / 2 + 0.25), (255, 222, 160), "Neon",
                       parent=hb.furniture, collide=False)
    point_light(porch_light, (255, 214, 150), 1.2, 18)

    # Loot furniture, most important first: every house stops after HOUSE_SPOTS of them (5).
    hb.tv_stand(-26.0, 10, "e")  # living room
    hb.counter(-15, -18.9, "s", length=12, spots=2)  # kitchen
    hb.pedestal(0, -17.4, "s")  # the display at the end of the hall
    hb.nightstand(12.6, -19.0, "s")  # bedroom
    hb.desk(25.9, 11, "w")  # study
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
    hb.siren((0, H - 0.6, D / 2 + 0.45))
    hb.siren((0, H - 0.5, 6))

    # Front yard (lot coordinates)
    front = LOT_D / 2 - FRONT_YARD  # lot z of the house's front wall
    hb.path(0, front + 4.6, LOT_D / 2 - 0.6, 4)
    fence_gaps = [(0, 6)]  # the garden gate
    if guard["kind"] == "Vehicle":
        fence_gaps.append((12, 13))  # the driveway the security car pulls out of
    hb.fence(FENCE_STYLES.get(tier, "picket"), fence_gaps, back_z=front - CLIFF_SETBACK)
    # The way in and out of the lot, in the order it is walked. Leaving: the gateway, in the middle
    # of the front fence where the path runs out to the street, and then the pavement outside it.
    # Coming home it is the other way round, so the walk to the gate is made along the fence and
    # the turn through the gateway happens square in front of it.
    hb.route_lot("Street", 0, LOT_D / 2 + 6)
    hb.route_lot("Gate", 0, LOT_D / 2 - 0.2)
    # And the front door itself: the marker in the middle of the doorway, so a defender coming in
    # off the path aims through the opening rather than at the wall beside it.
    hb.route_lot("Door", 0, LOT_D / 2 - FRONT_YARD - 0.3)
    # Keep the front garden uncluttered: house-name/difficulty yard labels were removed.
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

# Warm cream sandstone — the canyon glows instead of looming grey.
ROCK_COLORS = [(206, 186, 158), (218, 198, 170), (196, 176, 148), (226, 206, 180), (212, 192, 164), (188, 168, 140),
               (202, 184, 154)]


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


def build_mansion_cliff(parent: Inst, decor: Inst, lot_cf: CF):
    """The Grand Mansion backs onto the tallest cliff, which also closes off the end of the street."""
    folder = Inst("Folder", "Mansion", parent)
    cliff = CliffBuilder(folder, 4242)
    MS = HOUSE_SCALE
    house_front, house_back, half_w = 25.0 * MS, -27.0 * MS, 42.0 * MS  # the estate's plan (see build_mansion)
    face_z = house_front - CLIFF_SETBACK
    frame = lot_cf * CF(0, 0, face_z)
    back = -95.0 * MS - face_z  # the east edge of the map
    for a, b in ((-130.0 * MS, -half_w), (half_w, 130.0 * MS)):
        cliff.face(frame, a, b, (30, 44))
        cliff.fill(frame, a, b, -6, back, (34, 50), None, decor)
        cliff.rubble(frame, a, b, 0.12)
    cliff.fill(frame, -half_w, half_w, house_back - face_z, back, (36, 52), None, decor)
    # Beyond the estate walls the cliff comes forward to meet the end of the street.
    lot_front = 75.0 * MS - face_z
    for a, b in ((-130.0 * MS, -100.0 * MS), (100.0 * MS, 130.0 * MS)):
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


def build_corridor_cliffs(parent: Inst, decor: Inst, end_x: dict[int, float]):
    """The cliffs that join the yard to the houses: a canyon that curves in from the yard's mouth until it is
    as tight as the street it runs into. `end_x` is where each side's street cliffs begin (it overlaps them)."""
    folder = Inst("Folder", "Corridor", parent)
    cliff = CliffBuilder(folder, 9200)
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
    hb = HouseBuilder(folder, info["id"], info["display"], 4, lot_cf, MANSION_LOT_W, MANSION_LOT_D,
                      84, 52, 14, MANSION_FRONT_YARD, HOUSE_SCALE)
    hb.spot_budget = HOUSE_SPOTS  # the museum shows five treasures at a time, like the houses
    MS = HOUSE_SCALE  # the estate is drawn to the same plan as the houses and built just as much bigger

    def ly(name, size, pos, color, material="SmoothPlastic", rot=None, **kw):
        """A part on the mansion's grounds, in the plan's lot coordinates."""
        return hb.y(name, (size[0] * MS, size[1], size[2] * MS), (pos[0] * MS, pos[1], pos[2] * MS),
                    color, material, rot, **kw)

    hb.model.attr(Guard=info["guard"]["id"])
    wall = (244, 234, 208)
    hb.wall_color, hb.wall_material = wall, "Limestone"
    H = 14
    windows_front = [window(x, 6 if abs(x) < 30 else 5, 3.6, 10.4) for x in (-37, -27, -14, 14, 27, 37)]
    # The cliff wraps the sides and the back, so only the front has openings.
    hb.exterior(1.2, wall, "Limestone", front=[door_opening(0, 8, 11.5)] + windows_front, back=[], left=[], right=[])
    hb.floor((240, 236, 228), "Marble")
    hb.room_floor(-40.8, -14.4, 0.4, 24.8, (222, 128, 118), "Carpet")
    hb.room_floor(-40.8, -14.4, -24.8, -0.4, (152, 176, 232), "Carpet")
    hb.room_floor(14.4, 40.8, 0.4, 24.8, WOOD_LIGHT, "WoodPlanks")
    hb.room_floor(-13.6, 13.6, -24.8, -6.4, (120, 122, 128), "DiamondPlate")
    inner = (240, 234, 220)
    for x in (-14, 14):
        hb.wall_z(x, -24.8, 24.8, 0.8, H, [doorway(13, 5, 10.5), doorway(-13, 5, 10.5)], inner, "Plaster",
                  "InteriorWall")
    hb.wall_x(0, -40.8, -14.4, 0.8, H, [doorway(-28, 5, 10.5)], inner, "Plaster", "InteriorWall")
    hb.wall_x(0, 14.4, 40.8, 0.8, H, [doorway(28, 5, 10.5)], inner, "Plaster", "InteriorWall")
    hb.wall_x(-6, -13.6, 13.6, 1.2, H, [doorway(0, 6, 10)], (110, 112, 120), "DiamondPlate", "VaultWall")
    hb.gable_roof(12, 1.6, (242, 112, 88), "ClayRoofTiles")
    door_color = (186, 96, 64)
    # Masonry quoins: alternating limestone blocks stacked at each corner — the texture that makes it
    # read as a manor rather than a box.
    for sx in (-1, 1):
        for sz in (-1, 1):
            for q in range(5):
                light = (252, 244, 220) if q % 2 == 0 else (228, 218, 192)
                hb.p("Quoin", (1.7, 2.8, 1.7), (sx * 41.4, 1.4 + q * 2.8, sz * 25.4), light, "Limestone",
                     collide=False)
    hb.door("x", 25.4, -2, 4, 11.5, +1, door_color, hinge="low", name="FrontDoorLeft", step=False)
    hb.door("x", 25.4, 2, 4, 11.5, +1, door_color, hinge="high", name="FrontDoorRight", step=False)
    # Portico
    hb.p("Portico", (26, 0.4, 8.5), (0, 0.2, 30.3), (240, 234, 220), "Marble")
    for x in (-11, -4.5, 4.5, 11):
        hb.p("Column", (12.6, 1.7, 1.7), (x, 0.4 + 6.3, 33.4), WHITE, "Marble", rot=(0, 0, 90), shape="Cylinder")
    hb.p("PorticoRoof", (27, 1.0, 9.4), (0, 13.5, 30.4), WHITE, "Marble")
    hb.p("Pediment", (1.0, 5, 13.5), (-6.75, 16.5, 34.4), WHITE, "Marble", rot=(0, 90, 0), cls="WedgePart")
    hb.p("Pediment", (1.0, 5, 13.5), (6.75, 16.5, 34.4), WHITE, "Marble", rot=(0, -90, 0), cls="WedgePart")
    # Grand hall
    hb.rug(0, 9.6, 5, 29, (238, 108, 96))
    for x in (-8, 8):
        hb.pedestal(x, 14, "s")
    hb.pedestal(-7, -12, "s", color=(60, 62, 70))  # ...and the pick of the vault (the rest wait inside)
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
    hb.sofa(-20, 6, "w", length=4, color=(226, 130, 118))
    # Master bedroom
    hb.bed(-36.0, -12.5, "e", color=(255, 208, 120), headboard_h=4)
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
        hb.painting("x", -24.8, x, 7.5, +1, [((150, 190, 130), (244, 216, 178)), ((120, 150, 230), (250, 216, 120)),
                                             ((238, 140, 120), (250, 226, 170))][i])
    hb.laser((25.5, 2.4, 0), (30.5, 2.4, 0), 0.9)
    # The vault
    for x, z in ((7, -12), (-7, -20.5), (7, -20.5)):
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
            hb.guard_post(fleet_x, fleet_z, "s", info["guard"], 4, (72, 82, 118))
    hb.siren((0, 12.4, 26.6))
    hb.siren((0, H - 0.6, 18))
    hb.siren((0, H - 0.6, -12))
    # Grounds (house front wall at lot z = 25 in the plan, 25 * MS on the ground)
    ly("Driveway", (14, 0.14, 40.6), (0, 0.07, 54.7), (204, 194, 178), "Cobblestone")
    hb.fence("estate", [(0, 16 * MS)], back_z=(25 - CLIFF_SETBACK) * MS)
    # The museum grounds use the same label-free frontage as every other house.
    for sx in (-1, 1):
        ly("GatePillar", (3.6, 12, 3.6), (sx * 9.6, 6, 74.4), (222, 208, 180), "Limestone")
        lamp_part = ly("GateLamp", (1.6, 1.6, 1.6), (sx * 9.6, 12.8, 74.4), (255, 230, 170), "Neon", shape="Ball")
        point_light(lamp_part, (255, 220, 160), 1, 24)
        # Fountains on both sides of the driveway
        fx = sx * 45 * MS
        ly("FountainBasin", (1.6, 18, 18), (fx, 0.8, 52), (200, 196, 186), "Marble", rot=(0, 0, 90), shape="Cylinder")
        ly("FountainWater", (0.3, 16, 16), (fx, 1.5, 52), (70, 170, 235), "Glass", rot=(0, 0, 90), shape="Cylinder",
           transparency=0.25, collide=False, reflectance=0.2)
        ly("FountainColumn", (6, 1.6, 1.6), (fx, 3.6, 52), (220, 216, 206), "Marble", rot=(0, 0, 90), shape="Cylinder")
        ly("FountainBowl", (1.0, 6, 6), (fx, 6.8, 52), (220, 216, 206), "Marble", rot=(0, 0, 90), shape="Cylinder")
        ly("FountainSpray", (2.4, 2.4, 2.4), (fx, 8.0, 52), (150, 210, 255), "Glass", shape="Ball", transparency=0.4,
           collide=False)
        for z in (40, 50, 60, 70):
            ly("Hedge", (2.4, 3.2, 7), (sx * 10.5, 1.6, z), LEAF_DARK, "LeafyGrass")
        for z in (38, 58):
            street_lamp(hb.yard, lot_cf * CF(sx * 13 * MS, 0, z * MS) * CF.deg(0, -90 * sx, 0))
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
    wall = (238, 240, 246)
    # Floor & walls
    p("Floor", (W, 0.4, D), (0, 0.2, 0), (198, 200, 202), "Concrete")
    for a, b in ((-W / 2, -13), (13, W / 2)):
        p("FrontWall", (b - a, H, t), ((a + b) / 2, H / 2, D / 2 - t / 2), wall, "SmoothPlastic")
    p("FrontWall", (26, H - 16, t), (0, 16 + (H - 16) / 2, D / 2 - t / 2), wall, "SmoothPlastic")
    p("DoorFrame", (27.2, 1.2, t + 0.4), (0, 16.6, D / 2 - t / 2), accent, "Metal")
    for x in (-13.6, 13.6):
        p("DoorFrame", (1.2, 16, t + 0.4), (x, 8, D / 2 - t / 2), accent, "Metal")
    p("RollerDoor", (26, 2.4, 1.4), (0, 15.2, D / 2 - 0.2), (176, 180, 188), "DiamondPlate")
    p("BackWall", (W, H, t), (0, H / 2, -D / 2 + t / 2), wall, "SmoothPlastic")
    for sx in (-1, 1):
        x = sx * (W / 2 - t / 2)
        p("SideWall", (t, 14, D - 2 * t), (x, 7, 0), wall, "SmoothPlastic")
        p("SideWall", (t, 3, D - 2 * t), (x, 20.5, 0), wall, "SmoothPlastic")
        p("Window", (0.3, 5, D - 2 * t), (x, 16.5, 0), GLASS, "Glass", transparency=0.5)
    p("Roof", (W + 2, 1.2, D + 2), (0, H + 0.6, 0), (248, 249, 252), "SmoothPlastic")
    p("AccentStripe", (W + 0.4, 1.4, D + 0.4), (0, H - 0.7, 0), accent, "Metal")
    # Sheet-metal wall panels: vertical seams every few studs so the white shell reads as manufactured
    # panelling, plus accent pilasters on the corners.
    seam = (218, 220, 230)
    for x in range(-28, 29, 8):
        if abs(x) < 13:  # above the garage door only
            p("PanelSeam", (0.18, H - 16.4, 0.14), (x, 16.4 + (H - 16.4) / 2, D / 2 + 0.07), seam, "SmoothPlastic",
              collide=False, shadow=False)
        else:
            p("PanelSeam", (0.18, H - 1, 0.14), (x, (H - 1) / 2 + 0.5, D / 2 + 0.07), seam, "SmoothPlastic",
              collide=False, shadow=False)
        p("PanelSeam", (0.18, H - 1, 0.14), (x, (H - 1) / 2 + 0.5, -D / 2 - 0.07), seam, "SmoothPlastic",
          collide=False, shadow=False)
    for sx in (-1, 1):
        for z in range(-18, 19, 8):
            p("PanelSeam", (0.14, 13, 0.18), (sx * (W / 2 + 0.07), 7, z), seam, "SmoothPlastic", collide=False,
              shadow=False)
        for sz in (-1, 1):
            p("Pilaster", (1.3, H, 1.3), (sx * (W / 2 - 0.65), H / 2, sz * (D / 2 - 0.65)), accent, "Metal")
    # The roller door is ribbed sheet metal too.
    for ry in (14.3, 14.9, 15.5, 16.1):
        p("DoorRib", (26.1, 0.16, 0.12), (0, ry, D / 2 + 0.51), (150, 154, 162), "SmoothPlastic", collide=False,
          shadow=False)
    for x in (-18, 0, 18):
        lamp = p("CeilingLight", (8, 0.4, 2), (x, H - 0.4, -4), (255, 248, 230), "Neon", collide=False)
        point_light(lamp, (255, 244, 225), 1.1, 42)

    # Sign above the door (the server writes the owner's name on it)
    sign = p("OwnerSign", (34, 5, 0.6), (0, 19.2, D / 2 + 0.35), (250, 250, 252), "SmoothPlastic", parent=plot)
    surface_text(sign, "Back", "EMPTY WAREHOUSE", color=(46, 42, 62), label_name="OwnerText", stroke=None,
                 pixels_per_stud=30)
    number = p("PlotNumber", (6, 6, 0.6), (-24, 19.2, D / 2 + 0.35), accent, "SmoothPlastic", parent=plot)
    surface_text(number, "Back", str(index), color=(255, 255, 255), stroke=0.3, pixels_per_stud=30)

    # Stats board on the back wall
    board = p("StatsBoard", (18, 7, 0.4), (0, 15.5, -D / 2 + t + 0.2), (250, 250, 252), "SmoothPlastic", parent=plot)
    surface_text(board, "Back", "Waiting for a new owner...", color=(30, 140, 80), label_name="StatsText",
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
        p("ShelfFrame", (4.2, 0.3, 23.4), (rx, 6.0, -8.8), (168, 174, 186), "Metal", parent=racks)
        for level, y in ((0, 0.7), (1, 6.3)):
            for z in SLOT_ZS:
                slot_index += 1
                size = (3.6, 0.6, 4.0) if level == 0 else (3.6, 0.2, 4.2)
                slot = part(slots, f"Slot{slot_index}", size, cf * CF(rx, y, z) * CF.deg(0, 180, 0),
                            WOOD_LIGHT if level == 0 else (234, 212, 168), "WoodPlanks")
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
        p("Crate", (3.2, 3.2, 3.2), (x, 2.0, z), (216, 174, 116), "WoodPlanks", rot=(0, (i * 17) % 30, 0))

    # Outside: apron and loading dock
    part(ground, "Apron", (80, 0.2, 40), cf * CF(0, 0.1, 44), (216, 212, 200), "Concrete")
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

    p("Mat", (8, 0.06, 17), (0, 0.03, 0.4), (102, 106, 120), "Rubber", collide=False, query=False)
    p("Deck", (5.4, 0.35, 12), (0, 0.175, 0), (238, 240, 246), "SmoothPlastic")
    p("Belt", (4.3, 0.12, 10.8), (0, 0.41, 0.1), (74, 76, 86), "Rubber")
    p("MotorHood", (5.4, 0.7, 1.2), (0, 0.35, -6.6), (118, 124, 140), "Metal")
    p("RearStep", (5.4, 0.25, 1.2), (0, 0.125, 6.6), (150, 154, 164), "DiamondPlate")
    for sx in (-1, 1):
        p("AccentRail", (0.55, 0.45, 12), (sx * 2.45, 0.575, 0), TREADMILL_TRIM, "Metal")
        p("Upright", (0.35, 4.6, 0.35), (sx * 2.3, 2.65, -5.5), (200, 200, 205), "Metal")
        p("Handrail", (0.25, 0.25, 4.4), (sx * 2.3, 4.0, -3.4), (200, 200, 205), "Metal")
    console = p("Console", (5.4, 1.8, 1.0), (0, 5.4, -5.7), (250, 250, 252), "SmoothPlastic")
    surface_text(console, "Back", "WALK ON\nTO TRAIN", color=(28, 148, 200), label_name="TreadmillText",
                 stroke=None, pixels_per_stud=40)
    surface_text(console, "Front", "TREADMILL", color=(46, 42, 62), label_name="TreadmillOwnerText",
                 stroke=None, pixels_per_stud=40)
    p("AccentBar", (5.6, 0.25, 1.2), (0, 6.42, -5.7), TREADMILL_TRIM, "Neon", collide=False)

    # Script markers: the runner is held at RunPoint facing its LookVector; ESCAPE drops you at ExitPoint.
    marker(m, "RunPoint", tcf * CF(0, 3.5, -0.5), (1, 1, 1))
    marker(m, "ExitPoint", tcf * CF(-6, 3.2, 0.5), (1, 1, 1))

    # A sign on the far side so everyone knows what it is.
    for z in (-3.0, 4.0):
        p("SignPost", (0.4, 5, 0.4), (6.5, 2.5, z), WHITE, "SmoothPlastic")
    sign = p("Sign", (0.4, 4, 8), (6.5, 6.4, 0.5), (250, 250, 252), "SmoothPlastic")
    surface_text(sign, "Left", "🏃 TREADMILL\nWalk on to train speed.\nWorks while you're AFK!",
                 color=(28, 148, 200), font="Builder", weight=700, stroke=None, pixels_per_stud=30)
    return m


def billboard_text(target: Inst, text: str, *, size=(7.0, 1.4), offset=(0.0, 0.0, 0.0),
                   color=(255, 255, 255), font: str = "Fredoka", weight: int = 700,
                   stroke: float | None = 0.4, label_name: str = "Label") -> Inst:
    """A floating text tag (BillboardGui) parented to a part: NPC name tags and the like."""
    gui = Inst("BillboardGui", "NameTag", target)
    gui.set(
        Size=UD2(float(size[0]), 0, float(size[1]), 0),
        StudsOffset=V3(float(offset[0]), float(offset[1]), float(offset[2])),
        LightInfluence=Float(0),
    )
    label = Inst("TextLabel", label_name, gui)
    props = {
        "Size": UD2(1, 0, 1, 0),
        "BackgroundTransparency": Float(1),
        "BorderSizePixel": Int(0),
        "Text": text,
        "TextColor3": C3.rgb(*color),
        "TextScaled": True,
        "TextWrapped": True,
        "FontFace": FontFace(FONTS[font], weight, "Normal"),
    }
    if stroke is not None:
        props["TextStrokeTransparency"] = Float(stroke)
        props["TextStrokeColor3"] = C3.rgb(20, 20, 26)
    label.set(**props)
    return label


def market_npc(parent: Inst, name: str, cf: CF, *, accent, tag_text: str, face_emoji: str) -> Inst:
    """A blocky shopkeeper behind a counter, facing local +x (towards the hall doors).

    `cf` sits at the character's feet when standing on the hall floor slab. The ProximityPrompts
    stay on the counter parts; the character is pure set dressing.
    """
    npc = model(parent, name, cf)

    def q(n, size, rel, col, mat="SmoothPlastic", **kw):
        return part(npc, n, size, cf * CF(*rel), col, mat, **kw)

    q("Mat", (3.0, 0.14, 2.6), (0, 0.07, 0), (52, 56, 64), "Rubber")
    pants, shirt, skin = (50, 54, 70), (242, 244, 248), (238, 188, 150)
    for sz in (-1, 1):
        q("Leg", (0.85, 2.0, 0.95), (0, 1.0, sz * 0.5), pants)
        q("Arm", (0.8, 2.1, 0.8), (0, 2.95, sz * 1.45), shirt)
        q("Cuff", (0.85, 0.45, 0.85), (0, 2.0, sz * 1.45), accent)
    q("Torso", (1.15, 2.3, 2.1), (0, 3.15, 0), accent)
    q("Apron", (0.5, 1.6, 1.7), (0.4, 2.7, 0), (60, 62, 74))
    head = q("Head", (1.3, 1.3, 1.3), (0.05, 5.05, 0), skin)
    surface_text(head, "Right", face_emoji, color=(255, 255, 255), font="Fredoka", stroke=None,
                 pixels_per_stud=26)
    q("Cap", (1.45, 0.45, 1.4), (0.05, 5.9, 0), accent)
    q("CapBrim", (0.6, 0.16, 1.3), (0.9, 5.72, 0), accent)
    billboard_text(head, tag_text, size=(9.0, 1.5), offset=(0, 2.6, 0))
    return npc


def market_hall(map_folder: Inst):
    """The yard's market as ONE warehouse-like hall: two open roller doors at the front (+x, facing
    the spawn drive), behind them two counters (the upgrade shop on the left bay, the trader on the
    right) each staffed by an NPC. Built from the warehouses' parts-language: glossy white shell,
    violet corner pilasters and eave band (the title arch's brand colour), grey panel seams, white
    slab roof with a violet parapet rim, and a rooftop board. Only `ShopCounter`/`SellCounter` and
    the `Shop`/`SellPoint` model names are gameplay-load-bearing; everything else is set dressing.
    """
    hall = model(map_folder, "MarketHall", CF(YARD_CX, 0, 0))
    W, D, H = HALL_W, HALL_D, HALL_H
    CX = YARD_CX                 # -320: the hall's footprint centre on the plaza
    FRONT = CX + D / 2           # -311: the facade plane, facing the spawn drive
    BACK = CX - D / 2            # -329
    SHELL = (238, 240, 246)
    BRAND = (146, 106, 238)      # matches the title arch over the road
    INK = (46, 42, 62)
    STEEL = (138, 146, 164)
    WOOD = (224, 180, 128)
    SHOP_AC, SELL_AC = (255, 196, 54), (120, 235, 150)
    FLOOR_TOP = 0.56             # the top of FloorSlab/Apron (sits on the plaza pad)

    def p(n, size, pos, col, mat="SmoothPlastic", rot=None, **kw):
        frame = CF(*pos)
        if rot:
            frame = frame * CF.deg(*rot)
        return part(hall, n, size, frame, col, mat, **kw)

    # --- shell: floor, walls and the facade with its two roller-door openings (10 wide, 6.9 tall) ---
    p("FloorSlab", (D - 0.6, 0.3, W - 0.6), (CX, 0.41, 0), (224, 224, 230), "Concrete")
    p("BackWall", (0.7, H, W - 1.4), (BACK + 0.35, H / 2, 0), SHELL)
    for sz in (-1, 1):
        p("SideWall", (D, H, 0.7), (CX, H / 2, sz * (W / 2 - 0.35)), SHELL)
    for sz in (-1, 1):
        p("FrontWing", (0.7, H, 3.5), (FRONT - 0.35, H / 2, sz * 14.25), SHELL)
    p("FrontColumn", (0.7, H, 5.0), (FRONT - 0.35, H / 2, 0), SHELL)
    p("FrontHeader", (0.7, H - 6.9, 25.0), (FRONT - 0.35, 6.9 + (H - 6.9) / 2, 0), SHELL)

    # --- the warehouses' dressing: violet pilasters, eave band, panel seams ---
    for sx in (-1, 1):
        px = CX + sx * (D / 2 - 0.65)
        for sz in (-1, 1):
            p("Pilaster", (1.3, H, 1.3), (px, H / 2, sz * (W / 2 - 0.65)), BRAND, "Metal")
    p("AccentBand", (0.45, 0.8, W - 0.2), (BACK - 0.05, H - 0.9, 0), BRAND)
    for sz in (-1, 1):
        p("AccentBand", (D - 0.2, 0.8, 0.45), (CX, H - 0.9, sz * (W / 2 + 0.02)), BRAND)
    seam = (218, 220, 230)
    for i in range(9):
        sz = -12.8 + i * 3.2
        p("PanelSeam", (0.18, H - 2, 0.14), (BACK - 0.09, (H - 2) / 2 + 0.5, sz), seam, collide=False, shadow=False)
    for szs in (-1, 1):
        for i in range(5):
            x = BACK + 2.8 + i * 3.2
            p("PanelSeam", (0.14, H - 2, 0.18), (x, (H - 2) / 2 + 0.5, szs * (W / 2 + 0.09)), seam,
              collide=False, shadow=False)

    # --- roof: white slab, violet parapet rim, skylight + plant kit, and the rooftop board ---
    p("Roof", (D + 2.2, 1.0, W + 2.2), (CX, H + 0.5, 0), (248, 249, 252))
    for sx in (-1, 1):
        p("RoofRim", (0.4, 0.6, W + 2.6), (CX + sx * (D / 2 + 1.05), H + 0.75, 0), BRAND)
    for sz in (-1, 1):
        p("RoofRim", (D + 2.6, 0.6, 0.4), (CX, H + 0.75, sz * (W / 2 + 1.05)), BRAND)
    p("SkylightFrame", (5.2, 0.5, 10.6), (CX, H + 1.2, 0), BRAND)
    p("Skylight", (4.6, 0.5, 10.0), (CX, H + 1.35, 0), (176, 214, 232), "Glass", transparency=0.35,
      collide=False)
    p("RoofUnit", (2.4, 2.0, 2.4), (BACK + 3.0, H + 2.0, -9.5), (196, 200, 208), "Metal")
    p("RoofVent", (0.6, 1.8, 0.6), (BACK + 2.8, H + 1.9, 8.0), (216, 220, 226), "Metal",
      rot=(0, 0, 90), shape="Cylinder")
    for sz in (-1, 1):
        p("SignPost", (0.5, 2.8, 0.5), (CX, H + 2.4, sz * 5.8), (244, 246, 250))
    p("RoofSignFrame", (0.35, 3.4, 16.4), (CX + 0.15, H + 4.6, 0), BRAND)
    roof_sign = p("RoofSign", (0.3, 2.9, 15.7), (CX + 0.4, H + 4.6, 0), (250, 250, 252))
    for face in ("Right", "Left"):
        surface_text(roof_sign, face, "🛒 THE BARGAIN BARN", color=INK, font="Luckiest", stroke=None,
                     pixels_per_stud=24)

    # --- the two roller doors: guide rails, housing, raised slats, hazard sill, number plate, sign ---
    bays = ((-7.5, SHOP_AC, "01", "🛒 UPGRADE SHOP"), (7.5, SELL_AC, "02", "💰 SELL POINT"))
    for zc, accent, num, sign_text in bays:
        for sz in (-1, 1):
            p("DoorRail", (0.6, 6.9, 0.55), (FRONT - 0.3, FLOOR_TOP + 3.45, zc + sz * 4.95),
              (92, 96, 112), "Metal")
        p("DoorHood", (1.1, 1.05, 10.9), (FRONT - 0.55, FLOOR_TOP + 7.42, zc), (244, 246, 250))
        for i in range(2):
            p("DoorSlat", (0.5, 0.42, 10.4), (FRONT - 0.28, FLOOR_TOP + 6.7 + i * 0.45, zc), accent)
        p("DoorSill", (0.9, 0.1, 10.4), (FRONT + 0.45, 0.6, zc), (52, 54, 64), "DiamondPlate")
        for i in range(5):
            p("HazardStripe", (0.62, 0.12, 1.6), (FRONT + 0.45, 0.61, zc - 4.2 + i * 2.1), YELLOW,
              rot=(0, 40, 0), collide=False, query=False, shadow=False)
        outer = zc - 6.9 if zc < 0 else zc + 6.9
        plate = p("BayNumber", (0.25, 1.6, 1.6), (FRONT + 0.12, 5.9, outer), accent)
        surface_text(plate, "Right", num, color=(255, 255, 255), stroke=0.3, pixels_per_stud=20)
        p("BaySignFrame", (0.3, 3.0, 8.6), (FRONT + 0.18, FLOOR_TOP + 9.0, zc), accent)
        bd = p("BaySign", (0.3, 2.6, 8.0), (FRONT + 0.34, FLOOR_TOP + 9.0, zc), (250, 250, 252))
        surface_text(bd, "Right", sign_text, color=INK, font="Luckiest", stroke=None, pixels_per_stud=26)
        for sz in (-1, 1):
            pack = p("WallPack", (0.45, 0.4, 2.0), (FRONT + 0.24, H - 0.5, zc + sz * 5.9),
                     (255, 246, 226), "Neon")
            point_light(pack, (255, 244, 224), 0.45, 10)

    # --- walk-up apron: dock stripes + bollards at every jamb ---
    p("Apron", (7.0, 0.22, W + 2.0), (FRONT + 3.5, 0.47, 0), (206, 208, 210), "Concrete",
      collide=False)
    for zc, _, _, _ in bays:
        p("DockStripe", (0.7, 0.08, 11.2), (FRONT + 2.4, 0.6, zc), YELLOW, collide=False, query=False,
          shadow=False)
        for sz in (-1, 1):
            p("Bollard", (0.55, 1.6, 0.55), (FRONT + 1.4, FLOOR_TOP + 0.8, zc + sz * 6.1), YELLOW,
              "Metal")

    # --- interior: trusses + lights, chain hoist, clerestory glass, posters, tool boards ---
    for tx in (FRONT - 3.8, CX, BACK + 3.8):
        p("Truss", (0.7, 0.7, W - 0.6), (tx, H - 2.1, 0), (144, 150, 162), "Metal", collide=False)
        lamp = p("HallLight", (9.0, 0.3, 1.3), (tx, H - 2.65, 0), (255, 246, 226), "Neon",
                 collide=False)
        point_light(lamp, (255, 244, 224), 0.55, 20, True)
    p("HoistChain", (0.16, 2.4, 0.16), (CX, H - 3.6, 0), (70, 74, 84), "Metal", collide=False)
    p("HoistHook", (0.4, 0.7, 0.35), (CX, H - 5.0, 0), (70, 74, 84), "Metal", collide=False)
    for sz in (-1, 1):
        for i in range(4):
            p("Clerestory", (3.0, 1.1, 0.2), (BACK + 3.2 + i * 4.1, 8.2, sz * (W / 2 - 0.45)),
              (176, 214, 232), "Glass", transparency=0.35, collide=False)
    posters = (
        (-1, BACK + 5.5, "⏰ OPEN 24 / 7", SHOP_AC),
        (-1, BACK + 9.5, "📦 NEW STOCK DAILY", BRAND),
        (1, BACK + 5.5, "🙂 CCTV IN USE", SELL_AC),
        (1, BACK + 9.5, "📋 NO REFUNDS", STEEL),
    )
    for side, x, text, col in posters:
        z = side * (W / 2 - 0.55)
        p("PosterFrame", (2.9, 1.8, 0.18), (x, 4.6, z), col)
        bd = p("Poster", (2.5, 1.4, 0.22), (x, 4.6, z), (250, 250, 250), collide=False)
        surface_text(bd, "Back" if side < 0 else "Front", text, color=INK, pixels_per_stud=22,
                     stroke=None)
    # wall-mounted pegboards with chunky toys of real tools
    for side in (-1, 1):
        z = side * (W / 2 - 0.5)
        p("ToolBoard", (7.0, 3.6, 0.25), (CX - 1.5, 3.4, z), (150, 110, 64), "WoodPlanks")
        p("ToolBoardCap", (7.4, 0.4, 0.4), (CX - 1.5, 5.3, z), BRAND)
        base_x = CX - 1.5
        zf = side * (W / 2 - 0.9)   # tool faces sit proud of the pegboard
        rows = ((base_x - 2.45, 3.0), (base_x - 1.15, 4.3), (base_x + 0.15, 3.0),
                (base_x + 1.45, 4.3), (base_x + 2.55, 3.0))
        for i, (tx, ty) in enumerate(rows):
            if i == 0:   # hammer
                p("Tool", (0.16, 1.15, 0.14), (tx, ty - 0.2, zf), (118, 86, 52))
                p("ToolHead", (0.82, 0.42, 0.3), (tx, ty + 0.5, zf - 0.02 * side), STEEL, "Metal")
            elif i == 1:  # wrench
                p("Tool", (0.24, 1.0, 0.13), (tx, ty - 0.15, zf), STEEL, "Metal")
                p("ToolHead", (0.16, 0.56, 0.5), (tx, ty + 0.55, zf - 0.02 * side), STEEL, "Metal",
                  rot=(0, 0, 90), shape="Cylinder")
            elif i == 2:  # hand saw
                p("ToolHead", (1.7, 0.5, 0.1), (tx, ty + 0.2, zf), (214, 218, 226), "Metal")
                p("Tool", (0.42, 0.55, 0.3), (tx - 1.05, ty + 0.2, zf - 0.02 * side), (226, 96, 84))
            elif i == 3:  # mallet
                p("Tool", (0.14, 1.0, 0.13), (tx, ty - 0.2, zf), (118, 86, 52))
                p("ToolHead", (0.66, 0.42, 0.26), (tx, ty + 0.45, zf - 0.02 * side), WOOD, "Wood")
            else:          # screwdriver
                p("Tool", (0.22, 0.5, 0.24), (tx, ty - 0.45, zf), SHOP_AC)
                p("ToolHead", (0.14, 0.9, 0.12), (tx, ty + 0.35, zf - 0.02 * side), STEEL, "Metal")

    # --- back wall utilities: staff door, drainpipes, ceiling vent trims ---
    p("StaffDoorFrame", (0.24, 4.1, 2.5), (BACK - 0.1, 2.62, -5.0), (90, 94, 110), "Metal")
    p("StaffDoor", (0.26, 3.7, 2.0), (BACK - 0.22, 2.42, -5.0), (156, 118, 78), "WoodPlanks")
    bd = p("StaffOnly", (0.3, 0.9, 1.7), (BACK - 0.3, 3.3, -5.0), (232, 216, 88), collide=False)
    surface_text(bd, "Left", "STAFF\nONLY", color=INK, pixels_per_stud=18, stroke=None)
    for sz in (-1, 1):
        p("DrainPipe", (0.5, H - 0.4, 0.5), (BACK - 0.55, (H - 0.4) / 2, sz * 14.4), (120, 126, 138),
          "Metal", rot=(0, 0, 90), shape="Cylinder")

    # --- the two sales bays: counters + staffing + props, grouped under the gameplay models ---
    shop = model(map_folder, "Shop", CF(YARD_CX, 0, 0))
    sell = model(map_folder, "SellPoint", CF(YARD_CX, 0, 0))
    _hall_bay(shop, hall, -7.5, SHOP_AC, "ShopCounter", "🛒 UPGRADES", "Garry", "🛒 GARRY — UPGRADES",
              "🙂", kind="shop")
    _hall_bay(sell, hall, 7.5, SELL_AC, "SellCounter", "💰 CASH OUT", "Penny", "💰 PENNY — WE BUY LOOT",
              "🤑", kind="sell")
    return hall


def _hall_bay(bay: Inst, hall: Inst, zc: float, accent, counter_name: str, hang_text: str,
              npc_name: str, npc_tag: str, npc_face: str, *, kind: str):
    """One counter bay inside the market hall. Counter parts live in the gameplay model (`bay`);
    the hanging wayfinding board goes with the hall. Everything faces the doors (+x)."""
    CX = YARD_CX
    FRONT, BACK = CX + HALL_D / 2, CX - HALL_D / 2
    CONCRETE = (198, 200, 202)
    INK = (46, 42, 62)

    def q(n, size, pos, col, mat="SmoothPlastic", rot=None, **kw):
        frame = CF(*pos)
        if rot:
            frame = frame * CF.deg(*rot)
        return part(bay, n, size, frame, col, mat, **kw)

    def h(n, size, pos, col, rot=None, **kw):  # hall-owned parts
        frame = CF(*pos)
        if rot:
            frame = frame * CF.deg(*rot)
        return part(hall, n, size, frame, col, **kw)

    # hanging wayfinding board under the door-side truss
    bd = h("HangSign", (0.22, 1.5, 7.4), (FRONT - 4.2, 7.55, zc), accent)
    for face in ("Right", "Left"):
        surface_text(bd, face, hang_text, color=(255, 255, 255), font="Luckiest", stroke=0.25,
                     pixels_per_stud=24)

    # the counter the prompt anchors to (name kept), with its accent face and marble top
    q(counter_name, (2.6, 3.2, 10.4), (FRONT - 3.0, 2.16, zc), (250, 250, 252))
    q("CounterFace", (0.15, 2.2, 9.2), (FRONT - 1.65, 2.1, zc), accent)
    q("CounterTrimV", (0.12, 2.2, 0.25), (FRONT - 1.6, 2.1, zc - 4.7), INK, collide=False)
    q("CounterTrimV", (0.12, 2.2, 0.25), (FRONT - 1.6, 2.1, zc + 4.7), INK, collide=False)
    q("CounterTop", (3.2, 0.3, 11.0), (FRONT - 3.0, 3.9, zc), (250, 250, 252), "Marble")
    q("CounterSkirt", (2.7, 0.75, 10.4), (FRONT - 3.0, 0.94, zc), CONCRETE)
    market_npc(bay, npc_name, CF(FRONT - 5.6, 0.56, zc), accent=accent, tag_text=npc_tag,
               face_emoji=npc_face)

    # the back-wall shelf this bay shares cladding with
    for sy in (3.9, 6.0):
        q("Shelf", (1.8, 0.3, 11.2), (BACK + 1.25, sy, zc), (224, 180, 128), "WoodPlanks")

    if kind == "shop":
        # one crate + display ball per upgrade tier, then tyres, oil cans and a toolbox
        for i, (color, name) in enumerate((((245, 130, 115), "BAG"), ((120, 175, 238), "SPEED"),
                                           ((125, 210, 130), "STASH"), ((246, 196, 85), "LUCKY"))):
            cz = zc - 3.9 + i * 2.6
            q("Crate", (2.2, 2.0, 2.0), (BACK + 3.1, 1.56, cz), (216, 174, 116), "WoodPlanks")
            q("Goods", (1.6, 1.6, 1.6), (BACK + 3.1, 3.4, cz), color, shape="Ball", collide=False)
            tag = q("CrateTag", (0.16, 0.7, 1.5), (BACK + 4.25, 1.9, cz), (250, 250, 250), collide=False)
            surface_text(tag, "Right", name, color=INK, pixels_per_stud=18, stroke=None)
        for i in range(4):
            q("Tyre", (2.2, 0.85, 2.2), (BACK + 4.6, 0.98 + i * 0.86, zc - 6.3), (38, 40, 48),
              "Rubber", rot=(0, 0, 90), shape="Cylinder")
        for i, col in enumerate(((226, 96, 84), (90, 140, 220), (240, 190, 60))):
            q("OilCan", (1.1, 0.7, 0.7), (BACK + 1.25, 4.7, zc - 3.0 + i * 1.3), col,
              rot=(0, 0, 90), shape="Cylinder")
        q("Toolbox", (1.7, 0.95, 0.95), (FRONT - 3.0, 4.55, zc - 3.4), (220, 68, 60))
        q("ToolboxGrip", (0.14, 0.14, 0.8), (FRONT - 3.0, 5.12, zc - 3.4), (140, 40, 36))
        # a leaning ladder in the shop corner
        q("LadderRail", (0.25, 5.6, 0.25), (BACK + 2.6, 2.9, zc - 6.2), (196, 160, 96), "Wood",
          rot=(0, 0, -14))
        for i in range(5):
            q("LadderRung", (0.55, 0.16, 1.1), (BACK + 1.95 + i * 0.85, 1.2 + i * 0.85, zc - 6.2),
              (196, 160, 96), "Wood")
    else:
        # the trader's scales, cash box, money bags and ledger
        q("ScaleBase", (0.15, 1.4, 1.4), (BACK + 3.4, 0.66, zc + 5.2), (196, 158, 62), "Metal",
          rot=(0, 0, 90), shape="Cylinder")
        q("ScalePost", (3.1, 0.32, 0.32), (BACK + 3.4, 2.28, zc + 5.2), (196, 158, 62), "Metal",
          rot=(0, 0, 90), shape="Cylinder")
        q("ScaleBeam", (0.22, 0.22, 3.4), (BACK + 3.4, 3.9, zc + 5.2), (222, 186, 88), "Metal")
        for sz in (-1, 1):
            q("ScaleChain", (0.09, 0.9, 0.09), (BACK + 3.4, 3.38, zc + 5.2 + sz * 1.5),
              (170, 140, 70), "Metal", collide=False)
            q("ScalePan", (0.18, 1.5, 1.5), (BACK + 3.4, 2.86, zc + 5.2 + sz * 1.5), (204, 170, 74),
              "Metal", rot=(0, 0, 90), shape="Cylinder")
        q("CashBox", (1.8, 1.0, 1.3), (FRONT - 3.0, 4.6, zc + 3.6), (138, 148, 166), "Metal")
        q("CashBoxLid", (1.8, 0.25, 1.3), (FRONT - 3.85, 5.35, zc + 3.6), (160, 170, 188), "Metal")
        q("Banknotes", (1.4, 0.7, 1.0), (FRONT - 3.0, 5.15, zc + 3.6), (120, 190, 120), "Fabric",
          collide=False)
        for i, (dx, dz, sy) in enumerate(((0, 0, 1.6), (-1.3, 0.85, 1.35), (0.9, 1.0, 1.15))):
            q("MoneyBag", (sy, sy, sy), (BACK + 5.6 + dx, 0.56 + sy / 2, zc + 6.0 + dz), (214, 178, 112),
              "Fabric", shape="Ball")
        q("MoneyBagKnot", (0.45, 0.45, 0.45), (BACK + 5.6, 2.4, zc + 6.0), (128, 96, 50), "Fabric",
          shape="Ball", collide=False)
        q("Ledger", (1.7, 0.16, 2.2), (FRONT - 2.6, 4.14, zc - 2.6), (232, 226, 210))
        q("LedgerPen", (0.15, 0.15, 1.6), (FRONT - 2.2, 4.24, zc - 2.4), (40, 42, 52), "Metal",
          rot=(0, -20, 0), shape="Cylinder", collide=False)
        bd = q("BuySign", (0.3, 2.0, 8.5), (BACK + 0.5, 3.4, zc), (40, 158, 84), "SmoothPlastic")
        surface_text(bd, "Right", "WE BUY LOOT", color=(255, 255, 255), weight=700, stroke=0.4,
                     pixels_per_stud=40)
        # a pallet of loot ready for the back
        q("Pallet", (2.6, 0.35, 2.6), (FRONT - 6.6, 0.78, zc + 6.4), (196, 160, 96), "WoodPlanks")
        for i, (dx, dz, sy) in enumerate(((0, 0, 1.6), (0.8, -0.7, 1.25), (-0.8, -0.6, 1.1))):
            q("LootBox", (sy, sy, sy), (FRONT - 6.6 + dx, 0.95 + sy / 2, zc + 6.4 + dz), (216, 174, 116),
              "WoodPlanks")


# ---------------------------------------------------------------------------
# The yard: the spawn area. Six garages in a U around a parking lot, the two
# the market hall in the middle, cliffs on every closed side.
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
HALL_W, HALL_D, HALL_H = 32.0, 18.0, 11.0

# PlotIndex order: two garages on the north side, two on the west side, two on the south side.
YARD_PLOTS = (
    (YARD_CX - GARAGE_HALF, -(YARD_HALF_D + GARAGE_FRONT), 0),
    (YARD_CX + GARAGE_HALF, -(YARD_HALF_D + GARAGE_FRONT), 0),
    (YARD_ROW_X, -GARAGE_HALF, 90),
    (YARD_ROW_X, +GARAGE_HALF, 90),
    (YARD_CX + GARAGE_HALF, +(YARD_HALF_D + GARAGE_FRONT), 180),
    (YARD_CX - GARAGE_HALF, +(YARD_HALF_D + GARAGE_FRONT), 180),
)


def build_yard(map_folder: Inst, ground: Inst, decor: Inst):
    """The spawn area: the paved lot and its markings, the market hall and the yard's signage."""
    yard = model(map_folder, "Hub", CF(YARD_CX, 0, 0))

    # The paved site. Every garage keeps its own concrete apron and dock markings; one big asphalt slab
    # underneath fills the lot between them and the cliffs.
    part(ground, "LotPad", (YARD_MOUTH_X - YARD_FACE_X + 8.0, 0.2, YARD_FACE_Z * 2 + 8.0),
         CF((YARD_FACE_X + YARD_MOUTH_X) / 2 - 4.0, 0.0, 0), (150, 152, 160), "Asphalt")

    # Parking bays on both sides of the middle island
    for side in (-1, 1):
        for i in range(9):
            part(decor, "BayLine", (0.6, 0.06, 18.0), CF(YARD_CX - 56 + i * 14, 0.21, side * 29), WHITE,
                 collide=False, query=False, shadow=False)

    # The market hall in the middle of the lot: one warehouse-like building with two open roller
    # doors facing the spawn drive, two staffed counters behind them and the prompt parts the
    # Economy/Market servers look up.
    market_hall(map_folder)

    # The plaza pad under the kiosks: a cream disc tiled with a smaller inner disc and ringed with a
    # dotted candy pattern, marking the market as the heart of the yard.
    ring = CF(YARD_CX, 0, 0) * CF.deg(0, 0, 90)
    part(decor, "PlazaPad", (0.16, 46, 46), ring * CF(0.28, 0, 0), (236, 230, 216), "SmoothPlastic",
         shape="Cylinder", collide=False, shadow=False)
    part(decor, "PlazaCore", (0.16, 38, 38), ring * CF(0.30, 0, 0), (248, 244, 234), "SmoothPlastic",
         shape="Cylinder", collide=False, shadow=False)
    for i in range(20):
        angle = math.radians(i * 18)
        part(decor, "PlazaDot", (1.1, 0.06, 1.1), CF(YARD_CX + math.sin(angle) * 20, 0.34, math.cos(angle) * 20),
             (255, 196, 54) if i % 2 == 0 else (138, 232, 162), collide=False, query=False, shadow=False)

    # Spawn: in the drive lane at the mouth of the yard, looking at the stalls.
    spawn = Inst("SpawnLocation", "HubSpawn", yard)
    spawn.set(**{
        "size": _v3((10, 0.5, 10)), "CFrame": CF(YARD_CX + 70, 0.45, 0) * CF.deg(0, 90, 0),
        "Color3uint8": C3u8(255, 196, 54), "Material": Token(MATERIALS["SmoothPlastic"]), "Anchored": True,
        "TopSurface": Token(0), "BottomSurface": Token(0), "Neutral": True, "Duration": Int(0),
        "AllowTeamChangeOnTouch": False,
    })

    # How to play board, in the open corner by the way in, facing the arriving players.
    board = part(yard, "HowToPlay", (1, 15, 26), CF(YARD_MOUTH_X - 3, 8.6, -52), (250, 248, 242), "SmoothPlastic")
    for z in (-61, -43):
        part(yard, "BoardPost", (0.8, 3.4, 0.8), CF(YARD_MOUTH_X - 3, 1.7, z), (216, 180, 120), "WoodPlanks")
    howto = ('<font color="#D89000">HOW TO PLAY</font>\n'
             '1. Run down the street to a house\n'
             '2. Hold E to pick the lock, then steal loot\n'
             '3. Stealing trips the alarm! They chase you back to the yard\n'
             '4. Sprint home with the loot — inside a house everyone moves at the same speed\n'
             '5. Drop it on your warehouse\'s green DEPOSIT pad\n'
             '6. Stored loot earns 💰 every second!\n'
             '7. Buy upgrades at the market stall, and run on the treadmill outside your warehouse')
    surface_text(board, "Right", howto, color=(46, 42, 62), font="Builder", weight=700, rich=True, stroke=None,
                 pixels_per_stud=34)

    # The game's title arch, over the road where it leaves the yard.
    gate = YARD_MOUTH_X + 8.0
    arch = model(yard, "TitleArch", CF(gate, 0, 0))
    for z in (-21.5, 21.5):
        part(arch, "ArchPillar", (3.5, 26, 3.5), CF(gate, 13, z), (172, 134, 232), "Brick")
        part(arch, "ArchLight", (3.7, 1, 3.7), CF(gate, 24, z), (255, 196, 54), "Neon", collide=False)
    beam = part(arch, "ArchBeam", (3.5, 7, 47), CF(gate, 29.5, 0), (146, 106, 238), "SmoothPlastic")
    for face in ("Right", "Left"):
        surface_text(beam, face, "🦝 STEAL AN ITEM 🦝", color=(255, 210, 60), font="Luckiest", stroke=0.2,
                     pixels_per_stud=30)

    # Lamps and planters around the lot
    for x in (YARD_CX - 65, YARD_CX + 45):
        for z in (-50.0, 50.0):
            street_lamp(decor, CF(x, 0.3, z))
    for sx in (-1, 1):  # a planter at each corner of the market hall, except the shrine's corner
        for sz in (-1, 1):
            if (sx, sz) == (1, -1):
                continue  # the rebirth shrine stands here instead
            x, z = YARD_CX + sx * (HALL_D / 2 + 2.6), sz * (HALL_W / 2 + 2.4)
            part(decor, "Planter", (3.6, 2.0, 3.6), CF(x, 1.0, z), (196, 152, 100), "WoodPlanks")
            bush(decor, CF(x, 2.0, z), 3.0, LEAF)  # bush() grows its leaves upward from the given base

    # The rebirth shrine, at the hall's front corner on the walk from spawn to the doors: a violet
    # plinth crowned with a glowing orb. The "RebirthShrine" part is what the server's Rebirth
    # module searches for (the prompt, "OpenRebirthPrompt", only opens the window).
    shrine_x, shrine_z = YARD_CX + HALL_D / 2 + 2.6, -(HALL_W / 2 + 2.4)
    shrine = model(map_folder, "Shrine", CF(shrine_x, 0, shrine_z))
    shrine_brand = (146, 106, 238)      # the title-arch violet
    part(shrine, "Base", (4.0, 0.5, 4.0), CF(shrine_x, 0.61, shrine_z), (250, 248, 242), "Marble")
    part(shrine, "Plinth", (2.6, 1.2, 2.6), CF(shrine_x, 1.46, shrine_z), shrine_brand, "SmoothPlastic")
    part(shrine, "RebirthShrine", (1.5, 2.0, 1.5), CF(shrine_x, 3.06, shrine_z),
                  (172, 134, 232), "SmoothPlastic")
    part(shrine, "Halo", (2.6, 0.14, 2.6), CF(shrine_x - 0.07, 4.6, shrine_z) * CF.deg(0, 0, 90),
         (186, 140, 255), "Neon", shape="Cylinder", collide=False, shadow=False)
    orb = part(shrine, "Orb", (1.4, 1.4, 1.4), CF(shrine_x, 5.3, shrine_z), (190, 146, 255), "Neon",
               shape="Ball", collide=False)
    point_light(orb, (204, 172, 255), 0.5, 10, shadows=True)
    # The sign hung on the walk side between two posts, facing the spawn drive (+x reads as
    # the "Right" face): low enough that the column, halo and orb rise above it.
    for dz in (-2.9, 2.9):
        part(shrine, "SignPost", (0.6, 3.5, 0.6), CF(shrine_x + 2.3, 2.1, shrine_z + dz),
             (124, 94, 150), "Wood")
    part(shrine, "SignFrame", (0.34, 2.6, 6.4), CF(shrine_x + 2.3, 2.5, shrine_z),
         shrine_brand, "Wood")
    sign = part(shrine, "SignBoard", (0.3, 2.3, 6.1), CF(shrine_x + 2.45, 2.5, shrine_z),
                (250, 248, 242), "SmoothPlastic")
    surface_text(sign, "Right",
                 '<font size="46">\U0001F501 REBIRTH</font>\n'
                 '<font size="20" color="#926AEA">SPEND SPEED \u2022 GAIN POWER</font>',
                 color=(46, 42, 62), font="Luckiest", weight=400, rich=True, stroke=None,
                 pixels_per_stud=30)
    return yard


# ---------------------------------------------------------------------------
# Roads, decor, boundaries
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# City geography
#
# The old town was one straight street about 1,200 studs long, yard to museum.
# That made for a very short chase home, so the museum now stands TEN times as
# far from the warehouses, and a city fills the space between: a main street,
# two avenues on each side of it and cross streets joining them up. The named
# houses from the guide stand along the main street on a progression curve now -
# the first ones a short walk from the garages so a new player is robbing within
# footsteps, the gaps growing the deeper the city gets (the museum last, at the
# very end) - and numbered city houses fill the grid, each at the difficulty
# level its distance earns it.
# ---------------------------------------------------------------------------
ORIGINAL_MANSION_X = 885.25                        # where the museum stood on the old short street
CITY_DIST = (ORIGINAL_MANSION_X - YARD_CX) * 10.0  # warehouses -> museum, as the crow flies (x10)
LEVELS = 11                # the difficulty guide: House1..House10 + the museum = 11 levels
LEVEL_SLACK = 0.03         # a house's trip fraction may be this far off its level's position
MANSION_X = YARD_CX + CITY_DIST                     # the museum is the last stop, straight east
ROAD_X0, ROAD_X1 = -252.0, MANSION_X - (150.0 * HOUSE_SCALE) / 2   # asphalt to the museum's gate
WALK_X0 = -204.0                  # the pavements start where the parking lot ends
CROSSWALK_X = -190.0              # where the yard's drive lane empties onto the street
MANSION_LOT_W, MANSION_LOT_D = 200.0 * HOUSE_SCALE, 150.0 * HOUSE_SCALE
MANSION_FRONT_YARD = 50.0 * HOUSE_SCALE
MAP_X0, MAP_X1, MAP_Z = -580.0, MANSION_X + 95.0 * HOUSE_SCALE, 780.0

# The grid: avenues run parallel to the main street on each side; cross streets
# join them together and carry most of the new houses. The city opens right
# where the canyon corridor ends, so the road out of the yard runs straight in.
AVENUE_ZS = (-655.0, -330.0, 330.0, 655.0)
AVENUE_X0 = 110.0                         # the avenues (and the city) begin at the canyon's mouth
AVENUE_X1 = ROAD_X1 - 200.0               # ...and stop where the museum's hill takes over
CITY_DEPTH = 700.0                        # cross streets run from z = -CITY_DEPTH to +CITY_DEPTH
JUNCTION_HALF = 34.0                      # half-width kept clear at a cross-street mouth
CITY_BOUNDARY_Z = 745.0                   # the cliffs closing off the far ends of the cross streets
CITY_SEED = 20261017


# Where the guide's eleven named houses stand, west to east, the museum pinned at the far end:
# the walk from the yard to Maple Cottage is about as long as it was on the old street, and each
# next mark stands a bit further than the last, so every tier is earned one pair of legs at a time.
GUIDE_XS = (160.0, 830.0, 1610.0, 2560.0, 3740.0, 5140.0, 6740.0, 8540.0, 10140.0, 11240.0)
assert len(GUIDE_XS) == LEVELS - 1


def house_x(i: int) -> float:
    """The x of the i-th named house (the museum stays at the far end of the trip)."""
    if i == LEVELS:
        return MANSION_X
    return GUIDE_XS[i - 1]


def level_at(x: float, z: float) -> int | None:
    """The difficulty level a position earns: each named house on the guide marks its level's
    distance from the yard, and a new house qualifies for the nearest of those marks only when
    it lands within the 3%-of-the-trip slack the guide allows."""
    d = math.hypot(x - YARD_CX, z)
    best, best_off = None, LEVEL_SLACK * CITY_DIST
    for i in range(1, LEVELS):
        off = abs(d - (house_x(i) - YARD_CX))
        if off <= best_off:
            best, best_off = i, off
    return best


def road_sign(parent: Inst, x: float, z: float, text: str, facing_yaw: float):
    m = model(parent, "RoadSign", CF(x, 0, z))
    part(m, "Post", (0.5, 9, 0.5), CF(x, 4.5, z), WHITE, "SmoothPlastic")
    board = part(m, "Board", (10, 3, 0.4), CF(x, 8, z) * CF.deg(0, facing_yaw, 0), (42, 152, 78), "SmoothPlastic")
    surface_text(board, "Front", text, color=(255, 255, 255), stroke=None, pixels_per_stud=30)
    surface_text(board, "Back", text, color=(255, 255, 255), stroke=None, pixels_per_stud=30)


def build_boundary(map_folder: Inst, decor: Inst):
    walls = Inst("Folder", "Boundary", map_folder)
    w = MAP_X1 - MAP_X0
    mid = (MAP_X0 + MAP_X1) / 2
    for z in (-MAP_Z, MAP_Z):
        # tile it too: Roblox clamps anything past 2,048 studs and would leave the fence open
        x = MAP_X0
        while x < MAP_X1:
            nxt = min(x + 2048.0, MAP_X1)
            part(walls, "InvisibleWall", (nxt - x, 120, 2), CF((x + nxt) / 2, 60, z),
                 (255, 255, 255), transparency=1, shadow=False)
            x = nxt
    for x in (MAP_X0, MAP_X1):
        part(walls, "InvisibleWall", (2, 120, MAP_Z * 2), CF(x, 60, 0), (255, 255, 255), transparency=1, shadow=False)
    # Tree lines along the north and south edges
    x = MAP_X0 + 15
    i = 0
    while x < MAP_X1 - 10:
        for z in (-MAP_Z + 10, MAP_Z - 10):
            tree(decor, CF(x, 0, z + (i % 3 - 1) * 3), 1.2 + (i % 4) * 0.1, "pine" if i % 2 else "round")
        x += 84
        i += 1


# ---------------------------------------------------------------------------
# The city: filling the ten-times-longer trip to the museum
#
# The museum now stands ten times as far from the warehouses as it used to,
# so a city fills the space between: avenues running parallel to the main
# street, cross streets joining them at irregular intervals, and about forty
# numbered houses in three shapes (cottages, ranch houses and two-storey town
# houses). Every city house is placed so its straight-line distance from the
# warehouses sits within 3% of one of the guide's eleven difficulty levels,
# and it borrows that level's guard and loot table. The whole street network
# is written onto the Map as a "Lanes" attribute so the defenders can chase
# through the grid (see src/server/Houses.luau).
# ---------------------------------------------------------------------------

CITY_KIND_PLANS = {"cottage": (48.0, 36.0), "ranch": (64.0, 38.0), "town": (44.0, 34.0)}


def city_lot(kind: str) -> tuple[float, float]:
    """A city lot stands snugger than a canyon lot."""
    w, d = CITY_KIND_PLANS[kind]
    return w * HOUSE_SCALE + 14.0, d * HOUSE_SCALE + FRONT_YARD


# Which shape a house of this level takes. Harder streets get the taller,
# better-stocked houses - the view up the street tells you how deep you are.
def city_kind(level: int, rng: random.Random) -> str:
    if level <= 2:
        return "cottage"
    if level <= 4:
        return rng.choice(("cottage", "ranch", "ranch"))
    if level <= 6:
        return "ranch"
    if level <= 8:
        return rng.choice(("ranch", "town", "town"))
    return "town"


CITY_WALLS = [(244, 230, 200), (236, 214, 188), (214, 228, 240), (230, 240, 214), (240, 222, 228),
              (226, 222, 240), (240, 236, 220), (210, 226, 226), (236, 226, 206), (222, 210, 196),
              (200, 214, 230), (232, 216, 202), (246, 232, 214), (216, 234, 222)]
CITY_ROOFS = [(176, 100, 88), (110, 130, 158), (136, 104, 156), (150, 112, 86), (98, 120, 138),
              (160, 100, 100), (112, 138, 116), (166, 128, 96), (188, 122, 108)]
CITY_DOORS = [(150, 80, 60), (90, 120, 170), (160, 130, 60), (100, 150, 120), (170, 100, 120),
              (120, 90, 150)]


def city_palette(rng: random.Random, level: int) -> dict:
    wall = rng.choice(CITY_WALLS)
    roof = rng.choice(CITY_ROOFS)
    door = rng.choice(CITY_DOORS)
    shade = lambda c, f: tuple(min(255, max(0, int(v * f))) for v in c)
    return {"wall": wall, "roof": roof, "door": door,
            "carpet": shade(wall, 0.92), "sofa": rng.choice(CITY_ROOFS), "rug": shade(roof, 1.15),
            "bed": shade(rng.choice(CITY_DOORS), 1.15), "bush": LEAF if rng.random() < 0.5 else LEAF_DARK,
            "accent": rng.choice((WOOD, WOOD_DARK, (176, 122, 82))), "pet": shade(door, 1.3)}


def plan_city(canonical_xs: list[float], canonical: list[dict]) -> dict:
    """Works out the whole city once, deterministically: where the cross streets meet the main
    street, which numbered houses stand where (at what level), and the street network the
    defenders chase through."""
    rng = random.Random(CITY_SEED)
    street_names = ["Juniper", "Alder", "Bramble", "Hazel", "Fern", "Wren", "Sorrel", "Marigold",
                    "Copper", "Jasper", "Holly", "Laurel", "Ashby", "Primrose", "Tansy", "Birchwood"]
    rng.shuffle(street_names)

    # -- junctions: one in each level's band, biased to just short of the band's centre so the
    # houses up the street straddle the level's official position; a few extras split the big
    # blocks up so the grid reads as a city rather than a ladder.
    junctions: list[dict] = []

    def junction_ok(x: float) -> bool:
        if not (AVENUE_X0 + 80 <= x <= AVENUE_X1 - 140):
            return False
        if any(abs(x - cx) < LOT_W / 2 + JUNCTION_HALF + 10 for cx in canonical_xs):
            return False
        return all(abs(x - j["x"]) >= 260 for j in junctions)

    for level in range(1, LEVELS - 1):
        anchor = house_x(level)
        half = LEVEL_SLACK * CITY_DIST * 0.9
        lo = max(anchor - half + 40, AVENUE_X0 + 80)
        hi = min(anchor + half - 40, AVENUE_X1 - 140)
        pick = None
        for _ in range(100):
            cand = lo + (hi - lo) * rng.random() ** 1.6  # nudge west: uphill houses fill the band
            if junction_ok(cand):
                pick = cand
                break
        if pick is None:
            cand = lo
            while cand <= hi and pick is None:
                if junction_ok(cand):
                    pick = cand
                cand += 32
        if pick is not None:
            junctions.append({"x": pick})
    for level in (3, 5, 7):  # extras
        anchor = house_x(level)
        for _ in range(60):
            cand = anchor + rng.uniform(-0.5, 0.5) * LEVEL_SLACK * CITY_DIST * 2
            if junction_ok(cand):
                junctions.append({"x": cand})
                break
    junctions.sort(key=lambda j: j["x"])
    for j, name in zip(junctions, street_names):
        j["name"] = name

    # -- the houses, level by level (a house's own position decides its level, within 3%)
    city_houses: list[dict] = []
    budget = 44

    def add_house(x: float, z: float, yaw: float, kind: str, street: str):
        level = level_at(x, z)
        if level is None or len(city_houses) >= budget:
            return False
        guard = canonical[level - 1]["guard"]
        number = int(abs(x) * 3 + abs(z) * 7) % 90 + 4
        city_houses.append({
            "id": f"City{len(city_houses) + 1}", "display": f"{number} {street}", "level": level,
            "tier": canonical[level - 1]["tier"], "guard": guard, "count": canonical[level - 1]["count"],
            "kind": kind, "x": x, "z": z, "yaw": yaw, "palette": city_palette(rng, level)})
        return True

    # Cross-street lots: slots up either side of the main street, on both sides of each cross
    # street, clear of the avenue carriageways and of each other.
    slot_zs = (96.0, 202.0, 308.0, 416.0, 522.0, 628.0)
    for j in junctions:
        jx = j["x"]
        street = j["name"] + " St"
        cands = [(half, side, sz) for half in (-1, 1) for side in (-1, 1) for sz in slot_zs]
        rng.shuffle(cands)
        taken = rng.randint(2, 4)
        placed: list[tuple[int, float, float]] = []  # (side, z, lot_w)
        for half, side, sz in cands:
            if len(placed) >= taken or len(city_houses) >= budget:
                break
            z = half * sz
            rough = level_at(jx, z)
            if rough is None:
                continue
            kind = city_kind(rough, rng)
            lot_w, lot_d = city_lot(kind)
            if abs(z) < JUNCTION_HALF + lot_w / 2 + 4:
                continue
            if any(abs(z - az) < JUNCTION_HALF + lot_w / 2 + 4 for az in AVENUE_ZS):
                continue
            if any(p[0] == side and abs(p[1] - z) < (p[2] + lot_w) / 2 + 8 for p in placed):
                continue
            x = jx + side * (SIDEWALK_EDGE + lot_d / 2)
            if x < AVENUE_X0 + 10 or x > ROAD_X1 - 20:
                continue  # keep the lots clear of the city's west wall and the museum's hill
            yaw = -90 if side > 0 else 90  # the front door faces the cross street
            if add_house(x, z, yaw, kind, street):
                placed.append((side, z, lot_w))

    # Avenue lots: numbered doors on the avenues themselves, between the junctions.
    bounds = [AVENUE_X0 + 80] + [j["x"] for j in junctions] + [AVENUE_X1 - 80]
    spans = [(a, b) for a, b in zip(bounds, bounds[1:]) if b - a > 300]
    for az in AVENUE_ZS:
        avenue = "Midtown Ave" if abs(az) < 500 else "Skyline Ave"
        for a, b in spans:
            if len(city_houses) >= budget:
                break
            count = 1 if b - a < 520 else 2
            for pos in rng.sample([rng.uniform(a + 90, b - 90) for _ in range(3)], min(count, 3)):
                rough = level_at(pos, az)
                if rough is None:
                    continue
                kind = city_kind(rough, rng)
                lot_w, lot_d = city_lot(kind)
                if any(abs(pos - j["x"]) < JUNCTION_HALF + lot_w / 2 + 10 for j in junctions):
                    continue
                if abs(az) < 500:  # Midtown: both sides are buildable
                    side = rng.choice((-1, 1))
                else:              # Skyline: only the side facing the city
                    side = -1 if az > 0 else 1
                x, z = pos, az + side * (SIDEWALK_EDGE + lot_d / 2)
                yaw = 0 if side < 0 else 180  # faces the avenue
                if add_house(x, z, yaw, kind, avenue):
                    break  # one per span keeps the avenues from crowding

    # -- the street network the defenders chase through ("axis,fixed,lo,hi" per lane)
    lanes = [("x", 0.0, ROAD_X0, ROAD_X1)]
    for az in AVENUE_ZS:
        lanes.append(("x", az, AVENUE_X0, AVENUE_X1))
    for j in junctions:
        lanes.append(("z", j["x"], -CITY_DEPTH, CITY_DEPTH))
    lanes_str = ";".join(f"{a},{f:.0f},{lo:.0f},{hi:.0f}" for a, f, lo, hi in lanes)

    corridor_end = min(house_x(1) - LOT_W / 2, min(j["x"] for j in junctions)) - 48
    return {"junctions": junctions, "houses": city_houses, "lanes": lanes_str,
            "corridor_end": corridor_end}


# --- the three city house shapes -------------------------------------------


def _city_common(hb: HouseBuilder, ch: dict):
    """Wiring every city house shares: attributes the server reads, budget of loot spots,
    front path, gate route markers, a small city garden and a driveway if the guard needs one."""
    hb.model.attr(Guard=ch["guard"]["id"], GuardCount=ch["count"], LootHouse=f'House{ch["level"]}',
                  Level=ch["level"])
    front = hb.lot_d / 2 - FRONT_YARD
    gaps = [(0, 6)]
    if ch["guard"]["kind"] == "Vehicle":
        gaps.append((CITY_DRIVE_X[ch["kind"]], 13))
    hb.fence({1: "picket", 2: "hedge", 3: "modern"}[min(3, ch["tier"])], gaps)
    hb.path(0, front + 4.0, hb.lot_d / 2 - 0.6, 4)
    hb.route_lot("Street", 0, hb.lot_d / 2 + 6)
    hb.route_lot("Gate", 0, hb.lot_d / 2 - 0.2)
    hb.route_lot("Door", 0, front - 0.3)
    palette = ch["palette"]
    bush(hb.yard, hb.lot_cf * CF(-hb.lot_w / 2 + 6, 0, front + 1.2), 2.2, palette["bush"])
    bush(hb.yard, hb.lot_cf * CF(hb.lot_w / 2 - 6, 0, front + 1.2), 2.2, palette["bush"])
    hb.y("MailboxPost", (0.3, 3.0, 0.3), (4.6, 1.5, hb.lot_d / 2 - 1.2), WOOD_DARK, "Wood")
    hb.y("Mailbox", (1.0, 0.9, 1.6), (4.6, 3.4, hb.lot_d / 2 - 1.2), palette["door"], "Metal")
    if ch["guard"]["kind"] == "Vehicle":
        hb.y("Driveway", (13, 0.12, FRONT_YARD - 1.5), (CITY_DRIVE_X[ch["kind"]], 0.06, hb.lot_d / 2 - (FRONT_YARD - 1.5) / 2),
             (198, 194, 184), "Concrete")


CITY_DRIVE_X = {"cottage": 10.5, "ranch": 12.0, "town": 10.5}

# Where each kind of defender waits in each house shape, in plan coordinates (x, z, facing).
CITY_POSTS = {
    "cottage": {
        "Cat": ((-9.5, 11, "e"),), "Dog": ((-9.5, 11, "e"),), "Human": ((-9.5, 11, "e"),),
        "Wizard": ((-9.5, 11, "e"),), "Beast": ((-11.5, 5, "e"),),
        "Robot": ((-6.5, 4, "e"), (10, 5, "w"), (8, -12, "n")),
        "Vehicle": ((7.8, 20, "s"),),
    },
    "ranch": {
        "Cat": ((-12, 13, "e"),), "Dog": ((-12, 13, "e"),), "Human": ((-12, 13, "e"),),
        "Wizard": ((-12, 13, "e"),), "Beast": ((-15, 8, "e"),),
        "Robot": ((-7, 5, "e"), (9, 10, "w"), (11, -11, "n")),
        "Vehicle": ((9.2, 21, "s"),),
    },
    "town": {
        "Cat": ((-9, 12.5, "e"),), "Dog": ((-9, 12.5, "e"),), "Human": ((-9, 12.5, "e"),),
        "Wizard": ((-9, 12.5, "e"),), "Beast": ((-11, 5, "e"),),
        "Robot": ((-6, 5, "e"), (9, 12, "w"), (8, -11, "n")),
        "Vehicle": ((7, 19.5, "s"),),
    },
}


def _city_guards(hb: HouseBuilder, ch: dict):
    guard = ch["guard"]
    posts = list(CITY_POSTS[ch["kind"]].get(guard["kind"], CITY_POSTS[ch["kind"]]["Dog"]))
    while len(posts) < ch["count"]:
        posts.append(posts[-1])
    for post_x, post_z, facing in posts[: ch["count"]]:
        hb.guard_post(post_x, post_z, facing, guard, ch["tier"], ch["palette"]["pet"])


def build_city_cottage(folder: Inst, ch: dict, lot_cf: CF, lot_w: float, lot_d: float):
    """A compact one-storey cottage: living room and kitchen on the left, a den on the right."""
    W, D = CITY_KIND_PLANS["cottage"]
    H = 13.0
    hb = HouseBuilder(folder, ch["id"], ch["display"], ch["tier"], lot_cf, lot_w, lot_d, W, D, H,
                      FRONT_YARD, HOUSE_SCALE)
    palette = ch["palette"]
    hb.spot_budget = HOUSE_SPOTS  # same five items out as every other house
    hb.wall_color, hb.wall_material = palette["wall"], "Plaster"
    t = 0.8
    xi, zi = W / 2 - t, D / 2 - t
    hb.exterior(t, palette["wall"], "Plaster",
                front=[door_opening(0, 5, 9), window(-16.5, 4.4), window(-8.5, 4.4), window(8.5, 4.4),
                       window(16.5, 4.4)],
                back=[window(-8, 4.6), window(8, 4.6)], left=[window(-5, 4.4)], right=[window(5, 4.4)])
    hb.floor(WOOD_LIGHT)
    hb.room_floor(-xi, -4.25, -zi, -0.25, (226, 226, 222), "CeramicTiles")
    hb.room_floor(4.25, xi, -zi + 0.05, zi, palette["carpet"], "Carpet")
    hb.wall_z(-4, -zi, zi, 0.5, H, [doorway(8, 5, 9), doorway(-8, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_z(4, -zi, zi, 0.5, H, [doorway(6, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(0, -xi, -4.25, 0.5, H, [doorway(-14, 7, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.route_node("WestFront", -4, 8)
    hb.route_node("WestRear", -4, -8)
    hb.route_node("EastDen", 4, 6)
    hb.route_node("Hall", 0, 12)
    hb.room("Living", -xi + 0.3, 0.3, -4.6, zi - 0.3, "WestFront")
    hb.room("Kitchen", -xi + 0.3, -zi + 0.3, -4.6, -0.3, "WestRear")
    hb.room("Den", 4.6, -zi + 0.3, xi - 0.3, zi - 0.3, "EastDen")
    hb.room("Hall", -4.6, -zi + 0.3, 4.6, zi - 0.3)
    hb.gable_roof(8.0, 1.3, palette["roof"])
    hb.p("Chimney", (2.6, 8, 2.6), (-15, H + 4.6, -7), (186, 108, 88), "Brick")
    hb.door("x", D / 2 - t / 2, 0, 5, 9, +1, palette["door"], step=False)
    for sx in (-1, 1):
        hb.p("DoorTrim", (0.55, 9, 0.35), (sx * 2.78, 4.5, D / 2 + 0.1), WHITE, "SmoothPlastic")
    hb.p("DoorTrim", (6.2, 0.55, 0.35), (0, 9.28, D / 2 + 0.1), WHITE, "SmoothPlastic")
    porch_h = H - 2.6
    hb.p("PorchFloor", (11, 0.35, 4.2), (0, 0.175, D / 2 + 2.1), (202, 172, 132), "WoodPlanks")
    for x in (-4.9, 4.9):
        hb.p("PorchColumn", (porch_h, 0.8, 0.8), (x, 0.35 + porch_h / 2, D / 2 + 3.7), WHITE,
             "SmoothPlastic", rot=(0, 0, 90), shape="Cylinder")
    hb.p("PorchRoof", (12.2, 0.6, 4.9), (0, 0.35 + porch_h + 0.3, D / 2 + 2.3), palette["roof"], "RoofShingles")
    porch_light = hb.p("PorchLight", (0.6, 0.9, 0.4), (3.4, 7.4, D / 2 + 0.25), (255, 222, 160), "Neon",
                       parent=hb.furniture, collide=False)
    point_light(porch_light, (255, 214, 150), 1.0, 16)
    # Living room
    hb.tv_stand(-22.0, 8, "e")
    hb.p("TV", (0.3, 3.2, 5.4), (-22.9, 5.0, 8), BLACK, parent=hb.furniture)
    hb.p("TVScreen", (0.05, 2.8, 5.0), (-22.73, 5.0, 8), (40, 110, 220), "Neon", parent=hb.furniture,
         collide=False)
    hb.sofa(-11.5, 8, "w", length=8, color=palette["sofa"])
    hb.rug(-15, 8, 8, 7, palette["rug"])
    hb.plant(-21.5, 14.6)
    hb.coffee_table(-14.2, 8, "e")
    # Kitchen
    hb.counter(-13, -15.35, "s", length=10, spots=2)
    hb.fridge(-21.35, -15.2, "s")
    hb.table(-13, -6.5, "s", width=6, depth=3.6, height=2.9, spots=1, chairs=True)
    # Hall
    hb.pedestal(0, -13.2, "s")
    hb.rug(0, 4, 3.2, 18, palette["rug"])
    hb.painting("z", -3.75, 3, 6.4, +1, (palette["accent"], (240, 220, 120)))
    # The den
    hb.bed(15.5, -11.9, "s", color=palette["bed"])
    hb.nightstand(20.35, -15.2, "s")
    hb.desk(19.35, 9.5, "w")
    hb.dresser(19.35, -3.5, "w", color=palette["accent"])
    hb.low_shelf(9, 3.3, "s")
    for x, z in ((-14, 8), (-13, -9), (0, 10), (0, -6), (13, -7), (13, 9)):
        hb.lamp(x, z)
    _city_guards(hb, ch)
    hb.siren((0, H - 0.6, D / 2 + 0.45))
    hb.siren((0, H - 0.5, 5))
    _city_common(hb, ch)
    return hb


def build_city_ranch(folder: Inst, ch: dict, lot_cf: CF, lot_w: float, lot_d: float):
    """A long single-storey ranch house with a carport on the east gable."""
    W, D = CITY_KIND_PLANS["ranch"]
    H = 15.0
    hb = HouseBuilder(folder, ch["id"], ch["display"], ch["tier"], lot_cf, lot_w, lot_d, W, D, H,
                      FRONT_YARD, HOUSE_SCALE)
    palette = ch["palette"]
    hb.spot_budget = HOUSE_SPOTS  # same five items out as every other house
    hb.wall_color, hb.wall_material = palette["wall"], "Plaster"
    t = 0.8
    xi, zi = W / 2 - t, D / 2 - t
    hb.exterior(t, palette["wall"], "Plaster",
                front=[door_opening(0, 5, 9), window(-24, 5), window(-15, 5), window(-7, 5), window(7, 5),
                       window(15, 5), window(24, 5)],
                back=[window(-22, 5), window(-10, 5), window(10, 5), window(22, 5)],
                left=[window(-6, 5)], right=[window(2, 5)])
    hb.floor(WOOD_LIGHT)
    hb.room_floor(-xi, -4.25, -zi, -0.25, (226, 226, 222), "CeramicTiles")
    hb.room_floor(4.25, xi, -zi, 2.5, palette["carpet"], "Carpet")
    hb.room_floor(4.25, xi, 3.5, zi, WOOD, "WoodPlanks")
    hb.wall_z(-4, -zi, zi, 0.5, H, [doorway(10, 5, 9), doorway(-10, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_z(4, -zi, zi, 0.5, H, [doorway(11, 5, 9), doorway(-9, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(0, -xi, -4.25, 0.5, H, [doorway(-18, 8, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(3, 4.25, xi, 0.5, H, [], OFFWHITE, "Plaster", "InteriorWall")
    hb.route_node("WestFront", -4, 10)
    hb.route_node("WestRear", -4, -10)
    hb.route_node("EastFront", 4, 11)
    hb.route_node("EastRear", 4, -9)
    hb.route_node("Hall", 0, 14)
    hb.room("Living", -xi + 0.3, 0.3, -4.6, zi - 0.3, "WestFront")
    hb.room("Kitchen", -xi + 0.3, -zi + 0.3, -4.6, -0.3, "WestRear")
    hb.room("Bedroom", 4.6, -zi + 0.3, xi - 0.3, 2.4, "EastRear")
    hb.room("Study", 4.6, 3.6, xi - 0.3, zi - 0.3, "EastFront")
    hb.room("Hall", -4.6, -zi + 0.3, 4.6, zi - 0.3)
    hb.gable_roof(9.0, 1.4, palette["roof"])
    hb.door("x", D / 2 - t / 2, 0, 5, 9, +1, palette["door"], step=False)
    for sx in (-1, 1):
        hb.p("DoorTrim", (0.55, 9, 0.35), (sx * 2.78, 4.5, D / 2 + 0.1), WHITE, "SmoothPlastic")
    hb.p("DoorTrim", (6.2, 0.55, 0.35), (0, 9.28, D / 2 + 0.1), WHITE, "SmoothPlastic")
    porch_h = H - 2.8
    hb.p("PorchFloor", (13, 0.35, 4.6), (0, 0.175, D / 2 + 2.3), (202, 172, 132), "WoodPlanks")
    for x in (-5.9, 5.9):
        hb.p("PorchColumn", (porch_h, 0.9, 0.9), (x, 0.35 + porch_h / 2, D / 2 + 4.1), WHITE,
             "SmoothPlastic", rot=(0, 0, 90), shape="Cylinder")
    hb.p("PorchRoof", (14.4, 0.6, 5.4), (0, 0.35 + porch_h + 0.3, D / 2 + 2.5), palette["roof"], "RoofShingles")
    porch_light = hb.p("PorchLight", (0.6, 0.9, 0.4), (3.6, 7.6, D / 2 + 0.25), (255, 222, 160), "Neon",
                       parent=hb.furniture, collide=False)
    point_light(porch_light, (255, 214, 150), 1.0, 16)
    # Carport on the east side (pure set dressing, no way in)
    cp_x = W / 2 + 6.5
    hb.p("CarportPad", (13, 0.14, 20), (cp_x, 0.07, 3), CONCRETE, "Concrete", parent=hb.yard, frame=hb.cf)
    for dx, dz in ((-5.6, -8.6), (5.6, -8.6), (-5.6, 8.6), (5.6, 8.6)):
        hb.p("CarportPost", (0.7, 8.6, 0.7), (cp_x + dx, 4.3, 3 + dz), WHITE, "SmoothPlastic",
             parent=hb.structure, frame=hb.cf)
    hb.p("CarportRoof", (14.6, 0.7, 21), (cp_x, 9.0, 3), palette["roof"], "RoofShingles",
         parent=hb.structure, frame=hb.cf)
    hb.p("CarBody", (4.6, 2.4, 8.6), (cp_x, 1.65, 3), (150, 160, 175), "Metal", parent=hb.yard, frame=hb.cf)
    hb.p("CarCab", (4.0, 1.6, 4.2), (cp_x, 3.6, 3.6), (120, 150, 180), "Glass", parent=hb.yard, frame=hb.cf,
         transparency=0.3)
    # Living room
    hb.tv_stand(-30.0, 9.5, "e")
    hb.p("TV", (0.3, 3.4, 6.0), (-30.95, 5.3, 9.5), BLACK, parent=hb.furniture)
    hb.p("TVScreen", (0.05, 3.0, 5.6), (-30.78, 5.3, 9.5), (40, 110, 220), "Neon", parent=hb.furniture,
         collide=False)
    hb.sofa(-18, 9.5, "w", length=10, color=palette["sofa"])
    hb.sofa(-24, 13.8, "n", length=5, color=palette["sofa"])
    hb.rug(-21, 9.5, 9, 8, palette["rug"])
    hb.plant(-29.5, 15.6)
    # Kitchen & dining
    hb.counter(-19, -16.35, "s", length=12, spots=2)
    hb.fridge(-29.4, -16.2, "s")
    hb.table(-19, -7.5, "s", width=8, depth=4, height=2.9, spots=1, chairs=True)
    # Hall
    hb.pedestal(0, -14.8, "s")
    hb.rug(0, 4, 3.4, 22, palette["rug"])
    hb.painting("z", -3.75, 3, 7, +1, (palette["accent"], (240, 220, 120)))
    hb.painting("z", 3.75, -3, 7, -1, ((80, 140, 200), palette["accent"]))
    # Bedroom & study
    hb.bed(21, -13.0, "s", color=palette["bed"])
    hb.nightstand(27.8, -15.6, "s")
    hb.dresser(27.4, -5.5, "w", color=palette["accent"])
    hb.desk(27.4, 10, "w")
    hb.tall_bookcase(9, 3.1, "s")
    hb.sofa(14, 16.6, "n", length=5, color=palette["sofa"])
    for x, z in ((-20, 9), (-19, -9), (0, 11), (0, -7), (20, -9), (16, 10)):
        hb.lamp(x, z)
    _city_guards(hb, ch)
    hb.siren((0, H - 0.6, D / 2 + 0.45))
    hb.siren((0, H - 0.5, 6))
    _city_common(hb, ch)
    return hb


def build_city_townhouse(folder: Inst, ch: dict, lot_cf: CF, lot_w: float, lot_d: float):
    """A two-storey town house: down below a living room, kitchen and den like a normal house;
    a staircase climbs from the living room to the bedroom and gallery upstairs, where the best
    pieces are kept. Defenders sleep downstairs and cannot climb, so the way back down is the
    risky part."""
    W, D = CITY_KIND_PLANS["town"]
    GROUND_H, SLAB_T = 10.7, 0.8                 # the upstairs floor slab
    FLOOR2 = GROUND_H + SLAB_T                   # 11.5: where upstairs feet and furniture stand
    UPPER_H = 21.9                               # top of the upper walls
    hb = HouseBuilder(folder, ch["id"], ch["display"], ch["tier"], lot_cf, lot_w, lot_d, W, D,
                      UPPER_H, FRONT_YARD, HOUSE_SCALE)
    palette = ch["palette"]
    hb.spot_budget = HOUSE_SPOTS  # same five items out as every other house
    hb.wall_color, hb.wall_material = palette["wall"], "Brick"
    t = 0.9
    xi, zi = W / 2 - t, D / 2 - t
    upper_windows_f = [window(x, 4.6, 14.6, 19.0) for x in (-14, -6.8, 6.8, 14)]
    upper_windows_b = [window(x, 4.6, 14.6, 19.0) for x in (-10, 0, 10)]
    hb.exterior(t, palette["wall"], "Brick",
                front=[door_opening(0, 5, 9), window(-10.5, 4.4, 3.2, 7.6), window(10.5, 4.4, 3.2, 7.6),
                       window(17, 3.6, 3.2, 7.6)] + upper_windows_f,
                back=[window(-8, 4.6, 3.2, 7.6), window(8, 4.6, 3.2, 7.6)] + upper_windows_b,
                left=[window(-4, 4.2, 14.6, 19.0)], right=[window(4, 4.2, 14.6, 19.0)])
    # Cornice band between the storeys and the parapet that finishes the flat roof.
    for sz in (-1, 1):
        hb.p("Cornice", (W + 0.5, 0.65, t + 0.5), (0, 10.9, sz * (D / 2 - t / 2)), WHITE, "Limestone")
        hb.p("Parapet", (W + 0.9, 1.5, t + 0.9), (0, UPPER_H + 0.55, sz * (D / 2 - t / 2)), WHITE, "Limestone")
    for sx in (-1, 1):
        hb.p("Cornice", (t + 0.5, 0.65, D + 0.5), (sx * (W / 2 - t / 2), 10.9, 0), WHITE, "Limestone")
        hb.p("Parapet", (t + 0.9, 1.5, D + 0.9), (sx * (W / 2 - t / 2), UPPER_H + 0.55, 0), WHITE, "Limestone")
    hb.flat_roof(0.9, (66, 60, 58), 1.0)

    hb.floor(WOOD_LIGHT)
    hb.room_floor(-xi, -4.25, -zi, -0.25, (226, 226, 222), "CeramicTiles")
    hb.room_floor(4.25, xi, -zi + 0.05, zi, palette["carpet"], "Carpet")
    hb.wall_z(-4, -zi, zi, 0.5, GROUND_H, [doorway(8, 5, 9), doorway(-8, 5, 9)], OFFWHITE, "Plaster",
              "InteriorWall")
    hb.wall_z(4, -zi, zi, 0.5, GROUND_H, [doorway(8, 5, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.wall_x(0, -xi, -4.25, 0.5, GROUND_H, [doorway(-13, 7, 9)], OFFWHITE, "Plaster", "InteriorWall")
    hb.route_node("WestFront", -4, 8)
    hb.route_node("WestRear", -4, -8)
    hb.route_node("EastDen", 4, 8)
    hb.route_node("Hall", 0, 11)

    def room3d(name, x0, z0, x1, z1, y0, y1, via=None):
        box = hb.p(name, (abs(x1 - x0), y1 - y0, abs(z1 - z0)), ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
                   (60, 200, 255), parent=hb.rooms, transparency=1, collide=False, query=False, touch=False,
                   shadow=False)
        if via:
            box.attr(Via=via)
        return box

    room3d("Living", -xi + 0.3, 0.3, -4.6, zi - 0.3, 0.0, 10.4, "WestFront")
    room3d("Kitchen", -xi + 0.3, -zi + 0.3, -4.6, -0.3, 0.0, 10.4, "WestRear")
    room3d("Den", 4.6, -zi + 0.3, xi - 0.3, zi - 0.3, 0.0, 10.4, "EastDen")
    room3d("Hall", -4.6, -zi + 0.3, 4.6, zi - 0.3, 0.0, 10.4)
    # Upstairs: the landing at the top of the stairs, the master bedroom over the den, and the
    # gallery over the living room and kitchen. No waypoints lead up here on purpose - the
    # defenders wait below while you find your own way back down.
    room3d("Landing", -xi + 0.3, -zi + 0.3, 4.6, -7.6, 11.5, 21.5)
    room3d("Bedroom", 4.6, -zi + 0.3, xi - 0.3, -0.4, 11.5, 21.5, "BedDoor")
    room3d("Gallery", -xi + 0.3, -7.6, 4.6, zi - 0.3, 11.5, 21.5)
    marker(hb.route, "Stairs", hb.frame(-17.6, -5.2, "n", FLOOR2), (0.6, 0.6, 0.6))
    marker(hb.route, "BedDoor", hb.frame(4, -13.5, "n", FLOOR2), (0.6, 0.6, 0.6))

    # The staircase: a straight ramp in the living room climbing the west wall, with a handrail.
    ramp_len, ramp_w = 18.6, 5.0
    ramp_zc, ramp_x = 2.1, -17.6
    hb.p("StairRamp", (ramp_w, FLOOR2 - 0.7, ramp_len), (ramp_x, 0.7 + (FLOOR2 - 0.7) / 2, ramp_zc),
         (196, 168, 128), "WoodPlanks", rot=(0, 180, 0), cls="WedgePart")
    hb.p("StairLanding", (ramp_w + 0.6, 0.5, 1.8), (ramp_x, FLOOR2 - 0.25, -7.5), (196, 168, 128), "WoodPlanks")
    slope = math.degrees(math.atan2(FLOOR2 - 0.7, ramp_len))
    hb.p("StairRail", (0.3, 0.3, ramp_len + 1.4), (ramp_x + ramp_w / 2 - 0.2, 3.4 + (FLOOR2 - 0.7) / 2, ramp_zc),
         WOOD_DARK, "Wood", rot=(-slope, 0, 0))
    for i in range(4):
        zz = ramp_zc + ramp_len / 2 - 1 - i * (ramp_len / 3.2)
        yy = 0.7 + (FLOOR2 - 0.7) * (ramp_zc + ramp_len / 2 - zz) / ramp_len
        hb.p("RailPost", (0.28, 3.4, 0.28), (ramp_x + ramp_w / 2 - 0.2, yy + 1.7, zz), WOOD_DARK, "Wood")
    # Balustrade guarding the stairwell opening where the upstairs floor is cut away.
    hb.p("Balustrade", (0.3, 3.0, 20.4), (-14.75, FLOOR2 + 1.5, ramp_zc + 0.4), WOOD_DARK, "Wood")
    hb.p("BalustradeCap", (0.5, 0.3, 20.7), (-14.75, FLOOR2 + 3.05, ramp_zc + 0.4), WOOD, "Wood")
    # The upstairs floor slab, in pieces around the stairwell.
    slab_y = GROUND_H + SLAB_T / 2
    hb.p("UpperFloor", (xi + 15.0, SLAB_T, D - 0.2), ((xi - 15.0) / 2, slab_y, 0), (206, 186, 156), "WoodPlanks")
    hb.p("UpperFloor", (0.9, SLAB_T, D - 0.2), (-xi + 0.45, slab_y, 0), (206, 186, 156), "WoodPlanks")
    hb.p("UpperFloor", (5.2, SLAB_T, zi - 7.8 + 0.1), (-17.6, slab_y, -(7.8 + (zi - 7.8) / 2) + 0.05 - 0.25),
         (206, 186, 156), "WoodPlanks")
    hb.p("UpperFloor", (5.2, SLAB_T, zi - 12.2 + 0.1), (-17.6, slab_y, (12.2 + zi) / 2 - 0.05),
         (206, 186, 156), "WoodPlanks")
    # Upstairs interior walls: landing | bedroom wall with a doorway, and the upstairs ceilings.
    def uwall(name, size, pos):
        hb.p(name, size, pos, OFFWHITE, "Plaster")
    uy0, uy1 = FLOOR2, UPPER_H - 0.3
    # wall at x=+4 separating the bedroom, with a doorway at z=-13.5
    for z0, z1 in ((-zi, -16), (-11, -0.4)):
        uwall("InteriorWall", (0.5, uy1 - uy0, z1 - z0), (4, (uy0 + uy1) / 2, (z0 + z1) / 2))
    # wall at z=-7.6 separating the landing from the gallery on the west half (open arch at the
    # stairs side, x < 1)
    uwall("InteriorWall", (1 - (-xi + 0.3), uy1 - uy0, 0.5), ((1 + (-xi + 0.3)) / 2, (uy0 + uy1) / 2, -7.6))
    hb.p("UpperCeiling", (W - 0.2, 0.3, D - 0.2), (0, UPPER_H - 0.45, 0), (236, 234, 228), "Plaster")

    door_color = palette["door"]
    hb.door("x", D / 2 - t / 2, 0, 5, 9, +1, door_color, step=False)
    for sx in (-1, 1):
        hb.p("DoorTrim", (0.55, 9, 0.35), (sx * 2.78, 4.5, D / 2 + 0.1), WHITE, "SmoothPlastic")
    hb.p("DoorTrim", (6.2, 0.55, 0.35), (0, 9.28, D / 2 + 0.1), WHITE, "SmoothPlastic")
    steps = ("Stoop", (7.5, 0.5, 3.4), (0, 0.25, D / 2 + 1.9), CONCRETE)
    hb.p(*steps, "Concrete")
    hb.p("CanopyRoof", (8.6, 0.5, 3.2), (0, 9.8, D / 2 + 1.8), palette["roof"], "RoofShingles")
    hb.p("CanopyFascia", (8.8, 0.4, 3.4), (0, 9.55, D / 2 + 1.8), WHITE, "SmoothPlastic")
    porch_light = hb.p("PorchLight", (0.6, 0.9, 0.4), (3.4, 7.4, D / 2 + 0.25), (255, 222, 160), "Neon",
                       parent=hb.furniture, collide=False)
    point_light(porch_light, (255, 214, 150), 1.0, 16)

    def ground_lamp(x, z):
        f = hb.cf * CF(x, GROUND_H - 0.45, z)
        shade_part = part(hb.furniture, "CeilingLamp", (0.6, 1.8, 1.8), f * CF.deg(0, 0, 90),
                          (255, 240, 205), "Neon", shape="Cylinder", collide=False)
        point_light(shade_part, (255, 236, 205), 0.85, 18)

    def upper_lamp(x, z):
        f = hb.cf * CF(x, UPPER_H - 0.85, z)
        shade_part = part(hb.furniture, "CeilingLamp", (0.6, 1.8, 1.8), f * CF.deg(0, 0, 90),
                          (255, 240, 205), "Neon", shape="Cylinder", collide=False)
        point_light(shade_part, (255, 236, 205), 0.85, 18)

    # Ground floor: living room, kitchen, den (the stairs fill the west of the living room).
    hb.sofa(-13, 8.2, "w", length=6, color=palette["sofa"])
    hb.rug(-11, 10, 6, 6, palette["rug"])
    hb.plant(-5.6, 14.8)
    hb.counter(-12, -14.6, "s", length=9, spots=2)
    hb.fridge(-20.15, -14.5, "s")
    hb.table(-10, -7, "s", width=5.4, depth=3.4, height=2.9, spots=0, chairs=True)
    hb.pedestal(0, -12.9, "s")
    hb.rug(0, 4, 3.0, 16, palette["rug"])
    hb.bed(13, -11.9, "s", color=palette["bed"])
    hb.nightstand(19.65, -14.7, "s")
    hb.desk(19.6, 9.5, "w")
    hb.low_shelf(9, 3.3, "s")
    for x, z in ((-10, 8), (-11, -9), (0, 8), (0, -6), (12, -7), (12, 9)):
        ground_lamp(x, z)
    # Upstairs: the gallery's dresser and display (the good stuff), the bedroom and the landing.
    hb.FLOOR_Y = FLOOR2  # frame()-built furniture (beds, dressers...) lands on the upstairs floor
    hb.dresser(-18.9, 8.5, "w", color=palette["accent"])
    hb.nightstand(-18.9, -2.5, "w")
    hb.bed(12.5, -12.4, "s", color=palette["bed"], headboard_h=3.6)
    hb.desk(19.6, -6.5, "w")
    hb.table(-9, -12.6, "s", width=4.2, depth=2.6, height=2.9, spots=1, color=WOOD_DARK)
    hb.tall_bookcase(2.9, -13.5, "n")
    hb.rug(-8, -11.5, 5, 4, palette["rug"])
    hb.FLOOR_Y = 0.7
    for x, z in ((-8, -6), (-12, 8), (12, -8), (12, 6), (-8, 12)):
        upper_lamp(x, z)
    if ch["level"] >= 9:
        hb.laser((-3.6, 2.4, 4), (3.6, 2.4, 4), 0.7)          # across the ground-floor hall
        hb.laser((0.6, 13.2, -7.6), (4.9, 13.2, -7.6), 1.9)   # across the upstairs gallery archway
    _city_guards(hb, ch)
    hb.siren((0, GROUND_H - 0.6, D / 2 + 0.45))
    hb.siren((0, UPPER_H - 1.0, D / 2 + 0.45))
    _city_common(hb, ch)
    return hb


def build_city_house(folder: Inst, ch: dict):
    lot_w, lot_d = city_lot(ch["kind"])
    lot_cf = CF(ch["x"], 0, ch["z"]) * CF.deg(0, ch["yaw"], 0)
    builder = {"cottage": build_city_cottage, "ranch": build_city_ranch, "town": build_city_townhouse}
    hb = builder[ch["kind"]](folder, ch, lot_cf, lot_w, lot_d)
    return hb


# --- streets, filling and skyline -------------------------------------------

# Roblox clamps any part dimension above 2,048 studs at load time: with the map's streets now
# over ten kilometres long, a road that is one Studio part would vanish away from its middle on
# load. Everything laid out this long is therefore likewise tiled from one end to the other.
MAX_PART_SPAN = 2048.0


def _span_chunks(x0: float, x1: float) -> list[tuple[float, float]]:
    chunks = []
    edge = x0
    while edge < x1:
        nxt = min(edge + MAX_PART_SPAN, x1)
        chunks.append((edge, nxt))
        edge = nxt
    return chunks


def _asphalt(ground: Inst, name: str, x0: float, x1: float, z0: float, z1: float, top: float,
             color=ASPHALT):
    for a, b in _span_chunks(x0, x1):
        part(ground, name, (b - a, 0.2, z1 - z0), CF((a + b) / 2, top - 0.1, (z0 + z1) / 2), color, "Asphalt")


def _walkway(ground: Inst, x0: float, x1: float, z0: float, z1: float, top: float = 0.3):
    for a, b in _span_chunks(x0, x1):
        part(ground, "Sidewalk", (b - a, 0.3, z1 - z0), CF((a + b) / 2, top - 0.15, (z0 + z1) / 2),
             SIDEWALK, "Concrete")


def _kerb(ground: Inst, x0: float, x1: float, z: float):
    for a, b in _span_chunks(x0, x1):
        part(ground, "Curb", (b - a, 0.34, 0.6), CF((a + b) / 2, 0.17, z), (206, 200, 186), "Concrete")


def build_city_roads(ground: Inst, decor: Inst, city: dict, entrances: list[tuple[float, float]]):
    """The main street, the avenues, the cross streets and everything that dresses them."""
    jxs = [j["x"] for j in city["junctions"]]

    def near_junction(x: float, pad: float = JUNCTION_HALF + 5) -> bool:
        return any(abs(x - jx) < pad for jx in jxs)

    _asphalt(ground, "MainStreet", ROAD_X0, ROAD_X1, -16, 16, 0.20)
    for z in (-20, 20):
        _walkway(ground, WALK_X0, ROAD_X1, z - 4, z + 4, 0.30)
    _kerb(ground, WALK_X0, ROAD_X1, -23.7)
    _kerb(ground, WALK_X0, ROAD_X1, 23.7)
    for az in AVENUE_ZS:
        _asphalt(ground, "Avenue", AVENUE_X0, AVENUE_X1, az - 16, az + 16, 0.17)
        _walkway(ground, AVENUE_X0, AVENUE_X1, az - 24, az - 16, 0.27)
        _walkway(ground, AVENUE_X0, AVENUE_X1, az + 16, az + 24, 0.27)
    for j in city["junctions"]:
        jx = j["x"]
        _asphalt(ground, "CrossStreet", jx - 16, jx + 16, -CITY_DEPTH, CITY_DEPTH, 0.185)
        _walkway(ground, jx - 24, jx - 16, -CITY_DEPTH, CITY_DEPTH, 0.28)
        _walkway(ground, jx + 16, jx + 24, -CITY_DEPTH, CITY_DEPTH, 0.28)
        # dead ends get a turning pad at each end
        for end in (-1, 1):
            _asphalt(ground, "TurnPad", jx - 22, jx + 22, end * (CITY_DEPTH - 6), end * CITY_DEPTH, 0.186)
    # junction caps sit just above every overlap, hiding the seams
    for j in city["junctions"]:
        jx = j["x"]
        _asphalt(ground, "Junction", jx - 24, jx + 24, -24, 24, 0.205, (112, 116, 128))
        for az in AVENUE_ZS:
            _asphalt(ground, "Junction", jx - 24, jx + 24, az - 24, az + 24, 0.206, (112, 116, 128))
    # crosswalks where the cross streets meet the main street (and at the yard's drive lane)
    for cx in [CROSSWALK_X] + jxs:
        for i in range(11):
            part(decor, "Crosswalk", (6, 0.04, 1.4), CF(cx, 0.24, -14 + i * 2.8), WHITE, collide=False,
                 query=False, shadow=False)
    part(decor, "RoadEnd", (1.2, 0.3, 32), CF(ROAD_X1 - 0.6, 0.25, 0), (228, 224, 212), "Concrete")
    # lane dashes: dense on the main street, sparser further out
    x = ROAD_X0 + 10
    while x < ROAD_X1 - 10:
        if not near_junction(x) and not (CROSSWALK_X - 15 < x < CROSSWALK_X + 15):
            part(decor, "LaneDash", (9, 0.04, 0.6), CF(x, 0.22, 0), WHITE, collide=False, query=False,
                 shadow=False)
        x += 20
    for az in AVENUE_ZS:
        x = AVENUE_X0 + 15
        while x < AVENUE_X1 - 10:
            if not near_junction(x, JUNCTION_HALF + 3):
                part(decor, "LaneDash", (9, 0.04, 0.6), CF(x, 0.19, az), WHITE, collide=False, query=False,
                     shadow=False)
            x += 40
    for j in city["junctions"]:
        jx = j["x"]
        z = -CITY_DEPTH + 20
        while z < CITY_DEPTH - 10:
            if abs(z) > 36 and min(abs(z - az) for az in AVENUE_ZS) > 34:
                part(decor, "LaneDash", (0.6, 0.04, 9), CF(jx, 0.21, z), WHITE, collide=False, query=False,
                     shadow=False)
            z += 56
    # street lamps: the main street keeps its old rhythm (skipping driveways and junctions);
    # avenues and cross streets get a lamp now and then, and every junction gets corners.
    def blocked(px: float) -> bool:
        return near_junction(px) or any(abs(px - ex) < half + 5 for ex, half in entrances)

    x = WALK_X0 + 21
    side = 1
    while x < ROAD_X1 - 10:
        if not blocked(x):
            street_lamp(decor, CF(x, 0.3, 23.0 * side) * CF.deg(0, 0 if side > 0 else 180, 0))
        x += 90
        side = -side
    for az in AVENUE_ZS:
        x = AVENUE_X0 + 40
        side = 1
        while x < AVENUE_X1 - 30:
            if not near_junction(x, JUNCTION_HALF + 8):
                street_lamp(decor, CF(x, 0.27, (az + 20 * side)) * CF.deg(0, 0 if side > 0 else 180, 0))
            x += 160
            side = -side
    for j in city["junctions"]:
        jx = j["x"]
        z = -CITY_DEPTH + 40
        side = 1
        while z < CITY_DEPTH - 30:
            if abs(z) > 40 and min(abs(z - az) for az in AVENUE_ZS) > 38:
                street_lamp(decor, CF(jx + 20 * side, 0.28, z) * CF.deg(0, -90 * side, 0))
            z += 220
            side = -side
        for corner in ((-1, -1), (1, 1)):  # two diagonal corners of each main junction
            street_lamp(decor, CF(jx + 21 * corner[0], 0.3, 21 * corner[1])
                        * CF.deg(0, -90 if corner[0] > 0 else 90, 0))
    # street name signs at the main-street junctions
    for j in city["junctions"]:
        for side in (-1, 1):
            road_sign(decor, j["x"] + 20, side * 27, j["name"].upper() + " ST", 0)


CITY_BRICKS = [(192, 124, 104), (182, 140, 112), (164, 128, 118), (186, 112, 96), (172, 146, 128),
               (148, 140, 160), (190, 150, 122), (158, 142, 118), (176, 128, 142), (150, 152, 168)]


def facade(parent: Inst, rng: random.Random, x: float, z: float, yaw: float, width: float,
           floors: int, kind: str = "brick", door_sign: int | None = None) -> tuple[Inst, float]:
    """One plain city building: a wall box with a strip of windows per floor, facing local -Z.
    `kind` = "brick" for street-infill blocks, "tower" for the skyline slabs. Returns the model
    and the local x of its front door, so shopfronts and street life can gather at the door."""
    frame = CF(x, 0, z) * CF.deg(0, yaw, 0)
    m = model(parent, "Building", frame)
    depth = rng.uniform(13, 18) if kind == "brick" else rng.uniform(24, 34)
    color = rng.choice(CITY_BRICKS)
    trim = tuple(max(0, int(c * 0.82)) for c in color)

    def q(name, size, pos, c=color, mat="Brick", **kw):
        return part(m, name, size, frame * CF(*pos), c, mat, **kw)

    height = floors * 9.6 + rng.uniform(0, 2.5)
    q("Body", (width, height, depth), (0, height / 2, depth / 2))
    q("Parapet", (width + 0.8, 1.1, depth + 0.8), (0, height + 0.55, depth / 2), trim)
    q("Base", (width + 0.4, 2.2, depth + 0.4), (0, 1.1, depth / 2), trim)
    for f in range(floors):
        y = 4.6 + f * 9.6
        q("Windows", (width * 0.82, 4.2, 0.3), (0, y, -0.15), (56, 68, 88), "Glass", transparency=0.25,
          reflectance=0.3, collide=False)
        q("Sills", (width * 0.86, 0.5, 0.6), (0, y - 2.45, -0.2), trim)
    if kind == "brick":
        door_sx = width * 0.28 * (door_sign if door_sign in (-1, 1) else rng.choice((-1, 1)))
        q("Door", (4.2, 6.0, 0.5), (door_sx, 3.2, -0.3), rng.choice(CITY_DOORS), "Wood")
        q("Canopy", (6.2, 0.5, 2.4), (door_sx, 6.8, -1.2), trim)
    else:
        door_sx = 0.0
        q("Crown", (width * 0.6, 5.0, depth * 0.6), (0, height + 3.0, depth / 2), trim)
        q("Beacon", (1.2, 1.2, 1.2), (0, height + 6.4, depth / 2), (255, 90, 90), "Neon", collide=False)
        # Rooftop life: tanks, vents and aerials, so the skyline reads lived-in, not bare slabs.
        roof_y = height + 1.1
        if width > 20:
            tx, tz = rng.uniform(-width * 0.25, width * 0.25), rng.uniform(depth * 0.25, depth * 0.6)
            q("RoofTank", (4.4, 4.6, 4.4), (tx, roof_y + 3.5, tz), (122, 96, 74), "Wood")
            q("TankCap", (4.8, 0.5, 4.8), (tx, roof_y + 5.95, tz), trim)
            for lx in (-1.6, 1.6):
                for lz in (-1.6, 1.6):
                    q("TankLeg", (0.5, 1.5, 0.5), (tx + lx, roof_y + 0.75, tz + lz), trim)
        for _ in range(rng.randint(1, 3)):
            q("RoofVent", (rng.uniform(1.6, 2.6), rng.uniform(1.0, 2.0), rng.uniform(1.6, 2.6)),
              (rng.uniform(-width * 0.35, width * 0.35), roof_y + 0.9,
               rng.uniform(depth * 0.15, depth * 0.7)), trim, "Metal")
        if rng.random() < 0.6:
            ax = rng.uniform(-width * 0.3, width * 0.3)
            az = rng.uniform(depth * 0.2, depth * 0.7)
            ah = rng.uniform(5, 9)
            q("Aerial", (0.3, ah, 0.3), (ax, roof_y + ah / 2, az), (60, 60, 66), "Metal", collide=False)
            q("AerialTip", (0.7, 0.7, 0.7), (ax, roof_y + ah + 0.35, az), (255, 80, 80), "Neon",
              collide=False)
    return m, door_sx


def build_city_fill(map_folder: Inst, city: dict, canonical_xs: list[float]):
    """Fills the blocks between the streets with building fronts and the skyline behind them,
    so every street in the city is lined and the middle distance is rooftops, not lawn."""
    rng = random.Random(CITY_SEED + 5)
    folder = Inst("Folder", "CityFill", map_folder)
    jxs = [j["x"] for j in city["junctions"]]
    houses = city["houses"]

    def row(x0: float, x1: float, z: float, yaw: float, floors_min: int, floors_max: int,
            skip: list[tuple[float, float]] | None = None, shops: float = 0.0):
        """A run of building fronts along X between x0..x1, facing the street at z, skipping gaps.
        With `shops` > 0 some fronts get a shopkeeper's sign, awning and display window."""
        x = x0
        while x < x1 - 24:
            width = rng.uniform(30, 56)
            cx = x + width / 2
            if skip and any(abs(cx - sx) < (width + sw) / 2 + 6 for sx, sw in skip):
                x += width * 0.5
                continue
            if cx + width / 2 > x1:
                width = x1 - cx
            levels = rng.randint(floors_min, floors_max)
            door_sign = rng.choice((-1, 1))
            _, door_sx = facade(folder, rng, cx, z, yaw, width, levels, door_sign=door_sign)
            if shops > 0 and rng.random() < shops:
                shopfront(folder, CF(cx, 0, z) * CF.deg(0, yaw, 0), width, door_sx, city_zone(cx), rng)
            x += width + rng.uniform(0, 6)

    # The main street is lined from the canyon corridor to the museum's hill, around the named
    # houses' lots and the cross-street mouths.
    skip = [(cx, LOT_W + 8) for cx in canonical_xs] + [(j["x"], JUNCTION_HALF * 2 + 12) for j in city["junctions"]]
    corridor_end = city["corridor_end"]
    for side in (-1, 1):
        row(corridor_end + 12, AVENUE_X1 + 30, side * 55, 180 if side < 0 else 0, 2, 6, skip,
            shops=0.38)
    # The avenues get a city wall too, between grid junctions and around the numbered houses
    # that face them.
    for az in AVENUE_ZS:
        skip = [(j["x"], JUNCTION_HALF * 2 + 8) for j in city["junctions"]]
        skip += [(ch["x"], city_lot(ch["kind"])[0] + 6) for ch in houses if abs(abs(ch["z"]) - abs(az)) < 120]
        for side in (-1, 1):
            if abs(az) > 500 and side == (1 if az > 0 else -1):
                continue  # the outer face of the outer avenues is cliffs and towers
            row(AVENUE_X0 + 10, AVENUE_X1 - 10, az + side * 55, 180 if side < 0 else 0, 2, 7, skip,
                shops=0.22)
    # The cross streets: fronts between their houses, keeping clear of every lot.
    for j in city["junctions"]:
        jx = j["x"]
        for side in (-1, 1):
            street_houses = [ch for ch in houses if abs(ch["x"] - jx) < 110 and (ch["x"] - jx) * side > 30]
            lots = sorted((ch["z"], city_lot(ch["kind"])[0]) for ch in street_houses)
            gaps = []
            cursor = -CITY_DEPTH + 4
            for zc, lw in lots:
                gaps.append((cursor, zc - lw / 2 - 3))
                cursor = zc + lw / 2 + 3
            gaps.append((cursor, CITY_DEPTH - 4))
            # ...but a street never gets a front door on the corner of another one: every
            # corridor window — the junction square and all four avenue mouths — is cut out
            # of every gap wholesale, so no dice roll can ever slide a wall into a turn.
            windows = sorted([(-(JUNCTION_HALF + 14.0), JUNCTION_HALF + 14.0)] +
                             [(az - JUNCTION_HALF - 14.0, az + JUNCTION_HALF + 14.0)
                              for az in AVENUE_ZS])
            for a, b in gaps:
                a = max(a, -CITY_DEPTH + 4)
                b = min(b, CITY_DEPTH - 4)
                segments = [(a, b)]
                for wa, wb in windows:
                    nxt = []
                    for sa, sb in segments:
                        if sa < wa:
                            nxt.append((sa, min(sb, wa)))
                        if sb > wb:
                            nxt.append((max(sa, wb), sb))
                    segments = nxt
                for sa, sb in segments:
                    if sb - sa >= 30:
                        facade_row_gap(folder, rng, jx, side, sa, sb)
    # The block interiors: every grid square gets a life of its own (plazas, parks, car
    # parks, townhouse terraces, playgrounds, tower plots) — no more empty lawns.
    build_city_blocks(folder, city, canonical_xs)


def facade_row_gap(folder: Inst, rng: random.Random, jx: float, side: int, z0: float, z1: float):
    """Building fronts along one side of a cross street between two z limits."""
    z = z0
    while z < z1 - 26:
        width = rng.uniform(28, 46)
        cz = z + width / 2
        if cz + width / 2 > z1:
            width = z1 - cz
        x = jx + side * 33.5
        yaw = 90 if side > 0 else -90
        facade(folder, rng, x, cz, yaw, width, rng.randint(2, 5))
        z += width + rng.uniform(0, 5)


# ---------------------------------------------------------------------------
# City life: people, cars, shopfronts, furniture and packed block interiors
# ---------------------------------------------------------------------------

SKIN_TONES = [(255, 204, 158), (240, 178, 128), (196, 134, 92), (150, 102, 66), (112, 76, 48)]
SHIRT_COLORS = [(214, 66, 66), (66, 120, 200), (240, 190, 70), (90, 170, 100), (190, 110, 180),
                (240, 240, 240), (70, 70, 80), (230, 130, 60)]
PANTS_COLORS = [(60, 70, 90), (90, 80, 70), (40, 44, 52), (120, 110, 100)]
CAR_COLORS = [(200, 60, 60), (60, 110, 200), (240, 240, 240), (40, 40, 44), (240, 190, 60),
              (90, 160, 110), (160, 90, 160)]
AWNING_COLORS = [(196, 60, 56), (52, 106, 160), (232, 178, 62), (80, 140, 94), (150, 84, 140)]
FLOWER_COLORS = [(240, 120, 150), (250, 210, 90), (180, 140, 240), (240, 96, 74)]

# The shopkeeper's high street changes as you walk east: homely oldtown, buzzy midtown,
# then the expensive downtown window displays on the way up to the museum.
SHOP_NAMES = {
    "oldtown": ["BAKERY", "CAFÉ", "MILK BAR", "BARBER", "FLORIST", "SWEET SHOP", "LAUNDRY",
                "PIE SHOP", "GROCER", "BOOKBINDERY"],
    "midtown": ["PAWN SHOP", "LOCKSMITH", "NOODLE BAR", "RECORDS", "BIKES & CO", "TABAC",
                "BOOKS", "ARCADE", "KEYS CUT", "CURIOS"],
    "downtown": ["HOTEL", "BANK", "TAILOR", "CIGARS", "ANTIQUES", "JEWELLERS", "LOUNGE",
                 "FINE SUITES"],
}


def city_zone(x: float) -> str:
    """Which district a spot on the map is in — residential oldtown in the west, mixed
    midtown in the middle, downtown's offices in the east below the museum's hill."""
    if x < 3400:
        return "oldtown"
    if x < 8100:
        return "midtown"
    return "downtown"


def _yaw_point(x: float, z: float, yaw: float, lx: float, lz: float) -> tuple[float, float]:
    """World position of the local offset (lx, lz) under a yaw-rotated frame at (x, z)."""
    t = math.radians(yaw)
    return x + math.cos(t) * lx + math.sin(t) * lz, z - math.sin(t) * lx + math.cos(t) * lz


def pedestrian(parent: Inst, base: CF, rng: random.Random) -> Inst:
    """A blocky bystander, planted mid-errand (they never actually get there)."""
    m = model(parent, "Citizen", base)
    shirt = rng.choice(SHIRT_COLORS)
    pants = rng.choice(PANTS_COLORS)
    for sx in (-0.28, 0.28):
        part(m, "Leg", (0.42, 1.8, 0.42), base * CF(sx, 0.9, 0), pants)
    part(m, "Torso", (1.4, 1.8, 0.75), base * CF(0, 2.75, 0), shirt)
    for sx in (-0.88, 0.88):
        part(m, "Arm", (0.36, 1.6, 0.36), base * CF(sx, 2.7, 0), shirt)
    part(m, "Head", (0.9, 0.9, 0.9), base * CF(0, 4.2, 0), rng.choice(SKIN_TONES))
    if rng.random() < 0.4:
        part(m, "Hat", (1.05, 0.35, 1.05), base * CF(0, 4.82, 0), rng.choice(PANTS_COLORS))
    return m


def simple_car(parent: Inst, base: CF, rng: random.Random, color=None) -> Inst:
    """A little runabout — five boxes and four wheels, parked, never driven."""
    m = model(parent, "Car", base)
    c = color or rng.choice(CAR_COLORS)
    dark = tuple(max(0, int(v * 0.72)) for v in c)
    part(m, "Body", (7.6, 1.7, 3.4), base * CF(0, 1.4, 0), c)
    part(m, "Cabin", (3.8, 1.4, 3.0), base * CF(-0.3, 2.9, 0), dark)
    part(m, "Glass", (3.2, 1.1, 3.06), base * CF(-0.3, 2.95, 0), (80, 100, 120), "Glass",
         transparency=0.3, collide=False)
    for wx in (-2.35, 2.35):
        for wz in (-1.55, 1.55):
            part(m, "Wheel", (0.7, 1.3, 1.3), base * CF(wx, 0.65, wz) * CF.deg(0, 90, 0),
                 (30, 30, 34), "Rubber", shape="Cylinder")
    part(m, "Lights", (0.3, 0.5, 2.6), base * CF(3.82, 1.3, 0), (255, 240, 190), "Neon", collide=False)
    return m


def bench(parent: Inst, base: CF, color=(96, 70, 52)) -> Inst:
    m = model(parent, "Bench", base)
    part(m, "Seat", (4.2, 0.35, 1.4), base * CF(0, 1.35, 0), color, "Wood")
    part(m, "Back", (4.2, 1.1, 0.3), base * CF(0, 2.3, 0.66), color, "Wood")
    for sx in (-1.7, 1.7):
        part(m, "Legs", (0.4, 1.35, 1.2), base * CF(sx, 0.67, 0), (60, 60, 66), "Metal")
    return m


def traffic_light(parent: Inst, base: CF) -> Inst:
    m = model(parent, "TrafficLight", base)
    part(m, "Pole", (0.5, 13.5, 0.5), base * CF(0, 6.75, 0), (44, 48, 52), "Metal", collide=False)
    part(m, "Box", (1.5, 3.6, 1.0), base * CF(0, 12.6, 0), (28, 30, 34), collide=False)
    for i, c in enumerate(((255, 70, 60), (255, 170, 50), (90, 235, 120))):
        part(m, "Light", (0.75, 0.75, 0.75), base * CF(0, 13.7 - i * 1.1, -0.32), c, "Neon",
             shape="Ball", collide=False)
    return m


def street_name_sign(parent: Inst, base: CF, name: str) -> Inst:
    """The classic corner cross-sign: the cross street one way, MAIN ST the other."""
    m = model(parent, "StreetSign", base)
    part(m, "Post", (0.4, 10.5, 0.4), base * CF(0, 5.25, 0), (70, 74, 78), "Metal", collide=False)
    for i, (txt, yaw) in enumerate(((name.upper() + " ST", 0), ("MAIN ST", 90))):
        board = part(m, "Board", (9.0, 1.5, 0.3), base * CF(0, 9.4 - i * 1.75, 0) * CF.deg(0, yaw, 0),
                     (26, 92, 60), "SmoothPlastic", collide=False)
        surface_text(board, "Front", txt, pixels_per_stud=34)
        surface_text(board, "Back", txt, pixels_per_stud=34)
    return m


def bus_stop(parent: Inst, base: CF, rng: random.Random) -> Inst:
    """A shelter, a bench, a sign and someone who has been waiting far too long."""
    m = model(parent, "BusStop", base)
    part(m, "Roof", (8.6, 0.4, 3.6), base * CF(0, 7.4, 0), (60, 120, 190), "Metal", collide=False)
    part(m, "Back", (8.6, 5.6, 0.3), base * CF(0, 3.7, 1.6), (150, 170, 195), "Glass",
         transparency=0.55, collide=False)
    for sx in (-4.0, 4.0):
        part(m, "Post", (0.4, 7.4, 0.4), base * CF(sx, 3.7, 1.4), (44, 48, 52), "Metal", collide=False)
    bench(m, base * CF(0, 0, 0.8))
    part(m, "SignPost", (0.35, 9.5, 0.35), base * CF(-4.9, 4.75, -1.3), (70, 74, 78), "Metal",
         collide=False)
    board = part(m, "Sign", (2.6, 1.3, 0.2), base * CF(-4.9, 9.9, -1.3), (240, 200, 60),
                 "SmoothPlastic", collide=False)
    surface_text(board, "Front", "BUS", color=(30, 30, 30), stroke=None, pixels_per_stud=40)
    surface_text(board, "Back", "BUS", color=(30, 30, 30), stroke=None, pixels_per_stud=40)
    # the patient passenger, out front of the glass
    pedestrian(m, base * CF(rng.uniform(-2.0, 2.0), 0, -2.9) * CF.deg(0, rng.uniform(-30, 30), 0), rng)
    return m


def hydrant(parent: Inst, base: CF) -> Inst:
    m = model(parent, "Hydrant", base)
    part(m, "Body", (0.9, 1.6, 0.9), base * CF(0, 0.8, 0), (210, 50, 45), "Metal", collide=False)
    part(m, "Cap", (1.1, 0.4, 1.1), base * CF(0, 1.75, 0), (240, 200, 60), "Metal", collide=False)
    return m


def mailbox(parent: Inst, base: CF) -> Inst:
    m = model(parent, "Mailbox", base)
    part(m, "Post", (0.35, 2.4, 0.35), base * CF(0, 1.2, 0), (70, 74, 78), "Metal", collide=False)
    part(m, "Box", (1.6, 1.1, 1.0), base * CF(0, 2.9, 0), (60, 100, 190), "Metal", collide=False)
    part(m, "Flag", (0.15, 0.8, 0.5), base * CF(0.82, 3.6, 0), (230, 60, 55), collide=False)
    return m


def planter(parent: Inst, base: CF, rng: random.Random) -> Inst:
    m = model(parent, "Planter", base)
    part(m, "Tub", (4.6, 1.6, 4.6), base * CF(0, 0.8, 0), (150, 120, 96), "Wood")
    part(m, "Flowers", (3.9, 0.5, 3.9), base * CF(0, 1.8, 0), rng.choice(FLOWER_COLORS), "Grass",
         collide=False)
    bush(m, base * CF(-1.0, 1.5, 0.5), 2.6, LEAF)
    bush(m, base * CF(1.2, 1.5, -0.6), 2.2, LEAF_DARK)
    return m


def fountain(parent: Inst, base: CF) -> Inst:
    m = model(parent, "Fountain", base)
    part(m, "Basin", (9.0, 1.4, 9.0), base * CF(0, 0.7, 0), (212, 208, 196), "Marble")
    part(m, "Water", (7.6, 0.5, 7.6), base * CF(0, 1.35, 0), (110, 190, 235), "Glass",
         transparency=0.25, collide=False)
    part(m, "Column", (1.4, 3.2, 1.4), base * CF(0, 2.9, 0), (212, 208, 196), "Marble")
    part(m, "Top", (3.4, 0.5, 3.4), base * CF(0, 4.6, 0), (226, 222, 210), "Marble")
    part(m, "Sparkle", (0.8, 1.4, 0.8), base * CF(0, 5.45, 0), (170, 220, 250), "Neon",
         transparency=0.3, collide=False)
    return m


def shopfront(folder: Inst, frame: CF, width: float, door_sx: float, zone: str,
              rng: random.Random):
    """Dress a building's street face as a shop: a name board above and a big display
    window with a coloured awning beside the door."""
    name = rng.choice(SHOP_NAMES[zone])
    col = rng.choice(AWNING_COLORS)
    board = part(folder, "ShopSign", (min(width * 0.62, 22.0), 2.0, 0.4), frame * CF(0, 9.2, -0.5),
                 col, "SmoothPlastic")
    surface_text(board, "Front", name, pixels_per_stud=26)
    wsx = -door_sx if width > 30 else door_sx
    part(folder, "ShopAwning", (min(width * 0.4, 14.0), 0.4, 3.4),
         frame * CF(wsx, 7.0, -2.1) * CF.deg(-14, 0, 0), col, "Fabric", collide=False)
    part(folder, "ShopWindow", (min(width * 0.34, 11.0), 4.4, 0.3), frame * CF(wsx, 3.4, -0.22),
         (86, 104, 128), "Glass", transparency=0.2, reflectance=0.35, collide=False)


def playground(parent: Inst, base: CF, rng: random.Random) -> Inst:
    """Swings, a slide, a seesaw and a sand floor — the smallest residents are loud here."""
    m = model(parent, "Playground", base)
    part(m, "Floor", (30.0, 0.3, 26.0), base * CF(0, 0.15, 0), (222, 196, 140), "Sand",
         collide=False, shadow=False)
    sw = base * CF(-9, 0, -5.5) * CF.deg(0, 20, 0)
    part(m, "SwingTop", (8.0, 0.4, 0.4), sw * CF(0, 6.0, 0), (70, 74, 78), "Metal")
    for sx in (-3.8, 3.8):
        part(m, "SwingLeg", (0.35, 6.4, 0.35), sw * CF(sx, 2.9, -1.0) * CF.deg(12, 0, 0), (70, 74, 78), "Metal")
        part(m, "SwingLeg", (0.35, 6.4, 0.35), sw * CF(sx, 2.9, 1.0) * CF.deg(-12, 0, 0), (70, 74, 78), "Metal")
    for sx in (-1.9, 1.9):
        part(m, "Chain", (0.12, 3.4, 0.12), sw * CF(sx, 4.3, 0), (150, 150, 150), "Metal", collide=False)
        part(m, "Seat", (1.6, 0.25, 0.8), sw * CF(sx, 2.5, 0), (96, 70, 52), "Wood", collide=False)
    sl = base * CF(8.5, 0, -5) * CF.deg(0, -35, 0)
    part(m, "SlideTop", (3.0, 0.3, 3.0), sl * CF(0, 4.6, 0), (220, 90, 60))
    part(m, "SlideRamp", (2.0, 0.3, 7.6), sl * CF(0, 2.6, -4.7) * CF.deg(-32, 0, 0), (230, 200, 80),
         collide=False)
    for sx in (-1.3, 1.3):
        part(m, "SlideLeg", (0.35, 4.6, 0.35), sl * CF(sx, 2.3, 1.3), (70, 74, 78), "Metal")
    part(m, "Ladder", (1.8, 5.0, 0.3), sl * CF(0, 2.5, 2.2) * CF.deg(14, 0, 0), (70, 74, 78), "Metal")
    ss = base * CF(0, 0, 8.5) * CF.deg(0, 75, 0)
    part(m, "Pivot", (1.0, 1.4, 1.0), ss * CF(0, 0.7, 0), (70, 74, 78), "Metal")
    part(m, "Plank", (7.0, 0.3, 1.0), ss * CF(0, 1.5, 0) * CF.deg(0, 0, 8), (200, 70, 60))
    bench(m, base * CF(11, 0, 9) * CF.deg(0, -115, 0))
    if rng.random() < 0.8:
        pedestrian(m, base * CF(9.2, 0, 7.8) * CF.deg(0, rng.uniform(0, 360), 0), rng)
    return m


def pocket_park(parent: Inst, base: CF, rng: random.Random, w: float, d: float) -> Inst:
    """Grass, trees and benches — the pocket parks the towers look down on."""
    m = model(parent, "Park", base)
    part(m, "Lawn", (w, 0.16, d), base * CF(0, 0.08, 0), (104, 186, 86), "Grass",
         collide=False, shadow=False)
    part(m, "Path", (w * 0.94, 0.2, 3.0), base * CF(0, 0.1, 0), (186, 176, 160), "Pavement",
         collide=False, shadow=False)
    for _ in range(rng.randint(3, 5)):
        tree(m, base * CF(rng.uniform(-w / 2 + 5, w / 2 - 5), 0,
                          rng.choice((-1, 1)) * rng.uniform(4.5, d / 2 - 4)), rng.uniform(0.85, 1.25),
             "pine" if rng.random() < 0.4 else "round")
    for i in range(3):
        bush(m, base * CF(rng.uniform(-w / 2 + 3, w / 2 - 3), 0, rng.uniform(-d / 2 + 3, d / 2 - 3)),
             rng.uniform(2.0, 3.2), LEAF_DARK if i % 2 else LEAF)
    for sx in (-0.28, 0.28):
        bench(m, base * CF(sx * w, 0, 3.6) * CF.deg(0, 180, 0))
    if rng.random() < 0.85:
        pedestrian(m, base * CF(rng.uniform(-w / 4, w / 4), 0, 0) * CF.deg(0, rng.uniform(0, 360), 0), rng)
    return m


def pocket_plaza(parent: Inst, base: CF, rng: random.Random, w: float, d: float) -> Inst:
    """A paved square with a fountain, benches, hedges and somebody daydreaming by the water."""
    m = model(parent, "Plaza", base)
    part(m, "Paving", (w, 0.24, d), base * CF(0, 0.12, 0), (172, 164, 152), "Pavement",
         collide=False, shadow=False)
    fountain(m, base)
    for sx, sz, yawd in ((-1, -1, 30), (1, -1, -30), (-1, 1, 150), (1, 1, 210)):
        bench(m, base * CF(sx * w * 0.3, 0, sz * d * 0.3) * CF.deg(0, yawd, 0))
    for hx in (-w / 2 + 2.5, w / 2 - 2.5):
        part(m, "Hedge", (3.0, 2.2, d - 5), base * CF(hx, 1.1, 0), LEAF_DARK, "LeafyGrass")
    if rng.random() < 0.8:
        pedestrian(m, base * CF(rng.uniform(-4, 4), 0, rng.uniform(5, 8)) * CF.deg(0, rng.uniform(0, 360), 0), rng)
    return m


def carpark(parent: Inst, base: CF, rng: random.Random, w: float, d: float) -> Inst:
    """A neighbourhood car park: pad, painted bays, a pay meter, a few parked runabouts."""
    m = model(parent, "CarPark", base)
    part(m, "Pad", (w, 0.3, d), base * CF(0, 0.15, 0), (66, 68, 72), "Asphalt")
    n = max(2, int(w // 6.4))
    for i in range(n + 1):
        bx = -w / 2 + 2 + i * (w - 4) / n
        part(m, "BayLine", (0.3, 0.06, d * 0.6), base * CF(bx, 0.33, -d * 0.14), (230, 230, 230),
             "SmoothPlastic", collide=False, shadow=False)
    for i in range(n):
        if rng.random() < 0.55:
            bx = -w / 2 + 2 + (i + 0.5) * (w - 4) / n
            simple_car(m, base * CF(bx, 0.3, -d * 0.14) * CF.deg(0, 90 + rng.uniform(-4, 4), 0), rng)
    part(m, "MeterPost", (0.4, 3.0, 0.4), base * CF(w / 2 - 2.0, 1.5, d / 2 - 2.0), (70, 74, 78), "Metal")
    part(m, "MeterHead", (1.0, 1.2, 0.8), base * CF(w / 2 - 2.0, 3.6, d / 2 - 2.0), (60, 100, 190), "Metal")
    return m


def terrace_court(parent: Inst, rng: random.Random, x: float, z: float, yaw: float, w: float):
    """A short terrace of townhouses behind hedged front gardens, facing the street."""
    frame = CF(x, 0, 0 + z) * CF.deg(0, yaw, 0)
    m = model(parent, "Terrace", frame)
    n = 3 if w >= 62 else 2
    tw = w / n - 1.5
    for i in range(n):
        lx = -w / 2 + (i + 0.5) * (w / n)
        wx, wz = _yaw_point(x, z, yaw, lx, 0)
        facade(parent, rng, wx, wz, yaw, tw, rng.randint(2, 3))
        part(m, "Hedge", (tw - 2, 1.8, 1.6), frame * CF(lx, 0.9, -9.2), LEAF_DARK, "LeafyGrass")
        part(m, "Path", (3.0, 0.2, 7.4), frame * CF(lx, 0.1, -5.1), (186, 176, 160), "Pavement",
             collide=False, shadow=False)
        if rng.random() < 0.35:
            bush(m, frame * CF(lx + tw / 2 - 2.2, 0, -7.6), 2.2, LEAF)
    return m


def tower_plot(parent: Inst, rng: random.Random, x: float, z: float, yaw: float, w: float, d: float,
               zone: str):
    """An office tower set back behind a planted forecourt: the taller the zone, the
    taller the tower — downtown scrapes, oldtown just peeks over the rooftops."""
    frame = CF(x, 0, z) * CF.deg(0, yaw, 0)
    m = model(parent, "TowerPlot", frame)
    floors = {"oldtown": rng.randint(5, 8), "midtown": rng.randint(8, 13),
              "downtown": rng.randint(11, 18)}[zone]
    towers = [(0.0, floors)]
    if zone == "downtown" and d > 130:
        # deep blocks take a slab pair stepping back: a back tower behind the front one
        towers = [(0.0, floors), (d * 0.34, rng.randint(9, 16))]
    for tz_off, tfloors in towers:
        face_lz = -d / 2 + 16 + tz_off
        wx, wz = _yaw_point(x, z, yaw, 0, face_lz)
        facade(parent, rng, wx, wz, yaw, min(w * 0.55, 40.0), tfloors, "tower")
    face_lz = -d / 2 + 16
    part(m, "Forecourt", (w * 0.8, 0.2, 12.0), frame * CF(0, 0.1, face_lz - 7), (186, 176, 160),
         "Pavement", collide=False, shadow=False)
    planter(m, frame * CF(-w * 0.3, 0, face_lz - 6), rng)
    planter(m, frame * CF(w * 0.3, 0, face_lz - 6), rng)
    bench(m, frame * CF(0, 0, face_lz - 10.4))
    if rng.random() < 0.6:
        pedestrian(m, frame * CF(rng.uniform(-6, 6), 0, face_lz - 4.6) * CF.deg(0, rng.uniform(0, 360), 0),
                   rng)
    return m


def courtyard_court(parent: Inst, rng: random.Random, x: float, z: float, yaw: float, w: float,
                    d: float):
    """The perimeter-block filler: two rows of wide, shallow flats built wall-to-wall, facing
    each other across a paved court with washing lines and dustbins — the rectangle-in-depth
    that makes the middle of every block built-up rather than lawn."""
    frame = CF(x, 0, z) * CF.deg(0, yaw, 0)
    m = model(parent, "Courtyard", frame)
    part(m, "Court", (w * 0.96, 0.16, d * 0.9), frame * CF(0, 0.08, 0), (150, 144, 134),
         "Pavement", collide=False, shadow=False)
    n = max(2, int(w // 26))
    step = w / n
    for side in (-1, 1):
        # each row hugs one end of the plot, its fronts facing the shared court
        row_z = side * (d / 2 - 10)
        row_yaw = 180 if side < 0 else 0
        ryaw = yaw + row_yaw
        floors = 3 if (w * d) < 7000 else rng.randint(3, 5)
        for i in range(n):
            lx = -w / 2 + (i + 0.5) * step
            wx, wz = _yaw_point(x, z, yaw, lx, row_z)
            facade(parent, rng, wx, wz, ryaw, step - 1.6, floors)
    # Court life: a couple of bins and a dustbin corral, a washing line or two.
    for i in range(rng.randint(1, 2)):
        lx = rng.uniform(-w / 2 + 6, w / 2 - 6)
        lz = rng.uniform(-d * 0.22, d * 0.22)
        part(m, "Bin", (1.3, 1.8, 1.3), frame * CF(lx, 0.9, lz), (70, 74, 78), "Metal",
             shape="Cylinder")
    dx, dzc = _yaw_point(x, z, yaw, -w / 3, 0)
    dump = model(m, "Skip", frame * CF(-w / 2 + 4.4, 0, 0))
    part(dump, "Body", (5.0, 2.2, 2.6), frame * CF(-w / 2 + 4.4, 1.1, 0), (52, 96, 64), "Metal")
    part(dump, "Lid", (5.2, 0.3, 2.8), frame * CF(-w / 2 + 4.4, 2.35, 0) * CF.deg(-8, 0, 0),
         (60, 108, 72), "Metal", collide=False)
    for c in range(rng.randint(1, 2)):
        lx = rng.uniform(-w / 4, w / 4)
        lz = rng.uniform(-d * 0.16, d * 0.16)
        for sx in (-3.0, 3.0):
            part(m, "LinePost", (0.18, 4.4, 0.18), frame * CF(lx + sx, 2.2, lz), (70, 74, 78),
                 "Metal", collide=False)
        part(m, "Line", (6.0, 0.05, 0.05), frame * CF(lx, 4.3, lz), (200, 200, 200), collide=False)
        for cloth in range(3):
            part(m, "Washing", (1.1, 1.5, 0.08), frame * CF(lx - 2 + cloth * 2, 3.5, lz),
                 rng.choice(SHIRT_COLORS), "Fabric", collide=False)
    if rng.random() < 0.5:
        pedestrian(m, frame * CF(rng.uniform(-6, 6), 0, 0) * CF.deg(0, rng.uniform(0, 360), 0), rng)
    return m


def build_city_blocks(folder: Inst, city: dict, named_xs: list[float]):
    """Pack every block interior with a life of its own — plazas, pocket parks, car parks,
    townhouse terraces, playgrounds and tower plots — so no grid square is an empty lawn
    between the facades. Cells stay clear of the cross-street mouths, the avenue mouths and
    every house lot."""
    rng = random.Random(CITY_SEED + 17)
    jxs = [j["x"] for j in city["junctions"]]
    houses = city["houses"]
    bounds = [city["corridor_end"] + 60] + jxs + [AVENUE_X1 - 20]
    bands = ((-279.0, -64.0), (64.0, 279.0), (-603.0, -382.0), (382.0, 603.0))
    w_ranges = {"park": (30, 64), "plaza": (34, 66), "carpark": (36, 64), "terrace": (44, 74),
                "playground": (36, 54), "tower": (52, 90), "courtyard": (54, 98)}
    min_w = {"park": 26, "plaza": 30, "carpark": 34, "terrace": 42, "playground": 36, "tower": 50,
             "courtyard": 52}

    def clear_of_lots(tx: float, tz: float, half: float) -> bool:
        for ch in houses:
            lot_w, lot_d = city_lot(ch["kind"])
            if abs(tx - ch["x"]) < lot_w / 2 + half + 6 and abs(tz - ch["z"]) < lot_d / 2 + half + 6:
                return False
        for cx in named_xs:
            if abs(tx - cx) < LOT_W / 2 + half + 6 and abs(tz) < LOT_D + half:
                return False
        return True

    def pick(zone: str) -> str:
        r = rng.random()
        if zone == "oldtown":
            table = ((0.18, "park"), (0.40, "terrace"), (0.62, "courtyard"), (0.72, "playground"),
                     (0.84, "plaza"), (0.92, "carpark"), (1.01, "tower"))
        elif zone == "midtown":
            table = ((0.28, "courtyard"), (0.44, "carpark"), (0.58, "tower"), (0.70, "plaza"),
                     (0.80, "park"), (0.90, "terrace"), (1.01, "playground"))
        else:
            table = ((0.50, "tower"), (0.62, "courtyard"), (0.78, "carpark"), (0.88, "plaza"),
                     (0.94, "park"), (1.01, "terrace"))
        for p, k in table:
            if r < p:
                return k
        return "park"

    for a, b in zip(bounds, bounds[1:]):
        x0, x1 = a + 118.0, b - 118.0
        if x1 - x0 < 50:
            continue
        zone = city_zone((a + b) / 2)
        for z0, z1 in bands:
            depth = z1 - z0
            if depth < 40:
                continue
            cx = x0
            while x1 - cx > 24:
                cx += rng.uniform(4, 10)  # a paved alley between one building and the next
                if rng.random() < 0.05:
                    continue  # the odd pocket left open as a paved court
                kind = pick(zone)
                lo, hi = w_ranges[kind]
                w = min(rng.uniform(lo, hi), x1 - cx)
                if w < min_w[kind]:
                    kind = "park" if w >= min_w["park"] else None
                if kind is None:
                    break
                mx = cx + w / 2
                mz = (z0 + z1) / 2 + rng.uniform(-4, 4)
                p_depths = {"park": depth - 10, "plaza": min(depth - 10, 84),
                            "carpark": min(depth - 10, 160), "terrace": 46.0, "playground": 34.0,
                            "courtyard": min(depth - 8, 170), "tower": min(depth - 12, 150)}
                pd = p_depths[kind]
                yaw = 0.0 if mz > 0 else 180.0  # face the street nearer the city centreline
                if clear_of_lots(mx, mz, max(w, pd) / 2 + 3):
                    bcf = CF(mx, 0, mz) * CF.deg(0, yaw, 0)
                    if kind == "park":
                        pocket_park(folder, bcf, rng, w * 0.94, pd)
                    elif kind == "plaza":
                        pocket_plaza(folder, bcf, rng, w * 0.92, pd)
                    elif kind == "carpark":
                        carpark(folder, bcf, rng, w * 0.92, pd)
                    elif kind == "playground":
                        playground(folder, bcf, rng)
                    elif kind == "terrace":
                        fx, fz = _yaw_point(mx, mz, yaw, 0, -12)
                        terrace_court(folder, rng, fx, fz, yaw, w * 0.94)
                    elif kind == "courtyard":
                        courtyard_court(folder, rng, mx, mz, yaw, w * 0.96, pd)
                    else:
                        tower_plot(folder, rng, mx, mz, yaw, w, pd, zone)
                cx += w


def city_street_furniture(decor: Inst, city: dict, named_xs: list[float]):
    """Dress the main street itself: corner traffic lights and street-name boards, bus
    stops with waiting passengers, benches, planters, hydrants, mailboxes and people out
    for a walk. Everything keeps off the pavements (|z| 16–26), out of the junction turn
    lanes (|x − jx| < 40 while |z| < 31) and clear of the named houses' front yards."""
    rng = random.Random(CITY_SEED + 23)
    jxs = [j["x"] for j in city["junctions"]]

    def clear_any(x: float, z: float) -> bool:
        if abs(z) < 26.5:
            return False
        for jx in jxs:
            if abs(x - jx) < 40 and abs(z) < 31:
                return False
        for cx in named_xs:
            if abs(x - cx) < LOT_W / 2 + 7 and abs(z) < SIDEWALK_EDGE + LOT_D + 8:
                return False
        return True

    # Every junction corner gets its pair of traffic lights and the crossed street boards.
    for j in city["junctions"]:
        jx = j["x"]
        traffic_light(decor, CF(jx - 33, 0, -27.2))
        traffic_light(decor, CF(jx + 33, 0, 27.2))
        street_name_sign(decor, CF(jx + 33, 0, -27.6), j["name"])

    # Bus stops every few junctions, alternating sides of the street.
    for i, j in enumerate(city["junctions"]):
        if i % 3 != 1:
            continue
        side = 1 if i % 2 == 0 else -1
        bx, bz = j["x"] + 58, side * 30.5
        if clear_any(bx, bz):
            bus_stop(decor, CF(bx, 0, bz) * CF.deg(0, 0 if side > 0 else 180, 0), rng)

    # And the verges between junctions fill with benches, planters, street kit and walkers.
    bounds = [city["corridor_end"]] + jxs + [AVENUE_X1]
    for a, b in zip(bounds, bounds[1:]):
        x = a + 54
        while x < b - 54:
            side = rng.choice((-1, 1))
            r = rng.random()
            if r < 0.30:
                vz = side * rng.uniform(28.5, 31.5)
                if clear_any(x, vz):
                    bench(decor, CF(x, 0, vz) * CF.deg(0, 0 if side > 0 else 180, 0))
            elif r < 0.48:
                vz = side * rng.uniform(28.5, 31.5)
                if clear_any(x, vz):
                    planter(decor, CF(x, 0, vz), rng)
            elif r < 0.58:
                if clear_any(x, side * 27.4):
                    hydrant(decor, CF(x, 0, side * 27.4))
            elif r < 0.68:
                if clear_any(x, side * 27.6):
                    mailbox(decor, CF(x, 0, side * 27.6) * CF.deg(0, 180 if side > 0 else 0, 0))
            elif r < 0.95:
                vz = side * rng.uniform(27.8, 30.2)
                if clear_any(x, vz):
                    pedestrian(decor, CF(x, 0, vz) * CF.deg(0, 90 if rng.random() < 0.5 else -90, 0), rng)
            x += rng.uniform(60, 100)


def build_city_paving(ground: Inst, city: dict):
    """The city's own ground: a concrete sheet wall-to-wall under every block and verge, so
    nothing green shows inside the street grid unless a park or garden pad raises grass above
    it. Sits at top 0.06: above the base grass (0.0), below the lot pads (0.1), the asphalt
    (0.2) and the kerbs/pavements (0.3), so it reads as the alley-and-courtyard floor, and a
    defender steps over it without noticing (STEP_UP is 1.4)."""
    x0, x1 = city["corridor_end"], AVENUE_X1 + 46
    z0, z1 = -714.0, 714.0
    for a, b in _span_chunks(x0, x1):
        part(ground, "CityGround", (b - a, 0.12, z1 - z0), CF((a + b) / 2, 0.0, (z0 + z1) / 2),
             (152, 147, 138), "Pavement")


def build_city_cliffs(cliffs: Inst, decor: Inst, city: dict, sides: dict[int, list[float]]):
    """The rock that still holds the city in: behind the named houses, around the far ends of
    the cross streets, up the museum's approach hill and around the city's west and east edges."""
    folder = Inst("Folder", "City", cliffs)
    cliff = CliffBuilder(folder, 7700)
    depth = 88.0
    behind = OUT_D - CLIFF_SETBACK
    for side, xs in sides.items():
        frame = CF(0, 0, side * CLIFF_FACE_Z) * CF.deg(0, 0 if side < 0 else 180, 0)
        flip = -1 if side > 0 else 1

        def local(a, b, flip=flip):
            return (min(a * flip, b * flip), max(a * flip, b * flip))

        for hx in xs:
            cliff.fill(frame, *local(hx - OUT_W / 2, hx + OUT_W / 2), -behind, -depth, (25, 42), None, decor)
    corridor_end = city["corridor_end"]
    # the west wall of the city, from the corridor's shoulders out to the far boundary
    cliff_wall(cliff, decor, (AVENUE_X0 - 30, -(CITY_BOUNDARY_Z + 45) / 2), (1, 0),
                CITY_BOUNDARY_Z - 45, (24, 38), fill_heights=(28, 44), depth=46, trees=decor)
    cliff_wall(cliff, decor, (AVENUE_X0 - 30, (CITY_BOUNDARY_Z + 45) / 2), (1, 0),
                CITY_BOUNDARY_Z - 45, (24, 38), fill_heights=(28, 44), depth=46, trees=decor)
    # the north and south walls that the cross streets dead-end into
    for side in (-1, 1):
        cliff_wall(cliff, decor, ((AVENUE_X0 - 40 + AVENUE_X1 + 120) / 2, side * CITY_BOUNDARY_Z),
                   (0, -side), AVENUE_X1 + 160 - AVENUE_X0, (26, 42), fill_heights=(30, 48), depth=55,
                   rubble=0.08, trees=decor)
    # the museum's approach: canyon walls return for the last stretch of the main street
    for side in (-1, 1):
        cliff_wall(cliff, decor, ((AVENUE_X1 + 58 + ROAD_X1) / 2, side * CLIFF_FACE_Z), (0, -side),
                   ROAD_X1 - AVENUE_X1 - 58, (24, 38), fill_heights=(28, 44), depth=52, rubble=0.1,
                   trees=decor)
    # and the eastern bowl beyond the avenues, joining the approach walls to the museum's cliff
    for side in (-1, 1):
        cliff_wall(cliff, decor, (ROAD_X1 + 46, side * (CITY_BOUNDARY_Z + 178) / 2), (-1, 0),
                   CITY_BOUNDARY_Z - 178, (24, 40), fill_heights=(28, 46), depth=48, trees=decor)


def city_greenery(decor: Inst, city: dict):
    """Street trees at the junction corners, so the grid has some green in it."""
    rng = random.Random(CITY_SEED + 9)
    for j in city["junctions"]:
        for corner in ((-1, 1), (1, -1)):
            tx = j["x"] + 38 * corner[0]
            tz = 23.5 * corner[1]
            tree(decor, CF(tx, 0, tz), rng.uniform(1.0, 1.25), "pine" if rng.random() < 0.4 else "round")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Paint for the guide's ten named houses (in street order) — pastel candy walls and sorbet roofs,
# matching the light UI. "pet" is the colour of the guard's bed.
HOUSE_PALETTES = [
    # 1 Butter — cream-yellow cottage with a coral roof
    {"wall": (250, 240, 194), "roof": (255, 138, 116), "door": (238, 112, 96), "carpet": (248, 206, 176),
     "sofa": (138, 196, 232), "rug": (250, 208, 120), "bed": (255, 168, 182), "bush": LEAF, "accent": (228, 178, 118),
     "pet": (255, 150, 132)},
    # 2 Mint — mint walls with a sky-blue roof
    {"wall": (206, 242, 220), "roof": (118, 194, 238), "door": (96, 158, 228), "carpet": (178, 224, 234),
     "sofa": (255, 182, 158), "rug": (150, 220, 186), "bed": (128, 190, 242), "bush": LEAF, "accent": WOOD,
     "pet": (122, 170, 242)},
    # 3 Pink — strawberry-milk house with a raspberry roof
    {"wall": (255, 218, 226), "roof": (250, 124, 154), "door": (228, 96, 126), "carpet": (255, 190, 204),
     "sofa": (152, 212, 192), "rug": (252, 216, 158), "bed": (255, 152, 176), "bush": LEAF_DARK, "accent": (228, 178, 158),
     "pet": (202, 144, 242)},
    # 4 Lemon — lemon walls with an orange-sorbet roof
    {"wall": (255, 246, 186), "roof": (255, 168, 94), "door": (242, 144, 68), "carpet": (255, 220, 158),
     "sofa": (142, 202, 170), "rug": (202, 178, 238), "bed": (156, 212, 126), "bush": LEAF, "accent": WOOD_DARK,
     "pet": (92, 198, 158)},
    # 5 Sky — bluebell walls with a periwinkle roof
    {"wall": (198, 228, 252), "roof": (152, 166, 242), "door": (122, 142, 228), "carpet": (190, 210, 246),
     "sofa": (255, 176, 142), "rug": (255, 162, 132), "bed": (142, 176, 246), "bush": LEAF, "accent": WOOD,
     "pet": (238, 132, 122)},
    # 6 Cream — vanilla walls with a peach roof
    {"wall": (245, 240, 224), "roof": (255, 184, 142), "door": (250, 142, 152), "carpet": (236, 226, 210),
     "sofa": (176, 162, 232), "rug": (232, 208, 238), "bed": (238, 172, 192), "bush": LEAF, "accent": (176, 122, 82),
     "pet": (252, 172, 92)},
    # 7 Pistachio — soft-green walls with a mint roof
    {"wall": (216, 242, 190), "roof": (112, 216, 182), "door": (74, 186, 152), "carpet": (196, 236, 186),
     "sofa": (242, 192, 216), "rug": (166, 226, 196), "bed": (242, 216, 132), "bush": LEAF, "accent": WOOD,
     "pet": (255, 176, 82)},
    # 8 Toffee — biscuit walls with a lilac roof
    {"wall": (240, 222, 192), "roof": (196, 166, 244), "door": (162, 126, 222), "carpet": (226, 202, 242),
     "sofa": (152, 206, 236), "rug": (212, 176, 228), "bed": (192, 162, 242), "bush": LEAF_DARK, "accent": WOOD_DARK,
     "pet": (152, 122, 238)},
    # 9 Marshmallow — white walls with a cherry roof
    {"wall": (250, 247, 242), "roof": (255, 122, 122), "door": (255, 156, 98), "carpet": (238, 238, 242),
     "sofa": (136, 190, 236), "rug": (252, 202, 152), "bed": (146, 202, 246), "bush": LEAF, "accent": (200, 172, 136),
     "pet": (255, 132, 132)},
    # 10 Cookie — caramel walls with a butterscotch roof
    {"wall": (238, 222, 200), "roof": (242, 160, 92), "door": (206, 120, 72), "carpet": (250, 216, 176),
     "sofa": (236, 136, 156), "rug": (216, 236, 176), "bed": (252, 196, 116), "bush": LEAF, "accent": (152, 104, 62),
     "pet": (238, 146, 86)},
]
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

    # The map is now far wider than the 2,048-stud part limit, so the grass is tiled east to west.
    # It reaches well past the invisible boundary walls so the edge of the world fades out.
    edge = MAP_X0
    while edge < MAP_X1:
        x1 = min(edge + 2048, MAP_X1)
        part(ground, "Grass", (x1 - edge, 4, MAP_Z * 2), CF((edge + x1) / 2, -2, 0), GRASS, "Grass")
        edge = x1

    # Where the guide's named houses stand: they alternate sides of the main street, on the
    # progression schedule (close to the yard at first, the museum last at the very end).
    named_xs = [house_x(i + 1) for i in range(len(street))]
    sides: dict[int, list[float]] = {-1: [], 1: []}
    for i, x in enumerate(named_xs):
        sides[-1 if i % 2 == 0 else 1].append(x)

    # Plan the whole city once (junctions, numbered houses) and publish the street network so the
    # defenders can chase around the corners (see src/server/Houses.luau).
    city = plan_city(named_xs, street)
    map_folder.attr(Lanes=city["lanes"])

    # The yard at the west end of the street: six garages around the spawn parking lot. Each one sits a
    # hair higher than the last so the aprons that overlap in the corners never fight over one plane.
    for index, (x, z, yaw) in enumerate(YARD_PLOTS, start=1):
        build_warehouse(warehouses, ground, index, CF(x, 0.003 * index, z) * CF.deg(0, yaw, 0))
    build_yard(map_folder, ground, decor)
    build_yard_cliffs(cliffs, decor)
    # The canyon joins the yard to the city's west wall.
    build_corridor_cliffs(cliffs, decor, {side: city["corridor_end"] for side in (-1, 1)})

    entrances: list[tuple[float, float]] = []
    for i, info in enumerate(street):
        x = named_xs[i]
        side = -1 if i % 2 == 0 else 1
        lot_cf = CF(x, 0, side * (SIDEWALK_EDGE + LOT_D / 2)) * CF.deg(0, 0 if side < 0 else 180, 0)
        build_house(houses, info, tiers[info["tier"] - 1], lot_cf, HOUSE_PALETTES[i % len(HOUSE_PALETTES)])
        entrances.append((x, 6))

    # The numbered city houses fill the grid between them.
    for ch in city["houses"]:
        build_city_house(houses, ch)

    # The Mansion (the town's museum) at the end of the street, its front facing the road
    mansion_cf = CF(MANSION_X, 0, 0) * CF.deg(0, -90, 0)
    build_mansion(houses, mansion, tiers[3], mansion_cf)
    build_mansion_cliff(cliffs, decor, mansion_cf)

    build_city_paving(ground, city)
    build_city_roads(ground, decor, city, entrances)
    build_city_fill(map_folder, city, named_xs)
    build_city_cliffs(cliffs, decor, city, sides)
    city_greenery(decor, city)
    city_street_furniture(decor, city, named_xs)
    road_sign(decor, -30, -23, "DOWNTOWN & MUSEUM ➜", 0)
    road_sign(decor, -170, 23, "⬅ YOUR GARAGE", 0)
    road_sign(decor, house_x(1) - 64, -23, "MAPLE COTTAGE ➜ START HERE", 0)
    build_boundary(map_folder, decor)

    # Street trees on the grass between the yard and the city
    for x in (-170.0, -110.0):
        for z in (-34.0, 34.0):
            tree(decor, CF(x, 0, z), 1.1)
    return map_folder
