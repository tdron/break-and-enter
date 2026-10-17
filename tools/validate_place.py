#!/usr/bin/env python3
"""
Validates StealAnItem.rbxlx.

1. Structural checks (always): the XML parses, referents are unique, every Ref
   points at a real instance, and everything the game scripts look for exists
   (houses, zones, item spots, doors with hinges, 6 warehouses with 50 slots,
   treadmills with belts, the shop counter, the hub spawn, remotes, scripts).

2. API checks (when a reflection database is available): every class,
   property name, XML value type and enum value is checked against Rojo's
   rbx-dom reflection database (the same data Rojo uses to write place files).

    python3 tools/validate_place.py [--database path/to/database.json]

Download the database from
https://github.com/rojo-rbx/rbx-dom/blob/master/rbx_dom_lua/src/database.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# XML tag -> acceptable reflection data types
TAG_TYPES = {
    "bool": {"Bool"},
    "float": {"Float32"},
    "double": {"Float64"},
    "int": {"Int32"},
    "int64": {"Int64"},
    "string": {"String"},
    "token": {"Enum"},
    "Vector3": {"Vector3"},
    "Vector2": {"Vector2"},
    "Color3": {"Color3"},
    "Color3uint8": {"Color3", "Color3uint8"},
    "CoordinateFrame": {"CFrame"},
    "OptionalCoordinateFrame": {"OptionalCFrame"},
    "UDim2": {"UDim2"},
    "Font": {"Font"},
    "Ref": {"Ref"},
    "ProtectedString": {"String", "ProtectedString"},
    "BinaryString": {"BinaryString", "Attributes", "Tags"},
    "Content": {"Content", "ContentId"},
}


SINGLETON_CONTAINERS = {"StarterPlayerScripts", "StarterCharacterScripts"}


class Item:
    def __init__(self, element: ET.Element, parent: "Item | None"):
        self.element = element
        self.cls = element.get("class", "")
        self.referent = element.get("referent", "")
        self.parent = parent
        self.props: dict[str, ET.Element] = {}
        props = element.find("Properties")
        if props is not None:
            for prop in props:
                self.props[prop.get("name", "")] = prop
        self.children = [Item(child, self) for child in element.findall("Item")]

    @property
    def name(self) -> str:
        prop = self.props.get("Name")
        return prop.text or "" if prop is not None else ""

    def child(self, name: str) -> "Item | None":
        for c in self.children:
            if c.name == name:
                return c
        return None

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def path(self) -> str:
        parts = []
        node: Item | None = self
        while node:
            parts.append(node.name or node.cls)
            node = node.parent
        return ".".join(reversed(parts))

    def attributes(self) -> dict:
        import base64
        import struct
        prop = self.props.get("AttributesSerialize")
        if prop is None or not (prop.text or "").strip():
            return {}
        data = base64.b64decode(prop.text)
        count = struct.unpack_from("<I", data, 0)[0]
        offset = 4
        result = {}
        for _ in range(count):
            length = struct.unpack_from("<I", data, offset)[0]
            offset += 4
            key = data[offset:offset + length].decode()
            offset += length
            kind = data[offset]
            offset += 1
            if kind == 0x02:
                n = struct.unpack_from("<I", data, offset)[0]
                offset += 4
                result[key] = data[offset:offset + n].decode()
                offset += n
            elif kind == 0x03:
                result[key] = bool(data[offset])
                offset += 1
            elif kind == 0x06:
                result[key] = struct.unpack_from("<d", data, offset)[0]
                offset += 8
            elif kind in (0x0F, 0x11):
                result[key] = struct.unpack_from("<fff", data, offset)
                offset += 12
            else:
                raise ValueError(f"unexpected attribute type {kind:#x}")
        if offset != len(data):
            raise ValueError("attribute blob has trailing bytes")
        return result


def vector3(prop: ET.Element) -> tuple[float, float, float]:
    return tuple(float(prop.findtext(axis) or 0) for axis in ("X", "Y", "Z"))  # type: ignore[return-value]


def cframe_position(item: "Item") -> tuple[float, float, float] | None:
    """A part's CFrame, or a model's WorldPivot (which is how models are placed in the map builder)."""
    prop = item.props.get("CFrame")
    if prop is None:
        pivot = item.props.get("WorldPivotData")
        prop = pivot.find("CFrame") if pivot is not None else None
    return vector3(prop) if prop is not None else None


class Checker:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def expect(self, condition: bool, message: str) -> None:
        if not condition:
            self.error(message)


def check_structure(roots: list[Item], check: Checker) -> None:
    referents = {}
    for root in roots:
        for item in root.walk():
            if item.referent in referents:
                check.error(f"Duplicate referent {item.referent}")
            referents[item.referent] = item
            try:
                item.attributes()
            except Exception as exc:  # noqa: BLE001
                check.error(f"{item.path()}: bad AttributesSerialize ({exc})")
    for root in roots:
        for item in root.walk():
            for name, prop in item.props.items():
                if prop.tag == "Ref" and (prop.text or "null") != "null" and prop.text not in referents:
                    check.error(f"{item.path()}.{name} points at missing referent {prop.text}")

    services = {r.cls: r for r in roots}
    for service in ("Workspace", "ReplicatedStorage", "ServerScriptService", "StarterPlayer", "Lighting"):
        check.expect(service in services, f"Missing service {service}")
    workspace = services.get("Workspace")
    if workspace is None:
        return
    streaming = workspace.props.get("StreamingEnabled")
    check.expect(streaming is not None and streaming.text == "false", "Workspace.StreamingEnabled should be false")

    game_map = workspace.child("Map")
    check.expect(game_map is not None, "Workspace.Map is missing")
    if game_map is None:
        return
    for folder in ("Ground", "Houses", "Warehouses", "Shop", "SellPoint", "Hub", "Decor", "Cliffs"):
        check.expect(game_map.child(folder) is not None, f"Map.{folder} is missing")

    # Houses: one model per Config.Houses entry, named after its id, plus the numbered city houses
    # the city plan (deterministically) places between them.
    import map_builder
    houses_cfg = map_builder.read_houses()
    named_list = houses_cfg[:-1]  # everything before the Mansion
    named_xs = [map_builder.house_x(i + 1) for i in range(len(named_list))]
    city_plan = map_builder.plan_city(named_xs, named_list)
    city_by_id = {ch["id"]: ch for ch in city_plan["houses"]}
    expected_houses = {h["id"]: h for h in houses_cfg}
    houses = game_map.child("Houses")
    tiers = {}
    total_spots = 0
    total_guards = 0
    if houses:
        names = {h.name for h in houses.children}
        expected_names = set(expected_houses) | set(city_by_id)
        check.expect(names == expected_names,
                     f"Map.Houses should be the named houses plus the city plan: "
                     f"missing {sorted(expected_names - names)}, extra {sorted(names - expected_names)}")
        for house in houses.children:
            attrs = house.attributes()
            info = expected_houses.get(house.name)
            if info:
                check.expect(attrs.get("Tier") == info["tier"], f"{house.path()} Tier doesn't match Config.Houses")
                check.expect(attrs.get("DisplayName") == info["display"], f"{house.path()} DisplayName doesn't match")
                check.expect(attrs.get("Guard") == info["guard"]["id"], f"{house.path()} Guard doesn't match")
            else:
                ch = city_by_id.get(house.name)
                if ch is None:
                    continue
                check.expect(attrs.get("DisplayName") == ch["display"],
                             f"{house.path()} DisplayName doesn't match the city plan")
                check.expect(attrs.get("Guard") == ch["guard"]["id"],
                             f"{house.path()} Guard doesn't match the city plan")
                check.expect(attrs.get("Level") == ch["level"] and attrs.get("Tier") == ch["tier"],
                             f"{house.path()} Level/Tier doesn't match the city plan")
                check.expect(attrs.get("LootHouse") == f"House{ch['level']}",
                             f"{house.path()} should loot House{ch['level']}'s table")
            tier = attrs.get("Tier")
            check.expect(isinstance(tier, float) and 1 <= tier <= 4, f"{house.path()} has bad Tier attribute")
            check.expect(isinstance(attrs.get("DisplayName"), str), f"{house.path()} has no DisplayName")
            tiers[int(tier or 0)] = tiers.get(int(tier or 0), 0) + 1
            zone = house.child("Zone")
            check.expect(zone is not None and zone.cls == "Part", f"{house.path()} has no Zone part")
            if zone is not None:
                inset = zone.attributes().get("FrontInset")
                check.expect(isinstance(inset, float) and inset > 0,
                             f"{zone.path()} needs a positive FrontInset (where the front wall sits)")
            spots = house.child("ItemSpots")
            count = len(spots.children) if spots else 0
            total_spots += count
            check.expect(count == map_builder.HOUSE_SPOTS,
                         f"{house.path()} should put {map_builder.HOUSE_SPOTS} items out, has {count} spots")
            docks = house.child("GuardDocks")
            check.expect(docks is not None and len(docks.children) >= 1, f"{house.path()} has no guard docks")
            check.expect(house.child("DroneDocks") is None, f"{house.path()} still has an old DroneDocks folder")
            if docks is not None and info:
                check.expect(len(docks.children) == info["count"],
                             f"{house.path()} should have {info['count']} guard post(s), has {len(docks.children)}")
            total_guards += len(docks.children) if docks else 0
            doors = house.child("Doors")
            check.expect(doors is not None and len(doors.children) >= 1, f"{house.path()} has no doors")
            for door in doors.children if doors else []:
                check.expect(door.child("Hinge") is not None, f"{door.path()} has no Hinge")
                check.expect("OpenAngle" in door.attributes(), f"{door.path()} has no OpenAngle attribute")
            sirens = house.child("Sirens")
            check.expect(sirens is not None and len(sirens.children) >= 1, f"{house.path()} has no sirens")
            lasers = house.child("Lasers")
            for laser in lasers.children if lasers else []:
                check.expect("Phase" in laser.attributes(), f"{laser.path()} has no Phase attribute")
    check.expect(all(tiers.get(t, 0) >= 1 for t in (1, 2, 3, 4)), f"Expected houses of every tier, got {tiers}")

    # The guide's named houses still line the main street, each at its fraction of the trip; the
    # numbered city houses fill the grid, each within the guide's slack of its difficulty level.
    for house in houses.children if houses else []:
        position = cframe_position(house)
        if position is None:
            check.error(f"{house.path()} has no world pivot")
            continue
        named_index = next((i for i, h in enumerate(named_list) if h["id"] == house.name), None)
        if named_index is not None:
            check.expect(abs(position[0] - named_xs[named_index]) < 0.5,
                         f"{house.path()} should stand at x = {named_xs[named_index]:.0f} "
                         f"({(named_index + 1)}/{map_builder.LEVELS} of the trip), it is at {position[0]:.0f}")
            front = abs(position[2]) - map_builder.OUT_D / 2
            check.expect(abs(front - map_builder.HOUSE_FRONT_Z) < 1.5,
                         f"{house.path()} should stand on the main street with its front wall at |z| = "
                         f"{map_builder.HOUSE_FRONT_Z}, it is at {front:.0f}")
            check.expect(abs(position[2]) + map_builder.OUT_D / 2 >= map_builder.CLIFF_FACE_Z,
                         f"{house.path()} does not run back into the cliff")
            continue
        ch = city_by_id.get(house.name)
        if ch is None:  # the Mansion sits on its hill at the end
            check.expect(position[0] > map_builder.ROAD_X1, f"{house.path()} is not past the end of the street")
            check.expect(position[0] > max(named_xs), f"{house.path()} is not the furthest house east")
            continue
        # the model pivot is the house's centre, pushed back from the lot centre by HouseBuilder
        lot_w, lot_d = map_builder.city_lot(ch["kind"])
        plan_w, plan_d = map_builder.CITY_KIND_PLANS[ch["kind"]]
        hz = lot_d / 2 - map_builder.FRONT_YARD - plan_d * map_builder.HOUSE_SCALE / 2
        expect_cf = map_builder.CF(ch["x"], 0, ch["z"]) * map_builder.CF.deg(0, ch["yaw"], 0) * map_builder.CF(0, 0, hz)
        ex, _, ez = expect_cf.p
        check.expect(abs(position[0] - ex) < 0.5 and abs(position[2] - ez) < 0.5,
                     f"{house.path()} is not where the city plan put it")
        check.expect(map_builder.AVENUE_X0 - 200 <= position[0] <= map_builder.ROAD_X1 and
                     abs(position[2]) <= map_builder.CITY_DEPTH + 40,
                     f"{house.path()} stands outside the city ({position[0]:.0f}, {position[2]:.0f})")
        import math as _math
        frac = _math.hypot(position[0] - map_builder.YARD_CX, position[2]) / map_builder.CITY_DIST
        check.expect(abs(frac - ch["level"] / map_builder.LEVELS) <= map_builder.LEVEL_SLACK + 1e-6,
                     f"{house.path()} at {frac * 100:.1f}% of the trip claims level {ch['level']} "
                     f"(allowed within {map_builder.LEVEL_SLACK * 100:.0f}%)")

    # The street network the defenders chase through is published on the Map.
    lanes_attr = game_map.attributes().get("Lanes")
    check.expect(isinstance(lanes_attr, str) and lanes_attr != "", "Map needs a Lanes attribute")
    if isinstance(lanes_attr, str):
        lanes = []
        for seg in lanes_attr.split(";"):
            fields = seg.split(",")
            check.expect(len(fields) == 4 and fields[0] in ("x", "z"), f"Bad lane {seg!r}")
            if len(fields) == 4:
                lanes.append((fields[0], float(fields[1]), float(fields[2]), float(fields[3])))
                check.expect(lanes[-1][2] < lanes[-1][3], f"Lane {seg!r} runs backwards")
        main = [l for l in lanes if l[0] == "x" and l[1] == 0]
        check.expect(len(main) == 1 and main[0][2] <= map_builder.ROAD_X0 + 1 and
                     main[0][3] >= map_builder.ROAD_X1 - 1,
                     "The main street lane should cover the whole trip")
        check.expect(sum(1 for l in lanes if l[0] == "z") == len(city_plan["junctions"]),
                     "Every cross street needs a lane")

    cliffs = game_map.child("Cliffs")
    for folder in ("City", "Mansion", "Yard", "Corridor"):
        check.expect(cliffs is not None and cliffs.child(folder) is not None, f"Map.Cliffs.{folder} is missing")
    rocks = [d for d in cliffs.walk() if d.name == "Rock"] if cliffs else []
    rock_sizes = [vector3(r.props["size"]) for r in rocks if "size" in r.props]
    sizes = {round(x, 1) for x, _, _ in rock_sizes}
    check.expect(len(rocks) > 100 and len(sizes) > 20, f"The cliffs should be lots of different-sized cubes "
                                                         f"({len(rocks)} rocks, {len(sizes)} sizes)")
    check.expect(all(abs(x - y) < 1e-3 and abs(x - z) < 1e-3 for x, y, z in rock_sizes),
                 "Every cliff rock should be a cube")
    check.expect(game_map.child("Decor") is None or all(d.name != "Park" for d in game_map.child("Decor").children),
                 "The old park should be gone (the street runs up to the Mansion now)")

    safe_x = game_map.attributes().get("SafeX")
    check.expect(isinstance(safe_x, float) and safe_x < 0,
                 "Map needs a SafeX attribute (west of it, chases are over)")

    # The getaway car is gone: no car folder, no car spawns on any plot.
    check.expect(workspace.child("Cars") is None, "Workspace.Cars should be gone (there is no getaway car)")

    # Warehouses
    warehouses = game_map.child("Warehouses")
    plots = warehouses.children if warehouses else []
    check.expect(len(plots) == 6, f"Expected 6 warehouses, found {len(plots)}")
    for plot in plots:
        attrs = plot.attributes()
        check.expect(isinstance(attrs.get("PlotIndex"), float), f"{plot.path()} has no PlotIndex")
        for name, cls in (("Spawn", "SpawnLocation"), ("DepositPad", "Part"), ("Dock", "Part"),
                          ("Marker", "Part")):
            child = plot.child(name)
            check.expect(child is not None and child.cls == cls, f"{plot.path()}.{name} ({cls}) is missing")
        check.expect(plot.child("CarSpawn") is None, f"{plot.path()} still has a CarSpawn marker")
        slots = plot.child("Slots")
        indices = sorted(int(s.attributes().get("Index", 0)) for s in (slots.children if slots else []))
        check.expect(indices == list(range(1, 51)), f"{plot.path()} slots should be indexed 1..50")
        labels = {d.name for d in plot.walk() if d.cls == "TextLabel"}
        check.expect({"OwnerText", "StatsText"} <= labels, f"{plot.path()} is missing OwnerText/StatsText labels")
        treadmill = plot.child("Treadmill")
        check.expect(treadmill is not None and treadmill.cls == "Model", f"{plot.path()} has no Treadmill model")
        if treadmill is not None:
            for name in ("Belt", "RunPoint", "ExitPoint", "Console"):
                child = treadmill.child(name)
                check.expect(child is not None and child.cls == "Part", f"{treadmill.path()}.{name} (Part) is missing")
            treadmill_labels = {d.name for d in treadmill.walk() if d.cls == "TextLabel"}
            check.expect({"TreadmillText", "TreadmillOwnerText"} <= treadmill_labels,
                         f"{treadmill.path()} is missing its console labels")
            check.expect(any(c.name.startswith("Accent") for c in treadmill.children),
                         f"{treadmill.path()} has no Accent parts to show its level")

    # The yard: the garages ring the parking lot in a U, and every one of them faces into it
    rows = {"north": 0, "west": 0, "south": 0}
    for plot in plots:
        position = cframe_position(plot)
        if position is None:
            check.error(f"{plot.path()} has no CFrame")
            continue
        x, z = position[0], position[2]
        check.expect(map_builder.YARD_FACE_X - 2 <= x <= map_builder.YARD_MOUTH_X + 2 and
                     abs(z) <= map_builder.YARD_FACE_Z + 2,
                     f"{plot.path()} is not inside the yard ({x:.0f}, {z:.0f})")
        if z < -map_builder.YARD_HALF_D:
            rows["north"] += 1
        elif z > map_builder.YARD_HALF_D:
            rows["south"] += 1
        elif x < map_builder.YARD_ROW_X + map_builder.GARAGE_HALF:
            rows["west"] += 1
    check.expect(rows == {"north": 2, "west": 2, "south": 2},
                 f"The garages should be two on each of the U's sides, got {rows}")

    # The upgrade shop and the trader's sell point stand back to back in the middle of the lot
    stall_positions = []
    for name in ("Shop", "SellPoint"):
        stall = game_map.child(name)
        check.expect(stall is not None and stall.cls == "Model", f"Map.{name} should be a market stall model")
        if stall is not None:
            position = cframe_position(stall)
            check.expect(position is not None and abs(position[0] - map_builder.YARD_CX) < 30 and abs(position[2]) < 30,
                         f"Map.{name} should stand in the middle of the parking lot")
            stall_positions.append(position)
        counter = "ShopCounter" if name == "Shop" else "SellCounter"
        counter_part = next((d for d in game_map.walk() if d.name == counter), None)
        check.expect(counter_part is not None, f"No {counter} part (the prompt for this stall)")
    if len(stall_positions) == 2 and all(stall_positions):
        gap = ((stall_positions[0][0] - stall_positions[1][0]) ** 2 +
               (stall_positions[0][2] - stall_positions[1][2]) ** 2) ** 0.5
        check.expect(gap < 20, f"The two market stalls should be back to back, they are {gap:.0f} studs apart")

    # Hub spawn: in the drive lane of the lot, between the garages
    hub_spawn = next((d for d in game_map.walk() if d.name == "HubSpawn"), None)
    check.expect(hub_spawn is not None and hub_spawn.cls == "SpawnLocation", "No HubSpawn")
    if hub_spawn is not None:
        position = cframe_position(hub_spawn)
        check.expect(position is not None and abs(position[0] - map_builder.YARD_CX) < map_builder.YARD_HALF_W and
                     abs(position[2]) < map_builder.YARD_HALF_D,
                     "HubSpawn should be in the parking lot")
    check.expect(game_map.child("Gym") is None, "Map.Gym is obsolete (treadmills live at the garages now)")

    # Remotes and scripts
    replicated = services.get("ReplicatedStorage")
    remotes = replicated.child("Remotes") if replicated else None
    found = {(c.name, c.cls) for c in (remotes.children if remotes else [])}
    for expected in (("Notify", "RemoteEvent"), ("Busted", "RemoteEvent"), ("Purchase", "RemoteFunction"),
                     ("Treadmill", "RemoteFunction"), ("Storage", "RemoteFunction"),
                     ("Sell", "RemoteFunction"),
                     ("Rebirth", "RemoteFunction")):
        check.expect(expected in found, f"Missing remote {expected}")
    shared = replicated.child("Shared") if replicated else None
    check.expect(shared is not None and {"Config", "Items", "ItemModels", "Format", "Guards"} <= {c.name for c in shared.children},
                 "ReplicatedStorage.Shared is incomplete")
    sss = services.get("ServerScriptService")
    server = sss.child("Server") if sss else None
    check.expect(server is not None and server.cls == "Script", "ServerScriptService.Server Script missing")
    sp = services.get("StarterPlayer")
    sps = sp.child("StarterPlayerScripts") if sp else None
    client = sps.child("Client") if sps else None
    check.expect(client is not None and client.cls == "LocalScript", "StarterPlayerScripts.Client LocalScript missing")
    for root in roots:
        for item in root.walk():
            if item.cls in ("Script", "LocalScript", "ModuleScript"):
                source = item.props.get("Source")
                check.expect(source is not None and len(source.text or "") > 50, f"{item.path()} has no source")

    print(f"  houses by tier: {dict(sorted(tiers.items()))}, total loot spots: {total_spots}, guards: {total_guards}, "
          f"cliff cubes: {len(rocks)} in {len(sizes)} sizes")


def check_api(roots: list[Item], database: dict, check: Checker) -> None:
    classes = database["Classes"]
    enums = database["Enums"]
    cache: dict[str, dict[str, tuple[str, dict]]] = {}

    def serialized_props(class_name: str) -> dict[str, tuple[str, dict]]:
        if class_name in cache:
            return cache[class_name]
        result: dict[str, tuple[str, dict]] = {}
        current = class_name
        while current:
            info = classes[current]
            for prop_name, prop in info["Properties"].items():
                kind = prop.get("Kind", {})
                canonical = kind.get("Canonical")
                if not canonical:
                    continue
                serialization = canonical.get("Serialization")
                if serialization == "Serializes":
                    result.setdefault(prop_name, (prop_name, prop))
                elif isinstance(serialization, dict) and "SerializesAs" in serialization:
                    result.setdefault(serialization["SerializesAs"], (prop_name, prop))
            current = info.get("Superclass")
        cache[class_name] = result
        return result

    used: dict[str, int] = {}
    for root in roots:
        for item in root.walk():
            used[item.cls] = used.get(item.cls, 0) + 1
            if item.cls not in classes:
                check.error(f"{item.path()}: unknown class {item.cls}")
                continue
            tags = classes[item.cls].get("Tags", [])
            # Singleton containers such as StarterPlayerScripts can't be Instance.new()'d but Studio
            # saves them in every place file, so they're allowed.
            if "NotCreatable" in tags and "Service" not in tags and item.cls not in SINGLETON_CONTAINERS:
                check.error(f"{item.path()}: class {item.cls} is not creatable")
            props = serialized_props(item.cls)
            for name, element in item.props.items():
                if name not in props:
                    check.error(f"{item.path()}: {item.cls} has no serialized property '{name}'")
                    continue
                canonical, prop = props[name]
                data_type = prop["DataType"]
                type_name = data_type.get("Value") or ("Enum" if "Enum" in data_type else "?")
                allowed = TAG_TYPES.get(element.tag)
                if allowed is None:
                    check.error(f"{item.path()}.{name}: unsupported XML type <{element.tag}>")
                elif type_name not in allowed:
                    check.error(f"{item.path()}.{name}: written as <{element.tag}> but the API type is {type_name}")
                if "Enum" in data_type:
                    enum_name = data_type["Enum"]
                    valid = set(enums[enum_name]["items"].values())
                    try:
                        value = int(element.text or "")
                    except ValueError:
                        check.error(f"{item.path()}.{name}: bad enum value {element.text!r}")
                        continue
                    if value not in valid:
                        check.error(f"{item.path()}.{name}: {value} is not a valid {enum_name}")
                if prop.get("Scriptability") == "None" and canonical not in ("Technology",):
                    check.warnings.append(f"{item.cls}.{canonical} is not scriptable (fine in files)")
    print("  classes used: " + ", ".join(f"{k}x{v}" for k, v in sorted(used.items(), key=lambda kv: -kv[1])))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("place", nargs="?", default=os.path.join(ROOT, "StealAnItem.rbxlx"))
    parser.add_argument("--database", default=os.environ.get("RBX_DATABASE"),
                        help="Path to rbx-dom's database.json (enables API checks)")
    args = parser.parse_args()

    tree = ET.parse(args.place)
    document = tree.getroot()
    if document.tag != "roblox" or document.get("version") != "4":
        print("Not a version 4 Roblox XML file")
        return 1
    roots = [Item(element, None) for element in document.findall("Item")]
    check = Checker()
    print(f"Checking {os.path.relpath(args.place, ROOT)} ...")
    check_structure(roots, check)
    if args.database:
        with open(args.database, encoding="utf-8") as handle:
            database = json.load(handle)
        version = ".".join(str(v) for v in database.get("Version", []))
        print(f"  API database version {version}")
        check_api(roots, database, check)
    else:
        print("  (skipping API checks: pass --database to enable them)")

    for warning in sorted(set(check.warnings)):
        print(f"  note: {warning}")
    if check.errors:
        print(f"\n{len(check.errors)} problem(s):")
        for error in check.errors[:200]:
            print(f"  ✗ {error}")
        return 1
    print("All checks passed ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
