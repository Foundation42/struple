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
# Decimal adjusted-exponent bound: i32. Keeps `exponent() = adj_exp - digitCount`
# from underflowing, and stops a huge exponent from driving a multi-GB toJson or an
# exponent-proportional semantic scale (HARDENING.md Item 2). Mirrors the Zig
# reference (readDecExponent / appendDecimal / appendDecimalString i32 caps).
_DEC_ADJ_EXP_MAX = (1 << 31) - 1   # 2147483647
_DEC_ADJ_EXP_MIN = -(1 << 31)      # -2147483648
_EPOCH = _dt.datetime(1970, 1, 1, tzinfo=_dt.timezone.utc)

# Maximum container/JSON nesting depth accepted by the recursive walks (JSON
# parse, JSON render, semantic compare). Bounds stack use so hostile deeply-nested
# input is rejected with a ValueError instead of overflowing the stack (a native
# RecursionError). Shared across all 12 ports; no real value nests near this deep.
# Mirrors the Zig reference (src/struple.zig: `pub const max_depth: usize = 256`).
_MAX_DEPTH = 256

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
    # Bound the adjusted exponent to i32 so it round-trips through decode's i32 cap
    # and downstream exponent math never overflows (Item 2).
    if adj_exp > _DEC_ADJ_EXP_MAX or adj_exp < _DEC_ADJ_EXP_MIN:
        raise ValueError("struple: decimal adjusted exponent out of range")
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
            if ev > _DEC_ADJ_EXP_MAX:  # far beyond any real exponent
                raise ValueError("struple: invalid decimal")
            edig = True
            i += 1
        if not edig:
            raise ValueError("struple: invalid decimal")
        exp += esign * ev
    # Bound the (i64-safe) exponent to i32 before handing off; _append_decimal
    # additionally bounds the adjusted exponent (Item 2).
    if exp > _DEC_ADJ_EXP_MAX or exp < _DEC_ADJ_EXP_MIN:
        raise ValueError("struple: invalid decimal")
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
    # Escape only the order-significant terminator byte: every 0x00 is followed by
    # a 0xFF companion. The common case (no 0x00) bulk-copies the run; otherwise a
    # single C-level replace inserts the companions — both byte-identical to the
    # per-byte loop, but far faster than appending one byte at a time in Python.
    if 0x00 in content:
        out += content.replace(b"\x00", b"\x00\xff")
    else:
        out += content


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
        # Guard written as `n > remaining`, never `pos + n > len`: mirrors the Zig
        # reference (`take`). The addition is the overflow site in fixed-width ports,
        # and here it avoids materializing a huge (pos + n) bignum for an
        # attacker-supplied n before the bound is even checked. `pos <= len` is a
        # Reader invariant, so `len - pos` never goes negative.
        if n > len(self.buf) - self.pos:
            raise ValueError("struple: truncated")
        s = self.buf[self.pos : self.pos + n]
        self.pos += n
        return s

    def _take_framed(self) -> bytes:
        # Jump to each candidate 0x00 in C (bytes.find) rather than scanning byte
        # by byte in Python. A 0x00 is the terminator unless it is immediately
        # followed by its 0xFF escape companion (an escaped data byte) — identical
        # framing to the per-byte loop, but the runs between terminators are
        # skipped at C speed.
        start = self.pos
        buf = self.buf
        n = len(buf)
        i = start
        find = buf.find
        while True:
            i = find(0x00, i)
            if i == -1:
                raise ValueError("struple: truncated (unterminated framed value)")
            if i + 1 < n and buf[i + 1] == 0xFF:
                i += 2
                continue
            self.pos = i + 1
            return buf[start:i]

    def _take_framed_unescaped(self) -> bytes:
        return _unescape(self._take_framed())

    def _read_fixed_int(self, t: int) -> Element:
        positive = t > INT_ZERO
        n = (t - INT_ZERO) if positive else (INT_ZERO - t)
        payload = self._take(n)
        # Strict decode — reject non-minimal fixed-int slots (Item 7). A positive
        # magnitude never carries a leading zero byte; a negative excess-form
        # payload only leads with 0xFF for the single-byte -1, so any wider
        # 0xFF-lead is a non-minimal encoding of the value. (For negatives a
        # leading 0x00 IS canonical, e.g. -256 = 1f00, so it is not rejected.)
        if positive:
            if payload[0] == 0x00:
                raise ValueError("struple: non-canonical fixed integer")
        elif payload[0] == 0xFF and n > 1:
            raise ValueError("struple: non-canonical fixed integer")
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
        # Length-of-length is capped at 8 bytes: no real magnitude needs a length
        # that doesn't fit in u64. Without this bound, m (0–255) lets an attacker
        # assemble an arbitrarily large n from hostile bytes; the _take(n) below then
        # rejects any n beyond the buffer cleanly (its guard is written as
        # `n > remaining`, never `pos + n`). Mirrors the Zig reference
        # (src/struple.zig: `if (m > 8) return error.InvalidType`).
        if m > 8:
            raise ValueError("struple: big-int length-of-length exceeds 8 bytes")
        n = 0
        for b in self._take(m):
            n = (n << 8) | comp(b)
        stored = self._take(n)
        # Strict decode — a big-int must be canonical (Item 7): a nonempty,
        # leading-zero-free magnitude, a minimal length header, and a value that
        # genuinely escapes the i128 fixed range (else it belongs in a fixed slot;
        # accepting it would also break memcmp ordering, since every big-int type
        # code sorts after every fixed-int code).
        if n == 0:  # empty magnitude — zero must be the int_zero code (fixes the intSign bug)
            raise ValueError("struple: non-canonical big-int (empty magnitude)")
        if m != (n.bit_length() + 7) // 8:  # non-minimal length-of-length header
            raise ValueError("struple: non-canonical big-int (non-minimal length header)")
        # `stored` is bit-complemented for negatives; the un-complemented
        # most-significant magnitude byte must be nonzero.
        if ((stored[0] ^ 0xFF) if negative else stored[0]) == 0:
            raise ValueError("struple: non-canonical big-int (leading-zero magnitude)")
        mag = 0
        for b in stored:
            mag = (mag << 8) | comp(b)
        value = -mag if negative else mag
        # A value inside the signed 128-bit range belongs in a fixed slot — reuse
        # the encoder's fits-fixed bound. A big-int code for it is non-canonical.
        if _I128_MIN <= value <= _I128_MAX:
            raise ValueError("struple: non-canonical big-int (value fits fixed range)")
        return ("int", value)

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
            v = raw if positive else raw - (1 << (8 * n))
            # Bound the adjusted exponent to i32 (Item 2): keeps `exponent()`
            # (= adj_exp − digitCount) from underflowing and is ~2× any real
            # decimal Emax. A larger stored exponent is malformed.
            if v > _DEC_ADJ_EXP_MAX or v < _DEC_ADJ_EXP_MIN:
                raise ValueError("struple: decimal adjusted exponent out of range")
            return v
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
    return _semantic_order_depth(a, b, 0)


def _semantic_order_depth(a: bytes, b: bytes, depth: int) -> int:
    # Bound recursion into nested containers so hostile deeply-nested input is
    # rejected with a ValueError rather than overflowing the stack (a native
    # RecursionError). depth 0 at the top-level stream, +1 per container descent;
    # mirrors the Zig reference (src/semantic.zig: `semanticOrderDepth`).
    if depth > _MAX_DEPTH:
        raise ValueError("struple: nesting too deep")
    ra, rb = Reader(a), Reader(b)
    while True:
        ea, eb = ra.next(), rb.next()
        if ea is None and eb is None:
            return 0
        if ea is None:
            return -1
        if eb is None:
            return 1
        c = _compare_elements(ea, eb, depth)
        if c:
            return c


def semantic_eq(a: bytes, b: bytes) -> bool:
    return semantic_order(a, b) == 0


def _compare_elements(ea: tuple, eb: tuple, depth: int) -> int:
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
        # va/vb are the (un-escaped) inner streams; +1 for the container descent.
        return _semantic_order_depth(va, vb, depth + 1)
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
    # At least one exact (int/decimal) operand, and not both int. Decide by base-10
    # order of magnitude first, so a decimal with an i32-huge exponent never
    # materializes a 10**exp-scaled Fraction (Item 2 DoS). The exact rational path
    # is reached only when the magnitudes are close — then the work is bounded by
    # the operands' digit counts, never by the raw exponent.
    xa, xb = _is_exact(ea), _is_exact(eb)
    if xa and xb:
        return _compare_exact_exact(ea, eb)
    if xa:
        return _compare_exact_float(ea, eb)
    return -_compare_exact_float(eb, ea)


def _is_exact(e: tuple) -> bool:
    return e[0] == "int" or e[0] == "decimal"


def _num_base10_digits(n: int) -> int:
    """Exact number of base-10 digits of a positive int, without ``str(n)`` (its
    conversion is O(digits²) and, on Python 3.11+, capped at 4300 digits) or
    ``math.log10`` (OverflowError past ~1e308). ``bit_length·log10(2)`` seeds a
    candidate; one or two integer-power corrections pin it exactly."""
    est = ((n.bit_length() * 1233) >> 12) + 1  # ~floor(bits·log10(2)) + 1
    while n >= 10 ** est:
        est += 1
    while est > 1 and n < 10 ** (est - 1):
        est -= 1
    return est


def _b10(e: tuple):
    """Base-10 view of an exact (int/decimal) element: ``(sign, coeff, exp10, oom)``
    with ``value = sign·coeff·10**exp10`` (``coeff`` a non-negative int) and
    ``oom = floor(log10|value|)`` so ``|value| ∈ [10**oom, 10**(oom+1))``. Zero maps
    to ``(0, 0, 0, None)``. Never materializes ``10**exp10`` — the DoS site."""
    k, v = e
    if k == "int":
        if v == 0:
            return (0, 0, 0, None)
        c = -v if v < 0 else v
        return (_sign(v), c, 0, _num_base10_digits(c) - 1)
    # decimal — as_tuple() is context-free (no huge power built)
    if v.is_zero():
        return (0, 0, 0, None)
    s, digits, exp = v.as_tuple()
    coeff = 0
    for d in digits:
        coeff = coeff * 10 + d
    return (-1 if s else 1, coeff, exp, exp + len(digits) - 1)


def _compare_exact_exact(ea: tuple, eb: tuple) -> int:
    sa, ca, xa, oa = _b10(ea)
    sb, cb, xb, ob = _b10(eb)
    if sa != sb:
        return _sign(sa - sb)  # covers zero-vs-nonzero and neg-vs-pos
    if sa == 0:
        return 0
    if oa != ob:
        # oom is exact, so disjoint bounds decide outright (10^oom ≤ |v| < 10^(oom+1)).
        mag = _sign(oa - ob)
    else:
        # Equal oom ⇒ |exp10 difference| = |digit-count difference|, so the scaling
        # power is bounded by the digit counts, never by the raw exponent.
        e = xa if xa < xb else xb
        mag = _sign(ca * 10 ** (xa - e) - cb * 10 ** (xb - e))
    return mag if sa > 0 else -mag


def _compare_exact_float(ex: tuple, ef: tuple) -> int:
    """Compare an exact (int/decimal) element ``ex`` against a finite float ``ef``."""
    sx, cx, xx, ox = _b10(ex)
    f = ef[1]
    sf = _sign(f)
    if sx != sf:
        return _sign(sx - sf)
    if sx == 0:
        return 0
    # A finite nonzero f64 has |f| ∈ (10**-324, 10**309). If the exact value's order
    # of magnitude clears that window, decide without touching the exponent.
    if ox >= 309:
        mag = 1
    elif ox <= -325:
        mag = -1
    else:
        # In-window: exp10 is bounded, so the exact rational compare is cheap. Use
        # context-free abs so no Decimal context rounding perturbs the value.
        kx, vx = ex
        mx = _Fraction(cx if kx == "int" else vx.copy_abs())
        mag = _sign(mx - _Fraction(abs(f)))
    return mag if sx > 0 else -mag
