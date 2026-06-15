"""JSON <-> struple, mirroring the Zig reference.

    from_json: JSON text  -> struple encoding (one element for the root value)
    to_json:   struple bytes -> canonical JSON text

Python's ``json.loads`` already parses integer tokens as arbitrary-precision
``int`` and fractional/exponent tokens as ``float``, so big integers stay
lossless with no extra work. Objects encode to canonical (key-sorted) maps.
"""

from __future__ import annotations

import base64
import json as _json
import math

from ._core import Reader, encode


def from_json(text: str) -> bytes:
    return encode(_json.loads(text))


def to_json(data: bytes) -> str:
    e = Reader(data).next()
    return "null" if e is None else _render(e)


def _render(e: tuple) -> str:
    kind, val = e
    if kind in ("nil", "undef"):
        return "null"
    if kind == "bool":
        return "true" if val else "false"
    if kind == "int":
        return str(val)
    if kind in ("float32", "float64"):
        return repr(val) if math.isfinite(val) else "null"
    if kind == "timestamp":
        return str(val)
    if kind == "string":
        return _json.dumps(val, ensure_ascii=False)
    if kind == "bytes":
        return _json.dumps(base64.b64encode(val).decode("ascii"))
    if kind in ("array", "set"):
        return _render_array(val)
    if kind == "map":
        return _render_map(val)
    raise ValueError(f"struple/json: unknown element kind {kind!r}")


def _render_array(body: bytes) -> str:
    r = Reader(body)
    parts = []
    while (e := r.next()) is not None:
        parts.append(_render(e))
    return "[" + ",".join(parts) + "]"


def _render_map(body: bytes) -> str:
    r = Reader(body)
    parts = []
    while (k := r.next()) is not None:
        v = r.next()
        if v is None:
            raise ValueError("struple/json: malformed map")
        key = _json.dumps(k[1], ensure_ascii=False) if k[0] == "string" else _json.dumps(_render(k))
        parts.append(key + ":" + _render(v))
    return "{" + ",".join(parts) + "}"
