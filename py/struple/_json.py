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
import uuid as _uuid

from ._core import (
    ARRAY, Reader, _MAX_DEPTH, _append_map, _append_value, _write_framed,
)


def from_json(text: str) -> bytes:
    # Reject hostile deeply-nested JSON before parsing: the linear bracket-depth
    # scan bounds both json.loads' recursive C scanner (which would otherwise raise
    # a native RecursionError) and the _encode_json_value walk below. Mirrors the
    # Zig reference (src/json.zig: `checkJsonDepth`).
    _check_json_depth(text)
    out = bytearray()
    _encode_json_value(out, _json.loads(text), 0)
    return bytes(out)


def _check_json_depth(text: str) -> None:
    """Scan JSON text and reject if ``[``/``{`` nesting exceeds ``_MAX_DEPTH``.
    Brackets inside string literals (and after ``\\``) don't count. Mirrors the
    Zig reference (src/json.zig: ``checkJsonDepth``)."""
    depth = 0
    in_string = False
    escaped = False
    for c in text:
        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
            continue
        if c == '"':
            in_string = True
        elif c == "[" or c == "{":
            depth += 1
            if depth > _MAX_DEPTH:
                raise ValueError("struple: nesting too deep")
        elif c == "]" or c == "}":
            if depth > 0:
                depth -= 1


def _encode_json_value(out: bytearray, value, depth: int) -> None:
    """Encode a value parsed by ``json.loads`` into struple bytes, bounding the
    build recursion so deeply-nested input is rejected with a ValueError (not a
    native RecursionError). depth 0 at the root element, +1 per container descent.
    Mirrors the Zig reference (src/json.zig: ``encodeValue``); byte-identical to
    the core encoder for the JSON type set (scalars delegate to it)."""
    if depth > _MAX_DEPTH:
        raise ValueError("struple: nesting too deep")
    if isinstance(value, list):
        child = bytearray()
        for item in value:
            _encode_json_value(child, item, depth + 1)
        _write_framed(out, ARRAY, bytes(child))
    elif isinstance(value, dict):
        entries = []
        for k, v in value.items():
            kb = bytearray()
            _encode_json_value(kb, k, depth + 1)
            vb = bytearray()
            _encode_json_value(vb, v, depth + 1)
            entries.append((bytes(kb), bytes(vb)))
        _append_map(out, entries)
    else:  # scalar leaf (null / bool / int / float / string) — reuse the core codec
        _append_value(out, value)


def to_json(data: bytes) -> str:
    e = Reader(data).next()
    return "null" if e is None else _render(e, 0)


def _render(e: tuple, depth: int) -> str:
    # Bound recursion into nested containers so a hostile deeply-nested encoding is
    # rejected with a ValueError rather than overflowing the stack. Mirrors the Zig
    # reference (src/json.zig: `writeValue` depth param).
    if depth > _MAX_DEPTH:
        raise ValueError("struple: nesting too deep")
    kind, val = e
    if kind in ("nil", "undef"):
        return "null"
    if kind == "bool":
        return "true" if val else "false"
    if kind == "int":
        return str(val)
    if kind in ("float32", "float64"):
        return repr(val) if math.isfinite(val) else "null"
    if kind == "decimal":
        return _render_decimal(val)
    if kind == "timestamp":
        return str(val)
    if kind == "uuid":
        return _json.dumps(str(_uuid.UUID(bytes=val)))
    if kind == "string":
        return _json.dumps(val, ensure_ascii=False)
    if kind == "bytes":
        return _json.dumps(base64.b64encode(val).decode("ascii"))
    if kind in ("array", "set"):
        return _render_array(val, depth)
    if kind == "map":
        return _render_map(val, depth)
    raise ValueError(f"struple/json: unknown element kind {kind!r}")


def _render_decimal(value) -> str:
    """An exact plain decimal number literal (no exponent), mirroring the Zig
    ``writeDecimal``. One-way: JSON has no decimal type."""
    if value.is_zero():
        return "0"
    sign, digits, exp = value.as_tuple()
    # Canonicalize: strip trailing zeros (value-preserving) so "12.300" -> "12.3".
    k = len(digits)
    while k > 0 and digits[k - 1] == 0:
        exp += 1
        k -= 1
    digs = "".join(str(d) for d in digits[:k])
    neg = "-" if sign else ""
    # Past the plain-notation pad threshold, render in scientific notation so a huge
    # (i32-bounded) exponent can't emit gigabytes of zeros. Mirrors the Zig reference
    # (src/json.zig: writeDecimal). Here `exp` == exponent() (adj_exp − k).
    if exp >= 0:
        pad = exp
    else:
        point_pos0 = k + exp
        pad = 0 if point_pos0 > 0 else -point_pos0
    if pad > 40:
        sci_exp = exp + k - 1  # power of ten of the most-significant digit
        mant = digs[0] + ("." + digs[1:] if k > 1 else "")
        esign = "+" if sci_exp >= 0 else "-"
        return neg + mant + "e" + esign + str(abs(sci_exp))
    if exp >= 0:
        return neg + digs + "0" * exp
    point_pos = k + exp  # number of integer-part digits
    if point_pos > 0:
        return neg + digs[:point_pos] + "." + digs[point_pos:]
    return neg + "0." + "0" * (-point_pos) + digs


def _render_array(body: bytes, depth: int) -> str:
    r = Reader(body)
    parts = []
    while (e := r.next()) is not None:
        parts.append(_render(e, depth + 1))
    return "[" + ",".join(parts) + "]"


def _render_map(body: bytes, depth: int) -> str:
    r = Reader(body)
    parts = []
    while (k := r.next()) is not None:
        v = r.next()
        if v is None:
            raise ValueError("struple/json: malformed map")
        key = _json.dumps(k[1], ensure_ascii=False) if k[0] == "string" else _json.dumps(_render(k, depth + 1))
        parts.append(key + ":" + _render(v, depth + 1))
    return "{" + ",".join(parts) + "}"
