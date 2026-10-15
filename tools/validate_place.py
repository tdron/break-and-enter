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
    for folder in ("Ground", "Houses", "Warehouses", "Shop", "Hub", "Decor"):
        check.expect(game_map.child(folder) is not None, f"Map.{folder} is missing")

    # Houses
    houses = game_map.child("Houses")
    tiers = {}
    total_spots = 0
    if houses:
        for house in houses.children:
            attrs = house.attributes()
            tier = attrs.get("Tier")
            check.expect(isinstance(tier, float) and 1 <= tier <= 4, f"{house.path()} has bad Tier attribute")
            check.expect(isinstance(attrs.get("DisplayName"), str), f"{house.path()} has no DisplayName")
            tiers[int(tier or 0)] = tiers.get(int(tier or 0), 0) + 1
            zone = house.child("Zone")
            check.expect(zone is not None and zone.cls == "Part", f"{house.path()} has no Zone part")
            spots = house.child("ItemSpots")
            count = len(spots.children) if spots else 0
            total_spots += count
            check.expect(count >= 4, f"{house.path()} has only {count} item spots")
            docks = house.child("DroneDocks")
            check.expect(docks is not None and len(docks.children) >= 1, f"{house.path()} has no drone docks")
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

    # Warehouses
    warehouses = game_map.child("Warehouses")
    plots = warehouses.children if warehouses else []
    check.expect(len(plots) == 6, f"Expected 6 warehouses, found {len(plots)}")
    for plot in plots:
        attrs = plot.attributes()
        check.expect(isinstance(attrs.get("PlotIndex"), float), f"{plot.path()} has no PlotIndex")
        for name, cls in (("Spawn", "SpawnLocation"), ("DepositPad", "Part"), ("Dock", "Part"), ("CarSpawn", "Part"),
                          ("Marker", "Part")):
            child = plot.child(name)
            check.expect(child is not None and child.cls == cls, f"{plot.path()}.{name} ({cls}) is missing")
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

    # Shop & hub
    check.expect(game_map.child("Gym") is None, "Map.Gym is obsolete (treadmills live at the warehouses now)")
    check.expect(any(d.name == "ShopCounter" for d in game_map.walk()), "No ShopCounter part")
    check.expect(any(d.name == "HubSpawn" and d.cls == "SpawnLocation" for d in game_map.walk()), "No HubSpawn")

    # Remotes and scripts
    replicated = services.get("ReplicatedStorage")
    remotes = replicated.child("Remotes") if replicated else None
    found = {(c.name, c.cls) for c in (remotes.children if remotes else [])}
    for expected in (("Notify", "RemoteEvent"), ("Busted", "RemoteEvent"), ("Purchase", "RemoteFunction"),
                     ("SpawnCar", "RemoteFunction"), ("Treadmill", "RemoteFunction")):
        check.expect(expected in found, f"Missing remote {expected}")
    shared = replicated.child("Shared") if replicated else None
    check.expect(shared is not None and {"Config", "Items", "ItemModels", "Format"} <= {c.name for c in shared.children},
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

    print(f"  houses by tier: {dict(sorted(tiers.items()))}, total loot spots: {total_spots}")


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
