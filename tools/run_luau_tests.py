#!/usr/bin/env python3
"""
Runs tests/*.spec.luau against the shared modules using the standalone `luau`
CLI (https://github.com/luau-lang/luau/releases).

The Luau CLI has no Roblox APIs or file access, so this script bundles the
modules into one file together with small mocks of the Roblox datatypes they
use (Vector3, Color3, Enum, Random) and a `script.Parent.X` require shim.

    python3 tools/run_luau_tests.py [--luau path/to/luau]
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
SHARED = os.path.join(ROOT, "src", "shared")

PRELUDE = r'''
-- ===== Roblox datatype mocks ==============================================
local Vector3Meta = {}
Vector3Meta.__index = Vector3Meta
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Meta)
end
Vector3Meta.__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Vector3Meta.__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3Meta.__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end
Vector3Meta.__mul = function(a, b)
	if type(a) == "number" then return v3(b.X * a, b.Y * a, b.Z * a) end
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3Meta.__div = function(a, b)
	if type(b) == "number" then return v3(a.X / b, a.Y / b, a.Z / b) end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3Meta.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3Meta.__tostring = function(a) return string.format("%g, %g, %g", a.X, a.Y, a.Z) end
function Vector3Meta:Min(o) return v3(math.min(self.X, o.X), math.min(self.Y, o.Y), math.min(self.Z, o.Z)) end
function Vector3Meta:Max(o) return v3(math.max(self.X, o.X), math.max(self.Y, o.Y), math.max(self.Z, o.Z)) end
function Vector3Meta:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
Vector3 = { new = v3, zero = v3(0, 0, 0), one = v3(1, 1, 1), yAxis = v3(0, 1, 0) }

Color3 = {
	new = function(r, g, b) return { R = r or 0, G = g or 0, B = b or 0 } end,
	fromRGB = function(r, g, b) return { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 } end,
}

local function enumGroup(groupName)
	return setmetatable({}, { __index = function(_, key) return "Enum." .. groupName .. "." .. key end })
end
Enum = setmetatable({}, { __index = function(t, key) local g = enumGroup(key); rawset(t, key, g); return g end })

-- Deterministic xorshift RNG standing in for Roblox's Random
local RandomMeta = {}
RandomMeta.__index = RandomMeta
function RandomMeta:_next()
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x / 4294967296
end
function RandomMeta:NextNumber(min, max)
	local n = self:_next()
	if min then return min + (max - min) * n end
	return n
end
function RandomMeta:NextInteger(min, max)
	return min + math.floor(self:_next() * (max - min + 1))
end
Random = { new = function(seed) return setmetatable({ state = (seed or 1) % 4294967295 + 1 }, RandomMeta) end }

warn = function(...) print("[warn]", ...) end

-- ===== Module system shim ===================================================
local moduleFactories = {}
local moduleCache = {}
Shared = {}
for _, name in MODULE_NAMES do
	Shared[name] = { __module = name, Name = name }
end
local sharedFolder = setmetatable({}, { __index = Shared })
function require(target)
	local name = type(target) == "table" and target.__module
	assert(name, "require() expects a shared module")
	if moduleCache[name] == nil then
		local script = { Name = name, Parent = sharedFolder }
		moduleCache[name] = moduleFactories[name](script)
	end
	return moduleCache[name]
end
'''


def _lua_str(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _lua_value(value) -> str | None:
    from rbxlx import CF, C3u8, Float, Int, Int64, V3, C3
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(float(value))
    if isinstance(value, str):
        return _lua_str(value)
    if isinstance(value, (Float, Int, Int64)):
        return repr(float(value.value))
    if isinstance(value, V3):
        return f"Vector3.new({value.x!r}, {value.y!r}, {value.z!r})"
    if isinstance(value, CF):
        nums = list(value.p) + [value.r[i][j] for i in range(3) for j in range(3)]
        return "CFrame.new(" + ", ".join(repr(float(n)) for n in nums) + ")"
    if isinstance(value, C3u8):
        return f"Color3.fromRGB({value.r}, {value.g}, {value.b})"
    if isinstance(value, C3):
        return f"Color3.new({value.r!r}, {value.g!r}, {value.b!r})"
    return None


PROP_NAMES = {"size": "Size", "Color3uint8": "Color"}
SKIP_PROPS = {"shape", "Material", "TopSurface", "BottomSurface", "FontFace", "Face", "SizingMode"}


def export_map() -> str:
    """Builds the real map with map_builder and emits Luau that recreates it with RobloxMock instances."""
    import build_place
    roots = build_place.build_datamodel()
    workspace = next(r for r in roots if r.class_name == "Workspace")
    lines = [
        "local N = {}",
        "local function mk(className, name, parent)",
        "\tlocal instance = Mock.newInstance(className)",
        "\tinstance.Name = name",
        "\tinstance.Parent = parent",
        "\treturn instance",
        "end",
    ]
    ids = {}

    def emit(inst, parent_expr):
        index = len(ids) + 1
        ids[id(inst)] = index
        ref = f"N[{index}]"
        lines.append(f"{ref} = mk({_lua_str(inst.class_name)}, {_lua_str(inst.name)}, {parent_expr})")
        for key, value in inst.props.items():
            if key in SKIP_PROPS:
                continue
            if key == "WorldPivotData":
                if value.cf is not None:
                    lines.append(f"{ref}.WorldPivot = {_lua_value(value.cf)}")
                continue
            lua = _lua_value(value)
            if lua is not None:
                lines.append(f"{ref}.{PROP_NAMES.get(key, key)} = {lua}")
        for key, value in inst.attributes.items():
            lua = _lua_value(value)
            if lua is not None:
                lines.append(f"{ref}:SetAttribute({_lua_str(key)}, {lua})")
        for child in inst.children:
            emit(child, ref)

    for child in workspace.children:
        emit(child, "workspace")
    return "\n".join(lines)


def script_factory(var: str, name: str, class_name: str, parent: str, path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    return (f'{var} = mk("{class_name}", "{name}", {parent})\n'
            f'rawset({var}, "_factory", function(script)\n{source}\nend)')


DEFAULT_DATABASE = os.environ.get("RBX_DATABASE", os.path.join(os.path.expanduser("~"), ".tools", "ref", "database.json"))


def property_rules(database_path: str | None) -> str:
    """Luau table of ClassName -> {Property = Scriptability} for every class the game touches.

    With these rules the mock errors on unknown members and read-only writes, just like Roblox."""
    import json
    import re
    if not database_path or not os.path.exists(database_path):
        return "-- (no API database: property validation disabled)"
    with open(database_path, encoding="utf-8") as handle:
        classes = json.load(handle)["Classes"]
    names = set()
    for folder in ("src", "tests"):
        for path in glob.glob(os.path.join(ROOT, folder, "**", "*.luau"), recursive=True):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            names.update(re.findall(r'(?:Instance\.new|UI\.new|Mock\.newInstance|mk)\("([A-Za-z]+)"', text))
    names.update({"Part", "WedgePart", "SpawnLocation", "Model", "Folder", "SurfaceGui", "TextLabel", "Frame",
                  "PointLight", "Workspace", "Players", "Player", "Humanoid", "Camera", "PlayerGui"})
    lines = ["Mock.propertyRules = {"]
    for name in sorted(n for n in names if n in classes):
        rules = {}
        current = name
        while current:
            for prop_name, prop in classes[current]["Properties"].items():
                rules.setdefault(prop_name, prop.get("Scriptability", "ReadWrite"))
            current = classes[current].get("Superclass")
        body = ", ".join(f'{k} = "{v}"' for k, v in sorted(rules.items()) if k.isidentifier())
        lines.append(f"\t{name} = {{ {body} }},")
    lines.append("}")
    return "\n".join(lines)


def bundle_server(spec_path: str, database_path: str | None = None, client: bool = False) -> str:
    with open(os.path.join(ROOT, "tests", "mock", "RobloxMock.luau"), encoding="utf-8") as handle:
        mock_source = handle.read()
    out = ["Mock = (function()\n" + mock_source + "\nend)()"]
    out.append(export_map())
    out.append(property_rules(database_path))
    out.append("""
local requireCache = {}
function require(module)
\tlocal factory = rawget(module, "_factory")
\tassert(factory, "require() called on something that isn't a ModuleScript: " .. tostring(module))
\tif requireCache[module] == nil then
\t\trequireCache[module] = factory(module)
\tend
\treturn requireCache[module]
end
local ReplicatedStorageService = Mock.service("ReplicatedStorage")
SharedFolder = mk("Folder", "Shared", ReplicatedStorageService)
local RemotesFolder = mk("Folder", "Remotes", ReplicatedStorageService)
mk("RemoteEvent", "Notify", RemotesFolder)
mk("RemoteEvent", "Busted", RemotesFolder)
mk("RemoteFunction", "Purchase", RemotesFolder)
mk("RemoteFunction", "SpawnCar", RemotesFolder)
ServerScript = mk("Script", "Server", Mock.service("ServerScriptService"))
local M = {}
""")
    for path in sorted(glob.glob(os.path.join(SHARED, "*.luau"))):
        name = os.path.splitext(os.path.basename(path))[0]
        out.append(script_factory(f'M["shared_{name}"]', name, "ModuleScript", "SharedFolder", path))
    server_dir = os.path.join(ROOT, "src", "server")
    for path in sorted(glob.glob(os.path.join(server_dir, "*.luau"))):
        filename = os.path.basename(path)
        if filename.startswith("init."):
            continue
        name = os.path.splitext(filename)[0]
        out.append(script_factory(f'M["server_{name}"]', name, "ModuleScript", "ServerScript", path))
    with open(os.path.join(server_dir, "init.server.luau"), encoding="utf-8") as handle:
        init_source = handle.read()
    out.append("RunServer = function()\nlocal script = ServerScript\n" + init_source + "\nend")
    client_dir = os.path.join(ROOT, "src", "client")
    out.append('ClientScript = mk("LocalScript", "Client", Mock.service("StarterPlayer"))')
    for path in sorted(glob.glob(os.path.join(client_dir, "*.luau"))):
        filename = os.path.basename(path)
        if filename.startswith("init."):
            continue
        name = os.path.splitext(filename)[0]
        out.append(script_factory(f'M["client_{name}"]', name, "ModuleScript", "ClientScript", path))
    with open(os.path.join(client_dir, "init.client.luau"), encoding="utf-8") as handle:
        client_source = handle.read()
    out.append("RunClient = function()\nlocal script = ClientScript\n" + client_source + "\nend")
    with open(spec_path, encoding="utf-8") as handle:
        out.append(handle.read())
    return "\n".join(out)


def bundle(spec_path: str) -> str:
    names = sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SHARED, "*.luau")))
    out = [f"local MODULE_NAMES = {{ {', '.join(repr(n).replace(chr(39), chr(34)) for n in names)} }}", PRELUDE]
    for name in names:
        with open(os.path.join(SHARED, f"{name}.luau"), encoding="utf-8") as handle:
            source = handle.read()
        out.append(f'moduleFactories["{name}"] = function(script)\n{source}\nend')
    with open(spec_path, encoding="utf-8") as handle:
        out.append(handle.read())
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--luau", default=shutil.which("luau") or "luau")
    parser.add_argument("--database", default=DEFAULT_DATABASE,
                        help="rbx-dom database.json; enables strict Roblox property checks in the mock")
    args = parser.parse_args()
    failures = 0
    for spec in sorted(glob.glob(os.path.join(ROOT, "tests", "*.spec.luau"))):
        print(f"== {os.path.relpath(spec, ROOT)}")
        with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False, encoding="utf-8") as handle:
            uses_engine = os.path.basename(spec).startswith(("server", "client"))
            handle.write(bundle_server(spec, args.database) if uses_engine else bundle(spec))
            bundle_path = handle.name
        try:
            result = subprocess.run([args.luau, bundle_path], capture_output=True, text=True)
        except FileNotFoundError:
            print("The `luau` CLI was not found. Install it from https://github.com/luau-lang/luau/releases")
            return 2
        finally:
            pass
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            failures += 1
        os.unlink(bundle_path)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
