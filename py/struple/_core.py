"""struple core codec — a faithful port of the Zig reference.

The encoded bytes are directly comparable: ``compare(pack(a), pack(b))`` (and
plain ``bytes`` comparison) matches the semantic order of ``a`` and ``b``. The
conformance corpus (``conformance/vectors.json``) pins byte identity across
languages.
"""

from __future__ import annotations

import datetime as _dt
import decimal as _decimal
import math as _math
import struct
import uuid as _uuid
from fractions import Fraction as _Fraction
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
UUID = 0x44
STRING = 0x48
BYTES = 0x49
ARRAY = 0x50
MAP = 0x52
SET = 0x54

# Leading sign markers inside a decimal payload, isolating the three sign groups so
# memcmp keeps negative < zero < positive. For negatives the rest of the payload is
# bit-complemented, so a larger magnitude sorts earlier.
DEC_SIGN_NEG = 0x01
DEC_SIGN_ZERO = 0x02
DEC_SIGN_POS = 0x03

_MASK64 = (1 << 64) - 1
_SIGN64 = 1 << 63
# The fixed integer slots span the i128 range; values beyond use the big-int codes.
_I128_MAX = (1 << 127) - 1
_I128_MIN = -(1 << 127)
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

    def append_decimal(self, value, digits=None, exp=None) -> "Writer":
        """Append an arbitrary-precision decimal.

        Either pass a native ``decimal.Decimal`` (the recommended form) as the
        sole argument, or the explicit ``(negative, digits, exp)`` triple where
        ``digits`` is an iterable of the coefficient's decimal digits (0–9,
        most-significant first) and ``exp`` the power-of-ten scale.
        """
        if digits is None and exp is None:
            if not isinstance(value, _decimal.Decimal):
                value = _decimal.Decimal(value)
            negative, digs, dexp = _decimal_to_components(value)
        else:
            negative = bool(value)
            digs = list(digits)
            dexp = exp
        _append_decimal(self.buf, negative, digs, dexp)
        return self

    def append_decimal_string(self, s: str) -> "Writer":
        _append_decimal_string(self.buf, s)
        return self

    def append_timestamp(self, micros: int) -> "Writer":
        _append_timestamp(self.buf, micros)
        return self

    def append_uuid(self, u) -> "Writer":
        _append_uuid(self.buf, u.bytes if isinstance(u, _uuid.UUID) else bytes(u))
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
    elif isinstance(value, _decimal.Decimal):
        negative, digits, exp = _decimal_to_components(value)
        _append_decimal(out, negative, digits, exp)
    elif isinstance(value, _uuid.UUID):
        _append_uuid(out, value.bytes)
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
    # The fixed slots span the whole i128 range (1–16 byte magnitudes).
    if _I128_MIN <= value <= _I128_MAX:
        if negative:
            pos_val = mag - 1
            n = (pos_val.bit_length() + 7) // 8 or 1
            out.append(INT_ZERO - n)
            out += ((1 << (8 * n)) - mag).to_bytes(n, "big")
        else:
            mag_len = (mag.bit_length() + 7) // 8
            out.append(INT_ZERO + mag_len)
            out += mag.to_bytes(mag_len, "big")
        return
    # arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
    out.append(INT_NEG_BIG if negative else INT_POS_BIG)
    n = (mag.bit_length() + 7) // 8
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


def _append_uuid(out: bytearray, raw: bytes) -> None:
    if len(raw) != 16:
        raise ValueError("struple: uuid must be 16 bytes")
    out.append(UUID)
    out += raw


def _decimal_to_components(value: _decimal.Decimal) -> tuple[bool, list[int], int]:
    """A native ``Decimal`` -> ``(negative, digits, exp)`` (digits most-significant
    first), via ``Decimal.as_tuple()`` which maps 1:1 onto the wire model."""
    if not value.is_finite():
        raise ValueError("struple: cannot encode non-finite decimal")
    sign, digits, exp = value.as_tuple()
    return bool(sign), list(digits), int(exp)


def _append_decimal(out: bytearray, negative: bool, digits, exp: int) -> None:
    """Append ``(-1)^negative · C · 10^exp`` where ``digits`` are C's decimal digits
    (0–9, most-significant first). Canonicalized: leading/trailing zeros are
    stripped and any all-zero coefficient collapses to the single zero form."""
    digits = list(digits)
    lead = 0
    while lead < len(digits) and digits[lead] == 0:
        lead += 1
    sig = digits[lead:]

    out.append(DECIMAL)
    if not sig:  # canonical zero — one form regardless of scale
        out.append(DEC_SIGN_ZERO)
        return

    # Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
    # Trailing zeros change neither the value nor E, so drop them for storage.
    adj_exp = len(sig) + exp
    end = len(sig)
    while end > 0 and sig[end - 1] == 0:
        end -= 1
    store = sig[:end]

    # Order-bearing tail: [E as a struple int][base-100 digits][terminator].
    tail = bytearray()
    _append_integer(tail, adj_exp)
    for i in range(0, len(store), 2):
        hi = store[i]
        lo = store[i + 1] if i + 1 < len(store) else 0  # pad odd tail with 0
        tail.append(hi * 10 + lo + 1)  # pair 0–99 -> byte 1–100
    tail.append(TERMINATOR)

    out.append(DEC_SIGN_NEG if negative else DEC_SIGN_POS)
    if negative:
        out += bytes(b ^ 0xFF for b in tail)
    else:
        out += tail


def _append_decimal_string(out: bytearray, s: str) -> None:
    """Parse ``[+/-] digits [. digits] [ (e|E) [+/-] digits ]`` and append it."""
    i = 0
    n = len(s)
    negative = False
    if i < n and s[i] in "+-":
        negative = s[i] == "-"
        i += 1
    digits: list[int] = []
    exp = 0
    seen_point = False
    any_digit = False
    while i < n:
        c = s[i]
        if c == ".":
            if seen_point:
                raise ValueError("struple: invalid decimal")
            seen_point = True
            i += 1
            continue
        if c in "eE":
            break
        if not ("0" <= c <= "9"):
            raise ValueError("struple: invalid decimal")
        digits.append(ord(c) - 48)
        if seen_point:
            exp -= 1
        any_digit = True
        i += 1
    if not any_digit:
        raise ValueError("struple: invalid decimal")
    if i < n and s[i] in "eE":
        i += 1
        esign = 1
        if i < n and s[i] in "+-":
            if s[i] == "-":
                esign = -1
            i += 1
        ev = 0
        edig = False
        while i < n:
            if not ("0" <= s[i] <= "9"):
                raise ValueError("struple: invalid decimal")
            ev = ev * 10 + (ord(s[i]) - 48)
            edig = True
            i += 1
        if not edig:
            raise ValueError("struple: invalid decimal")
        exp += esign * ev
    _append_decimal(out, negative, digits, exp)


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
        if t == DECIMAL:
            return ("decimal", self._read_decimal())
        if t == TIMESTAMP:
            return ("timestamp", self._read_timestamp())
        if t == UUID:
            return ("uuid", self._take(16))
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

    def peek_type(self):
        """The next element's type code without consuming it (None at end)."""
        return self.buf[self.pos] if self.pos < len(self.buf) else None

    def rest(self) -> bytes:
        """The remaining unread bytes (a valid struple stream)."""
        return self.buf[self.pos :]

    def next_view(self):
        """The next element's raw bytes, advancing the cursor (None at end)."""
        start = self.pos
        if self.next() is None:
            return None
        return self.buf[start : self.pos]

    def skip(self) -> bool:
        """Advance past the next element; False at end of stream."""
        return self.next_view() is not None

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
        positive = t > INT_ZERO
        n = (t - INT_ZERO) if positive else (INT_ZERO - t)
        payload = self._take(n)
        # The widest (16-byte) slots can address values outside i128; a canonical
        # encoder uses the big-int codes for those, so reject them here.
        if n == 16 and ((positive and payload[0] >= 0x80) or (not positive and payload[0] < 0x80)):
            raise ValueError("struple: non-canonical 16-byte integer")
        raw = int.from_bytes(payload, "big")
        return ("int", raw if positive else raw - (1 << (8 * n)))

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

    def _read_decimal(self) -> _decimal.Decimal:
        sign = self._take(1)[0]
        if sign == DEC_SIGN_ZERO:
            return _decimal.Decimal(0)
        if sign not in (DEC_SIGN_NEG, DEC_SIGN_POS):
            raise ValueError("struple: invalid decimal sign")
        negative = sign == DEC_SIGN_NEG
        adj_exp = self._read_dec_exponent(negative)
        # Digit bytes are 1–100 (positive) or their complement (negative), and never
        # collide with the terminator (0x00, or 0xFF when complemented).
        term = 0xFF if negative else 0x00
        start = self.pos
        i = self.pos
        buf = self.buf
        n = len(buf)
        while i < n and buf[i] != term:
            i += 1
        if i >= n:
            raise ValueError("struple: truncated decimal")
        if i == start:
            raise ValueError("struple: nonzero decimal must carry digits")
        coeff_stored = buf[start:i]
        self.pos = i + 1  # consume the terminator

        # Unpack the base-100 coefficient into decimal digits (most-significant first).
        digits: list[int] = []
        last = len(coeff_stored) - 1
        for idx, raw in enumerate(coeff_stored):
            pair = ((raw ^ 0xFF) if negative else raw) - 1
            digits.append(pair // 10)
            lo = pair % 10
            if not (idx == last and lo == 0):  # skip the synthetic trailing pad
                digits.append(lo)
        exp = adj_exp - len(digits)
        return _decimal.Decimal((1 if negative else 0, tuple(digits), exp))

    def _read_dec_exponent(self, complement: bool) -> int:
        """Read the embedded exponent (a struple integer), un-complementing each byte
        for negatives. Big-int exponent codes are rejected."""
        comp = (lambda b: b ^ 0xFF) if complement else (lambda b: b)
        tb = comp(self._take(1)[0])
        if tb == INT_ZERO:
            return 0
        if (0x10 <= tb <= 0x1F) or (0x21 <= tb <= 0x30):
            positive = tb > INT_ZERO
            n = (tb - INT_ZERO) if positive else (INT_ZERO - tb)
            payload = bytes(comp(b) for b in self._take(n))
            if n == 16 and ((positive and payload[0] >= 0x80) or (not positive and payload[0] < 0x80)):
                raise ValueError("struple: non-canonical 16-byte decimal exponent")
            raw = int.from_bytes(payload, "big")
            return raw if positive else raw - (1 << (8 * n))
        raise ValueError("struple: invalid decimal exponent")

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
    if kind == "decimal":
        return val
    if kind == "timestamp":
        return _EPOCH + _dt.timedelta(microseconds=val)
    if kind == "uuid":
        return _uuid.UUID(bytes=val)
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
    elif kind == "decimal":
        negative, digits, exp = _decimal_to_components(val)
        _append_decimal(out, negative, digits, exp)
    elif kind == "timestamp":
        _append_timestamp(out, val)
    elif kind == "uuid":
        _append_uuid(out, val)
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


# ---------------------------------------------------------------------------
# Navigation / query
# ---------------------------------------------------------------------------


class View:
    """Navigation over a struple buffer (a stream of elements). Every result is
    a sub-buffer that is itself a valid struple buffer, so it composes."""

    def __init__(self, buf: bytes) -> None:
        self.buf = buf

    def reader(self) -> Reader:
        return Reader(self.buf)

    def count(self) -> int:
        r = self.reader()
        n = 0
        while r.skip():
            n += 1
        return n

    def at(self, index: int):
        r = self.reader()
        i = 0
        while True:
            v = r.next_view()
            if v is None:
                return None
            if i == index:
                return v
            i += 1

    def head(self):
        return self.at(0)

    def tail(self) -> bytes:
        r = self.reader()
        r.next_view()
        return r.rest()

    def nth_rest(self, n: int) -> bytes:
        r = self.reader()
        for _ in range(n):
            if not r.skip():
                break
        return r.rest()

    def take(self, n: int) -> bytes:
        r = self.reader()
        for _ in range(n):
            if not r.skip():
                break
        return self.buf[: len(self.buf) - len(r.rest())]

    def head_type(self):
        return self.buf[0] if len(self.buf) > 0 else None

    def is_nil(self) -> bool:
        return self.head_type() == NIL

    def is_undefined(self) -> bool:
        return self.head_type() == UNDEF

    def is_bool(self) -> bool:
        return self.head_type() in (BOOL_FALSE, BOOL_TRUE)

    def is_int(self) -> bool:
        t = self.head_type()
        return t is not None and (
            t == INT_ZERO or t == INT_NEG_BIG or t == INT_POS_BIG or 0x10 <= t <= 0x1F or 0x21 <= t <= 0x30
        )

    def is_float(self) -> bool:
        return self.head_type() in (FLOAT32, FLOAT64)

    def is_decimal(self) -> bool:
        return self.head_type() == DECIMAL

    def is_number(self) -> bool:
        return self.is_int() or self.is_float() or self.is_decimal()

    def is_timestamp(self) -> bool:
        return self.head_type() == TIMESTAMP

    def is_uuid(self) -> bool:
        return self.head_type() == UUID

    def is_string(self) -> bool:
        return self.head_type() == STRING

    def is_bytes(self) -> bool:
        return self.head_type() == BYTES

    def is_array(self) -> bool:
        return self.head_type() == ARRAY

    def is_map(self) -> bool:
        return self.head_type() == MAP

    def is_set(self) -> bool:
        return self.head_type() == SET

    def is_container(self) -> bool:
        return self.head_type() in (ARRAY, MAP, SET)

    def contained_items(self):
        """The container's inner element stream (un-escaped), or None."""
        if not self.is_container():
            return None
        e = self.reader().next()
        if e is None:
            return None
        kind, val = e
        return val if kind in ("array", "map", "set") else None


def view(buf: bytes) -> View:
    return View(buf)


class MapView:
    """Key/value pairs from a map's inner stream (from ``View.contained_items``).
    Keys are canonical (sorted), so ``get`` early-exits."""

    def __init__(self, inner: bytes) -> None:
        self.inner = inner

    def count(self) -> int:
        return View(self.inner).count() // 2

    def entries(self):
        r = Reader(self.inner)
        while True:
            k = r.next_view()
            if k is None:
                return
            v = r.next_view()
            if v is None:
                raise ValueError("struple: malformed map")
            yield (k, v)

    def get(self, key: bytes):
        """Look up the value bytes for an encoded key (e.g. ``encode("name")``)."""
        for k, v in self.entries():
            if k == key:
                return v
            if k > key:
                return None
        return None

    def indexed(self) -> "IndexedMap":
        """Materialize a random-access index for O(log n) ``get`` and O(1)
        ``at`` (see :class:`IndexedMap`). One O(n) pass over the inner stream."""
        return IndexedMap(self.inner)


class IndexedMap:
    """A map's entries materialized into a random-access index. Building it is one
    O(n) pass over the inner stream (from ``View.contained_items``); thereafter
    ``get`` is an O(log n) binary search (canonical key order means a key byte
    compare *is* the sort order) and ``at`` is O(1).

    Reach for this when you do many lookups, or need positional access, on the
    same map; use :class:`MapView` directly for a single zero-build lookup. The
    entry slices borrow the inner stream, so keep it alive for this index's life.
    """

    def __init__(self, inner: bytes) -> None:
        entries: list[tuple[bytes, bytes]] = []
        r = Reader(inner)
        while True:
            k = r.next_view()
            if k is None:
                break
            v = r.next_view()
            if v is None:
                raise ValueError("struple: malformed map")
            entries.append((k, v))
        self.entries = entries

    def count(self) -> int:
        """Number of entries — O(1)."""
        return len(self.entries)

    def __len__(self) -> int:
        return len(self.entries)

    def at(self, index: int):
        """The ``(key, value)`` entry at ``index`` in canonical (sorted) order —
        O(1); None if out of range."""
        if 0 <= index < len(self.entries):
            return self.entries[index]
        return None

    def find(self, key: bytes):
        """The index of ``key`` in canonical order, or None — O(log n)."""
        lo, hi = 0, len(self.entries)
        while lo < hi:
            mid = (lo + hi) // 2
            k = self.entries[mid][0]
            if k == key:
                return mid
            if k < key:
                lo = mid + 1
            else:
                hi = mid
        return None

    def get(self, key: bytes):
        """Look up the value bytes for an encoded key — O(log n) binary search."""
        i = self.find(key)
        return self.entries[i][1] if i is not None else None

    def __iter__(self):
        """Entries in canonical (sorted) order."""
        return iter(self.entries)


# ---------------------------------------------------------------------------
# Semantic (value-based) ordering
# ---------------------------------------------------------------------------

_CLASS_RANK = {
    "nil": 0, "undef": 1, "bool": 2, "int": 3, "float32": 3, "float64": 3, "decimal": 3,
    "timestamp": 4, "uuid": 5, "string": 6, "bytes": 7, "array": 8, "map": 9, "set": 10,
}


def _sign(x) -> int:
    return (x > 0) - (x < 0)


def semantic_order(a: bytes, b: bytes) -> int:
    """Compare two encoded streams by *value* (not bytes): int, float32 and
    float64 compare by exact mathematical value, so ``int 5 == float 5.0``.
    Returns -1, 0 or 1. NaN sorts greatest; -0.0 == 0; containers recurse."""
    ra, rb = Reader(a), Reader(b)
    while True:
        ea, eb = ra.next(), rb.next()
        if ea is None and eb is None:
            return 0
        if ea is None:
            return -1
        if eb is None:
            return 1
        c = _compare_elements(ea, eb)
        if c:
            return c


def semantic_eq(a: bytes, b: bytes) -> bool:
    return semantic_order(a, b) == 0


def _compare_elements(ea: tuple, eb: tuple) -> int:
    ka, va = ea
    kb, vb = eb
    ra, rb = _CLASS_RANK[ka], _CLASS_RANK[kb]
    if ra != rb:
        return _sign(ra - rb)
    if ka in ("nil", "undef"):
        return 0
    if ka == "bool":
        return _sign(int(va) - int(vb))
    if ka in ("int", "float32", "float64", "decimal"):
        return _compare_numbers(ea, eb)
    if ka == "timestamp":
        return _sign(va - vb)
    if ka == "uuid" or ka == "bytes":
        return (va > vb) - (va < vb)
    if ka == "string":
        ba, bb = va.encode("utf-8"), vb.encode("utf-8")  # UTF-8 byte order
        return (ba > bb) - (ba < bb)
    if ka in ("array", "set", "map"):
        return semantic_order(va, vb)  # va/vb are the (un-escaped) inner streams
    raise ValueError(f"struple: unknown element kind {ka!r}")


# Rank within the number class: -inf < finite < +inf < NaN. Ints and decimals
# are always finite.
def _num_class(e: tuple) -> int:
    k, v = e
    if k == "int" or k == "decimal":
        return 1
    if _math.isnan(v):
        return 3
    if v == _math.inf:
        return 2
    if v == -_math.inf:
        return 0
    return 1


def _compare_numbers(ea: tuple, eb: tuple) -> int:
    ca, cb = _num_class(ea), _num_class(eb)
    if ca != cb:
        return _sign(ca - cb)
    if ca != 1:
        return 0  # both -inf, both +inf, or both NaN
    ka, va = ea
    kb, vb = eb
    ai, bi = ka == "int", kb == "int"
    if ai and bi:
        return _sign(va - vb)
    if not _is_exact(ea) and not _is_exact(eb):
        return (va > vb) - (va < vb)  # both finite floats
    # At least one exact (int/decimal) operand — compare exactly via rationals.
    # Fraction is exact for int, Decimal and float (a float's true binary value),
    # so no precision is lost even for huge values.
    return _sign(_Fraction(va) - _Fraction(vb))


def _is_exact(e: tuple) -> bool:
    return e[0] == "int" or e[0] == "decimal"
