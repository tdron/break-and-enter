"""
Minimal Roblox XML place (.rbxlx / .rbxmx) writer.

Builds an in-memory instance tree and serializes it in the same format Roblox
Studio writes (version 4 XML). Only the property types this project needs are
implemented. Property *names* must be the serialized names used in files
(e.g. BasePart.Size is written as "size", BasePart.Color as "Color3uint8").
The helper functions in map_builder.py take care of that.

tools/validate_place.py can check a generated file against Rojo's rbx-dom
reflection database to make sure every class/property/enum value is valid.
"""

from __future__ import annotations

import base64
import math
import struct
from dataclasses import dataclass
from typing import Any, Iterable
from xml.sax.saxutils import escape

# ---------------------------------------------------------------------------
# CFrame math
# ---------------------------------------------------------------------------

Vec = tuple[float, float, float]
Mat = tuple[Vec, Vec, Vec]

IDENTITY: Mat = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))


def _matmul(a: Mat, b: Mat) -> Mat:
    return tuple(
        tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3)
    )  # type: ignore[return-value]


def _matvec(a: Mat, v: Vec) -> Vec:
    return (
        a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2],
        a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2],
        a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2],
    )


def _transpose(a: Mat) -> Mat:
    return tuple(tuple(a[j][i] for j in range(3)) for i in range(3))  # type: ignore[return-value]


class CF:
    """A Roblox-style CFrame: position + 3x3 rotation matrix (rows R00..R22)."""

    __slots__ = ("p", "r")

    def __init__(self, x: float = 0.0, y: float = 0.0, z: float = 0.0, r: Mat = IDENTITY):
        self.p: Vec = (float(x), float(y), float(z))
        self.r: Mat = r

    @staticmethod
    def angles(rx: float, ry: float, rz: float) -> "CF":
        """Equivalent of CFrame.Angles(rx, ry, rz) (radians): R = Rx * Ry * Rz."""
        cx, sx = math.cos(rx), math.sin(rx)
        cy, sy = math.cos(ry), math.sin(ry)
        cz, sz = math.cos(rz), math.sin(rz)
        rot_x: Mat = ((1, 0, 0), (0, cx, -sx), (0, sx, cx))
        rot_y: Mat = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
        rot_z: Mat = ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1))
        return CF(0, 0, 0, _matmul(_matmul(rot_x, rot_y), rot_z))

    @staticmethod
    def deg(rx: float, ry: float, rz: float) -> "CF":
        return CF.angles(math.radians(rx), math.radians(ry), math.radians(rz))

    @staticmethod
    def look_at(pos: Vec, target: Vec) -> "CF":
        """Equivalent of CFrame.lookAt(pos, target) with world up = +Y."""
        look = (target[0] - pos[0], target[1] - pos[1], target[2] - pos[2])
        length = math.sqrt(sum(c * c for c in look))
        look = (look[0] / length, look[1] / length, look[2] / length)
        up = (0.0, 1.0, 0.0)
        right = (
            look[1] * up[2] - look[2] * up[1],
            look[2] * up[0] - look[0] * up[2],
            look[0] * up[1] - look[1] * up[0],
        )
        rlen = math.sqrt(sum(c * c for c in right))
        right = (right[0] / rlen, right[1] / rlen, right[2] / rlen)
        up2 = (
            right[1] * look[2] - right[2] * look[1],
            right[2] * look[0] - right[0] * look[2],
            right[0] * look[1] - right[1] * look[0],
        )
        back = (-look[0], -look[1], -look[2])
        r: Mat = (
            (right[0], up2[0], back[0]),
            (right[1], up2[1], back[1]),
            (right[2], up2[2], back[2]),
        )
        return CF(pos[0], pos[1], pos[2], r)

    def __mul__(self, other: "CF") -> "CF":
        r = _matmul(self.r, other.r)
        rp = _matvec(self.r, other.p)
        return CF(self.p[0] + rp[0], self.p[1] + rp[1], self.p[2] + rp[2], r)

    def point(self, v: Vec) -> Vec:
        """Transform a local-space point to world space."""
        rp = _matvec(self.r, v)
        return (self.p[0] + rp[0], self.p[1] + rp[1], self.p[2] + rp[2])

    def vector(self, v: Vec) -> Vec:
        """Rotate a local-space direction to world space."""
        return _matvec(self.r, v)

    def inverse(self) -> "CF":
        rt = _transpose(self.r)
        ip = _matvec(rt, self.p)
        return CF(-ip[0], -ip[1], -ip[2], rt)

    def rotation(self) -> "CF":
        return CF(0, 0, 0, self.r)

    def offset(self, x: float, y: float, z: float) -> "CF":
        return self * CF(x, y, z)

    @property
    def look(self) -> Vec:
        return (-self.r[0][2], -self.r[1][2], -self.r[2][2])


# ---------------------------------------------------------------------------
# Typed property values
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Float:
    value: float


@dataclass(frozen=True)
class Double:
    value: float


@dataclass(frozen=True)
class Int:
    value: int


@dataclass(frozen=True)
class Int64:
    value: int


@dataclass(frozen=True)
class Token:
    """An enum value (written as <token>)."""

    value: int


@dataclass(frozen=True)
class V3:
    x: float
    y: float
    z: float


@dataclass(frozen=True)
class V2:
    x: float
    y: float


@dataclass(frozen=True)
class UD2:
    xs: float
    xo: int
    ys: float
    yo: int


@dataclass(frozen=True)
class C3:
    """Color3 with float components 0..1."""

    r: float
    g: float
    b: float

    @staticmethod
    def rgb(r: int, g: int, b: int) -> "C3":
        return C3(r / 255, g / 255, b / 255)


@dataclass(frozen=True)
class C3u8:
    """Color3uint8 (BasePart.Color)."""

    r: int
    g: int
    b: int


@dataclass(frozen=True)
class FontFace:
    family: str
    weight: int = 400
    style: str = "Normal"


@dataclass(frozen=True)
class Content:
    url: str | None


class Ref:
    def __init__(self, target: "Inst | None"):
        self.target = target


class OptionalCF:
    def __init__(self, cf: CF | None):
        self.cf = cf


class Protected:
    """ProtectedString (script Source)."""

    def __init__(self, text: str):
        self.text = text


# ---------------------------------------------------------------------------
# Instance tree
# ---------------------------------------------------------------------------


class Inst:
    def __init__(self, class_name: str, name: str, parent: "Inst | None" = None):
        self.class_name = class_name
        self.name = name
        self.props: dict[str, Any] = {}
        self.attributes: dict[str, Any] = {}
        self.tags: list[str] = []
        self.children: list[Inst] = []
        self.parent: Inst | None = None
        self.source_path: str | None = None  # for sourcemap.json
        if parent is not None:
            parent.add(self)

    def add(self, child: "Inst") -> "Inst":
        child.parent = self
        self.children.append(child)
        return child

    def set(self, **props: Any) -> "Inst":
        self.props.update(props)
        return self

    def attr(self, **attributes: Any) -> "Inst":
        self.attributes.update(attributes)
        return self

    def find(self, name: str) -> "Inst | None":
        for child in self.children:
            if child.name == name:
                return child
        return None

    def descendants(self) -> Iterable["Inst"]:
        for child in self.children:
            yield child
            yield from child.descendants()


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------


def fmt_float(value: float) -> str:
    if isinstance(value, bool):
        raise TypeError("bool passed where a number was expected")
    if math.isnan(value):
        return "NAN"
    if math.isinf(value):
        return "INF" if value > 0 else "-INF"
    if abs(value) < 1e-9:
        return "0"
    text = f"{value:.9g}"
    if "e" in text or "E" in text:
        text = f"{value:.9f}".rstrip("0").rstrip(".")
    return text


def _encode_attributes(attributes: dict[str, Any]) -> str:
    """Encodes attributes in Roblox's binary AttributesSerialize format."""
    out = bytearray(struct.pack("<I", len(attributes)))
    for key, value in attributes.items():
        key_bytes = key.encode("utf-8")
        out += struct.pack("<I", len(key_bytes)) + key_bytes
        if isinstance(value, bool):
            out += bytes([0x03, 1 if value else 0])
        elif isinstance(value, (int, float)):
            out += bytes([0x06]) + struct.pack("<d", float(value))
        elif isinstance(value, str):
            raw = value.encode("utf-8")
            out += bytes([0x02]) + struct.pack("<I", len(raw)) + raw
        elif isinstance(value, V3):
            out += bytes([0x11]) + struct.pack("<fff", value.x, value.y, value.z)
        elif isinstance(value, C3):
            out += bytes([0x0F]) + struct.pack("<fff", value.r, value.g, value.b)
        else:
            raise TypeError(f"Unsupported attribute type for {key!r}: {type(value)}")
    return base64.b64encode(bytes(out)).decode("ascii")


def _cframe_body(cf: CF, indent: str) -> str:
    x, y, z = cf.p
    r = cf.r
    parts = [f"<X>{fmt_float(x)}</X>", f"<Y>{fmt_float(y)}</Y>", f"<Z>{fmt_float(z)}</Z>"]
    for i in range(3):
        for j in range(3):
            parts.append(f"<R{i}{j}>{fmt_float(r[i][j])}</R{i}{j}>")
    return "".join(f"\n{indent}{p}" for p in parts)


class Writer:
    def __init__(self) -> None:
        self.referents: dict[int, str] = {}
        self.counter = 0

    def referent(self, inst: Inst) -> str:
        key = id(inst)
        if key not in self.referents:
            self.counter += 1
            self.referents[key] = f"RBX{self.counter:032X}"
        return self.referents[key]

    def prop_xml(self, name: str, value: Any, indent: str) -> str:
        inner = indent + "\t"
        n = escape(name, {'"': "&quot;"})
        if isinstance(value, bool):
            return f'{indent}<bool name="{n}">{"true" if value else "false"}</bool>'
        if isinstance(value, str):
            return f'{indent}<string name="{n}">{escape(value)}</string>'
        if isinstance(value, Float):
            return f'{indent}<float name="{n}">{fmt_float(value.value)}</float>'
        if isinstance(value, Double):
            return f'{indent}<double name="{n}">{fmt_float(value.value)}</double>'
        if isinstance(value, Int):
            return f'{indent}<int name="{n}">{int(value.value)}</int>'
        if isinstance(value, Int64):
            return f'{indent}<int64 name="{n}">{int(value.value)}</int64>'
        if isinstance(value, Token):
            return f'{indent}<token name="{n}">{int(value.value)}</token>'
        if isinstance(value, V3):
            return (
                f'{indent}<Vector3 name="{n}">\n{inner}<X>{fmt_float(value.x)}</X>\n'
                f"{inner}<Y>{fmt_float(value.y)}</Y>\n{inner}<Z>{fmt_float(value.z)}</Z>\n{indent}</Vector3>"
            )
        if isinstance(value, V2):
            return (
                f'{indent}<Vector2 name="{n}">\n{inner}<X>{fmt_float(value.x)}</X>\n'
                f"{inner}<Y>{fmt_float(value.y)}</Y>\n{indent}</Vector2>"
            )
        if isinstance(value, UD2):
            return (
                f'{indent}<UDim2 name="{n}">\n{inner}<XS>{fmt_float(value.xs)}</XS>\n{inner}<XO>{int(value.xo)}</XO>\n'
                f"{inner}<YS>{fmt_float(value.ys)}</YS>\n{inner}<YO>{int(value.yo)}</YO>\n{indent}</UDim2>"
            )
        if isinstance(value, C3):
            return (
                f'{indent}<Color3 name="{n}">\n{inner}<R>{fmt_float(value.r)}</R>\n'
                f"{inner}<G>{fmt_float(value.g)}</G>\n{inner}<B>{fmt_float(value.b)}</B>\n{indent}</Color3>"
            )
        if isinstance(value, C3u8):
            packed = (0xFF << 24) | (value.r << 16) | (value.g << 8) | value.b
            return f'{indent}<Color3uint8 name="{n}">{packed}</Color3uint8>'
        if isinstance(value, CF):
            return f'{indent}<CoordinateFrame name="{n}">{_cframe_body(value, inner)}\n{indent}</CoordinateFrame>'
        if isinstance(value, OptionalCF):
            if value.cf is None:
                return f'{indent}<OptionalCoordinateFrame name="{n}"></OptionalCoordinateFrame>'
            body = _cframe_body(value.cf, inner + "\t")
            return (
                f'{indent}<OptionalCoordinateFrame name="{n}">\n{inner}<CFrame>{body}\n{inner}</CFrame>\n'
                f"{indent}</OptionalCoordinateFrame>"
            )
        if isinstance(value, FontFace):
            return (
                f'{indent}<Font name="{n}">\n{inner}<Family><url>{escape(value.family)}</url></Family>\n'
                f"{inner}<Weight>{int(value.weight)}</Weight>\n{inner}<Style>{value.style}</Style>\n{indent}</Font>"
            )
        if isinstance(value, Content):
            if value.url is None:
                return f'{indent}<Content name="{n}"><null></null></Content>'
            return f'{indent}<Content name="{n}"><url>{escape(value.url)}</url></Content>'
        if isinstance(value, Ref):
            target = "null" if value.target is None else self.referent(value.target)
            return f'{indent}<Ref name="{n}">{target}</Ref>'
        if isinstance(value, Protected):
            text = value.text.replace("]]>", "]]]]><![CDATA[>")
            return f'{indent}<ProtectedString name="{n}"><![CDATA[{text}]]></ProtectedString>'
        raise TypeError(f"Unsupported property type for {name!r}: {type(value)}")

    def item_xml(self, inst: Inst, depth: int, out: list[str]) -> None:
        indent = "\t" * depth
        out.append(f'{indent}<Item class="{inst.class_name}" referent="{self.referent(inst)}">')
        out.append(f"{indent}\t<Properties>")
        pindent = indent + "\t\t"
        out.append(self.prop_xml("Name", inst.name, pindent))
        for key in sorted(inst.props):
            out.append(self.prop_xml(key, inst.props[key], pindent))
        if inst.attributes:
            out.append(f'{pindent}<BinaryString name="AttributesSerialize">{_encode_attributes(inst.attributes)}</BinaryString>')
        if inst.tags:
            encoded = base64.b64encode("\0".join(inst.tags).encode("utf-8")).decode("ascii")
            out.append(f'{pindent}<BinaryString name="Tags">{encoded}</BinaryString>')
        out.append(f"{indent}\t</Properties>")
        for child in inst.children:
            self.item_xml(child, depth + 1, out)
        out.append(f"{indent}</Item>")


def serialize(roots: list[Inst]) -> str:
    writer = Writer()
    # Assign referents in tree order first so output is deterministic.
    for root in roots:
        writer.referent(root)
        for d in root.descendants():
            writer.referent(d)
    out = [
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
        '\t<Meta name="ExplicitAutoJoints">true</Meta>',
        "\t<External>null</External>",
        "\t<External>nil</External>",
    ]
    for root in roots:
        writer.item_xml(root, 1, out)
    out.append("</roblox>")
    return "\n".join(out) + "\n"
