"""struple core codec — a faithful port of the Zig reference.

The encoded bytes are directly comparable: ``compare(pack(a), pack(b))`` (and
plain ``bytes`` comparison) matches the semantic order of ``a`` and ``b``. The
conformance corpus (``conformance/vectors.json``) pins byte identity across
languages.
"""

from __future__ import annotations

import datetime as _dt
import struct
from typing import Any, Iterable, Optional

# Type codes. Their order is the cross-type sort order.
TERMINATOR = 0x00
NIL = 0x01
UNDEF = 0x02
BOOL_FALSE = 0x05
BOOL_TRUE = 0x06
INT_NEG_BIG = 0x0F
INT_ZERO = 0x20
INT_POS_BIG = 0x31
FLOAT32 = 0x34
FLOAT64 = 0x35
DECIMAL = 0x38
TIMESTAMP = 0x40
STRING = 0x48
BYTES = 0x49
ARRAY = 0x50
MAP = 0x52
SET = 0x54

_MASK64 = (1 << 64) - 1
_SIGN64 = 1 << 63
_EPOCH = _dt.datetime(1970, 1, 1, tzinfo=_dt.timezone.utc)

# Element kinds yielded by Reader.next() as (kind, payload) tuples.
Element = tuple


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

def pack(*values: Any) -> bytes:
    out = bytearray()
    for v in values:
        _append_value(out, v)
    return bytes(out)


def encode(value: Any) -> bytes:
    out = bytearray()
    _append_value(out, value)
    return bytes(out)


class Writer:
    """Builder that mirrors the codec's explicit append methods."""

    def __init__(self) -> None:
        self.buf = bytearray()

    def bytes(self) -> bytes:
        return bytes(self.buf)

    def append_nil(self) -> "Writer":
        self.buf.append(NIL)
        return self

    def append_undefined(self) -> "Writer":
        self.buf.append(UNDEF)
        return self

    def append_bool(self, v: bool) -> "Writer":
        self.buf.append(BOOL_TRUE if v else BOOL_FALSE)
        return self

    def append_int(self, v: int) -> "Writer":
        _append_integer(self.buf, v)
        return self

    def append_float64(self, v: float) -> "Writer":
        _append_float64(self.buf, v)
        return self

    def append_float32(self, v: float) -> "Writer":
        _append_float32(self.buf, v)
        return self

    def append_timestamp(self, micros: int) -> "Writer":
        _append_timestamp(self.buf, micros)
        return self

    def append_string(self, s: str) -> "Writer":
        _write_framed(self.buf, STRING, s.encode("utf-8"))
        return self

    def append_bytes(self, b: bytes) -> "Writer":
        _write_framed(self.buf, BYTES, b)
        return self

    def append_array(self, child: bytes) -> "Writer":
        _write_framed(self.buf, ARRAY, child)
        return self

    def append_map(self, entries: Iterable[tuple[bytes, bytes]]) -> "Writer":
        _append_map(self.buf, entries)
        return self

    def append_set(self, elements: Iterable[bytes]) -> "Writer":
        _append_set(self.buf, elements)
        return self

    def append(self, value: Any) -> "Writer":
        _append_value(self.buf, value)
        return self


def _append_value(out: bytearray, value: Any) -> None:
    if value is None:
        out.append(NIL)
    elif isinstance(value, bool):  # bool is a subclass of int — check first
        out.append(BOOL_TRUE if value else BOOL_FALSE)
    elif isinstance(value, int):
        _append_integer(out, value)
    elif isinstance(value, float):
        _append_float64(out, value)
    elif isinstance(value, str):
        _write_framed(out, STRING, value.encode("utf-8"))
    elif isinstance(value, (bytes, bytearray)):
        _write_framed(out, BYTES, bytes(value))
    elif isinstance(value, (list, tuple)):
        child = bytearray()
        for item in value:
            _append_value(child, item)
        _write_framed(out, ARRAY, bytes(child))
    elif isinstance(value, dict):
        _append_map(out, ((encode(k), encode(v)) for k, v in value.items()))
    elif isinstance(value, (set, frozenset)):
        _append_set(out, (encode(e) for e in value))
    elif isinstance(value, _dt.datetime):
        _append_timestamp(out, _datetime_to_micros(value))
    else:
        raise TypeError(f"struple: cannot encode value of type {type(value).__name__}")


def _append_integer(out: bytearray, value: int) -> None:
    if value == 0:
        out.append(INT_ZERO)
        return
    negative = value < 0
    mag = -value if negative else value
    mag_len = (mag.bit_length() + 7) // 8
    if mag_len <= 8:
        if negative:
            pos_val = mag - 1
            n = (pos_val.bit_length() + 7) // 8 or 1
            out.append(INT_ZERO - n)
            out += ((1 << (8 * n)) - mag).to_bytes(n, "big")
        else:
            out.append(INT_ZERO + mag_len)
            out += mag.to_bytes(mag_len, "big")
        return
    # arbitrary precision: [m][n][magnitude], complemented for negatives
    out.append(INT_NEG_BIG if negative else INT_POS_BIG)
    n = mag_len
    m = (n.bit_length() + 7) // 8 or 1
    comp = (lambda b: ~b & 0xFF) if negative else (lambda b: b)
    out.append(comp(m))
    for b in n.to_bytes(m, "big"):
        out.append(comp(b))
    for b in mag.to_bytes(n, "big"):
        out.append(comp(b))


def _append_float64(out: bytearray, value: float) -> None:
    import math

    if math.isnan(value):
        bits = 0x7FF8000000000000
    else:
        v = 0.0 if value == 0 else value  # squash -0.0
        bits = int.from_bytes(struct.pack(">d", v), "big")
    bits = (~bits & _MASK64) if (bits & _SIGN64) else (bits ^ _SIGN64)
    out.append(FLOAT64)
    out += bits.to_bytes(8, "big")


def _append_float32(out: bytearray, value: float) -> None:
    import math

    if math.isnan(value):
        bits = 0x7FC00000
    else:
        v = 0.0 if value == 0 else value
        bits = int.from_bytes(struct.pack(">f", v), "big")
    mask32 = 0xFFFFFFFF
    bits = (~bits & mask32) if (bits & 0x80000000) else (bits ^ 0x80000000)
    out.append(FLOAT32)
    out += bits.to_bytes(4, "big")


def _append_timestamp(out: bytearray, micros: int) -> None:
    out.append(TIMESTAMP)
    out += ((micros & _MASK64) ^ _SIGN64).to_bytes(8, "big")


def _append_map(out: bytearray, entries: Iterable[tuple[bytes, bytes]]) -> None:
    items = sorted(entries, key=lambda kv: kv[0])
    out.append(MAP)
    for k, v in items:
        _write_escaped(out, k)
        _write_escaped(out, v)
    out.append(TERMINATOR)


def _append_set(out: bytearray, elements: Iterable[bytes]) -> None:
    items = sorted(elements)
    out.append(SET)
    prev: Optional[bytes] = None
    for e in items:
        if prev is not None and prev == e:
            continue
        _write_escaped(out, e)
        prev = e
    out.append(TERMINATOR)


def _write_framed(out: bytearray, type_code: int, content: bytes) -> None:
    out.append(type_code)
    _write_escaped(out, content)
    out.append(TERMINATOR)


def _write_escaped(out: bytearray, content: bytes) -> None:
    for b in content:
        out.append(b)
        if b == 0x00:
            out.append(0xFF)


def _datetime_to_micros(dt: _dt.datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    delta = dt - _EPOCH
    return delta.days * 86_400_000_000 + delta.seconds * 1_000_000 + delta.microseconds


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

class Reader:
    def __init__(self, buf: bytes, pos: int = 0) -> None:
        self.buf = buf
        self.pos = pos

    def done(self) -> bool:
        return self.pos >= len(self.buf)

    def next(self) -> Optional[Element]:
        if self.pos >= len(self.buf):
            return None
        t = self.buf[self.pos]
        self.pos += 1
        if t == NIL:
            return ("nil", None)
        if t == UNDEF:
            return ("undef", None)
        if t == BOOL_FALSE:
            return ("bool", False)
        if t == BOOL_TRUE:
            return ("bool", True)
        if t == INT_ZERO:
            return ("int", 0)
        if t in (INT_NEG_BIG, INT_POS_BIG):
            return self._read_big_int(t)
        if t == FLOAT32:
            return ("float32", self._read_f32())
        if t == FLOAT64:
            return ("float64", self._read_f64())
        if t == TIMESTAMP:
            return ("timestamp", self._read_timestamp())
        if t == STRING:
            return ("string", self._take_framed_unescaped().decode("utf-8"))
        if t == BYTES:
            return ("bytes", self._take_framed_unescaped())
        if t == ARRAY:
            return ("array", self._take_framed_unescaped())
        if t == MAP:
            return ("map", self._take_framed_unescaped())
        if t == SET:
            return ("set", self._take_framed_unescaped())
        if 0x10 <= t <= 0x1F or 0x21 <= t <= 0x30:
            return self._read_fixed_int(t)
        raise ValueError(f"struple: invalid type code {t:#x}")

    def _take(self, n: int) -> bytes:
        if self.pos + n > len(self.buf):
            raise ValueError("struple: truncated")
        s = self.buf[self.pos : self.pos + n]
        self.pos += n
        return s

    def _take_framed(self) -> bytes:
        start = self.pos
        i = self.pos
        buf = self.buf
        n = len(buf)
        while i < n:
            if buf[i] == 0x00:
                if i + 1 < n and buf[i + 1] == 0xFF:
                    i += 2
                    continue
                slice_ = buf[start:i]
                self.pos = i + 1
                return slice_
            i += 1
        raise ValueError("struple: truncated (unterminated framed value)")

    def _take_framed_unescaped(self) -> bytes:
        return _unescape(self._take_framed())

    def _read_fixed_int(self, t: int) -> Element:
        n = (INT_ZERO - t) if t < INT_ZERO else (t - INT_ZERO)
        if n > 8:
            raise ValueError(f"struple: unsupported integer width {n}")
        raw = int.from_bytes(self._take(n), "big")
        if t > INT_ZERO:
            return ("int", raw)
        return ("int", raw - (1 << (8 * n)))

    def _read_big_int(self, t: int) -> Element:
        negative = t == INT_NEG_BIG
        comp = (lambda b: ~b & 0xFF) if negative else (lambda b: b)
        m = comp(self._take(1)[0])
        n = 0
        for b in self._take(m):
            n = (n << 8) | comp(b)
        mag = 0
        for b in self._take(n):
            mag = (mag << 8) | comp(b)
        return ("int", -mag if negative else mag)

    def _read_f64(self) -> float:
        bits = int.from_bytes(self._take(8), "big")
        bits = (bits ^ _SIGN64) if (bits & _SIGN64) else (~bits & _MASK64)
        return struct.unpack(">d", bits.to_bytes(8, "big"))[0]

    def _read_f32(self) -> float:
        bits = int.from_bytes(self._take(4), "big")
        mask32 = 0xFFFFFFFF
        bits = (bits ^ 0x80000000) if (bits & 0x80000000) else (~bits & mask32)
        return struct.unpack(">f", bits.to_bytes(4, "big"))[0]

    def _read_timestamp(self) -> int:
        raw = int.from_bytes(self._take(8), "big") ^ _SIGN64
        return raw - (1 << 64) if raw >= _SIGN64 else raw


def unpack(data: bytes) -> list:
    r = Reader(data)
    out = []
    while (e := r.next()) is not None:
        out.append(_element_to_value(e))
    return out


def _element_to_value(e: Element) -> Any:
    kind, val = e
    if kind == "nil" or kind == "undef":
        return None
    if kind == "bool" or kind == "int" or kind in ("float32", "float64"):
        return val
    if kind == "timestamp":
        return _EPOCH + _dt.timedelta(microseconds=val)
    if kind == "string" or kind == "bytes":
        return val
    if kind == "array":
        return unpack(val)
    if kind == "set":
        return set(unpack(val))
    if kind == "map":
        r = Reader(val)
        d = {}
        while (k := r.next()) is not None:
            v = r.next()
            d[_element_to_value(k)] = _element_to_value(v)
        return d
    raise ValueError(f"struple: unknown element kind {kind!r}")


def _unescape(framed: bytes) -> bytes:
    if 0x00 not in framed:
        return framed
    out = bytearray()
    i = 0
    n = len(framed)
    while i < n:
        out.append(framed[i])
        if framed[i] == 0x00:
            i += 1  # skip the 0xff companion
        i += 1
    return bytes(out)


def transcode(data: bytes) -> bytes:
    """Decode every element and re-encode it. The output equals the input for any
    canonical buffer — a full round-trip validation of the decoder."""
    r = Reader(data)
    out = bytearray()
    while (e := r.next()) is not None:
        _append_element(out, e)
    return bytes(out)


def _append_element(out: bytearray, e: Element) -> None:
    kind, val = e
    if kind == "nil":
        out.append(NIL)
    elif kind == "undef":
        out.append(UNDEF)
    elif kind == "bool":
        out.append(BOOL_TRUE if val else BOOL_FALSE)
    elif kind == "int":
        _append_integer(out, val)
    elif kind == "float32":
        _append_float32(out, val)
    elif kind == "float64":
        _append_float64(out, val)
    elif kind == "timestamp":
        _append_timestamp(out, val)
    elif kind == "string":
        _write_framed(out, STRING, val.encode("utf-8"))
    elif kind == "bytes":
        _write_framed(out, BYTES, val)
    elif kind == "array":
        _write_framed(out, ARRAY, val)
    elif kind == "map":
        _write_framed(out, MAP, val)
    elif kind == "set":
        _write_framed(out, SET, val)
    else:
        raise ValueError(f"struple: unknown element kind {kind!r}")


def compare(a: bytes, b: bytes) -> int:
    """Lexicographic byte comparison (-1/0/1). Plain ``bytes`` comparison and
    ``sorted`` work too — they are already memcmp on the encoded keys."""
    return (a > b) - (a < b)
