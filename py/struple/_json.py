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
        # float32 carries its exact f64 value already (widened at decode), so the
        # same shortest-round-trip rendering applies to both without re-promotion.
        return _render_float(val)
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


def _render_float(f: float) -> str:
    """Render a float as ECMAScript ``Number::toString`` — the shortest decimal that
    round-trips to the same f64, formatted per the ECMA-262 fixed/exponential rules.
    This is the pinned cross-language float text format (Item 3), mirroring the Zig
    reference (src/json.zig: ``writeFloat`` + ``writeEcmaDigits``).

    ``repr(f)`` already gives the shortest round-tripping decimal; only its NOTATION
    diverges (``1e-07``/``1e+16``), so we extract its shortest significant digits +
    base-10 exponent and re-emit per ECMA-262."""
    if not math.isfinite(f):
        return "null"  # JSON has no inf/nan (matches JSON.stringify)
    if f == 0:
        return "0"  # +0.0 and -0.0 both render "0"
    s = repr(f)  # shortest round-trip; fixed ("0.1") or scientific ("1e-07")
    neg = ""
    if s[0] == "-":
        neg = "-"
        s = s[1:]
    epos = s.find("e")
    if epos < 0:
        epos = s.find("E")
    if epos >= 0:
        exp_val = int(s[epos + 1:])
        mant = s[:epos]
    else:
        exp_val = 0
        mant = s
    int_part, _, frac_part = mant.partition(".")
    digits = int_part + frac_part
    # Digit at index i has base-10 exponent (len(int_part) - 1 - i) + exp_val.
    # Strip leading zeros to find the most-significant digit, trailing zeros to
    # shorten (repr keeps a trailing ".0" on integral values -> digits like "1000").
    first = 0
    while first < len(digits) - 1 and digits[first] == "0":
        first += 1
    last = len(digits) - 1
    while last > first and digits[last] == "0":
        last -= 1
    sig = digits[first:last + 1]
    n = (len(int_part) - first) + exp_val  # = E + 1, the integer-part digit count
    return neg + _ecma_digits(sig, n)


def _ecma_digits(digits: str, n: int) -> str:
    """Emit shortest significant ``digits`` as ECMAScript Number::toString, where ``n``
    is the integer-part digit count (``10^(n-1) <= |value| < 10^n``). Mirrors the Zig
    reference (src/json.zig: ``writeEcmaDigits``)."""
    k = len(digits)
    if 1 <= n <= 21:
        if k <= n:  # integer with trailing zeros
            return digits + "0" * (n - k)
        return digits[:n] + "." + digits[n:]  # decimal point inside the digits
    if -6 < n <= 0:  # 0.00...digits
        return "0." + "0" * (-n) + digits
    # exponential: d1[.d2..dk]e±(n-1)
    mant = digits[0] + ("." + digits[1:] if k > 1 else "")
    e = n - 1
    return mant + "e" + ("+" if e >= 0 else "-") + str(abs(e))


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
