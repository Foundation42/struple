// Semantic (value-based) ordering over encoded struple streams.
//
// compare gives the raw memcmp order: the type byte dominates, so an integer
// and a float never interleave by magnitude. semanticOrder instead compares by
// value — int, big-int, float32, float64 and decimal all compare by their exact
// mathematical value, with no precision loss even where a double can't represent
// the number.
//
// Cross-type order (when the two values aren't both numbers):
//
//   nil < undefined < bool < number < timestamp < uuid < string < bytes
//       < array < map < set
//
// NaN sorts as the greatest number (above +inf); -0.0 == 0.0 == int 0.
// Containers recurse element-wise, with a shorter value sorting before a longer
// one that extends it.
//
// Each finite number maps exactly to a rational (BigInt numerator/denominator);
// a/b vs c/d compares as a*d vs c*b. A double's exact value is mantissa*2^exp,
// read from its IEEE-754 bits; a decimal's is coefficient*10^exp. So decimal 0.1
// < float 0.1 and decimal 2.5 == float 2.5 fall out exactly.

import 'dart:typed_data';

import 'codec.dart';

/// Maximum container nesting depth accepted by the recursive semantic compare.
/// Bounds stack use so hostile deeply-nested input is rejected instead of
/// overflowing the stack (Item 5). Mirrors the Zig reference's `max_depth`; no
/// real value nests anywhere near this deep.
const int _maxDepth = 256;

/// Compares two encoded streams element-by-element by semantic value, returning
/// -1, 0, or +1.
int semanticOrder(Uint8List a, Uint8List b) => _semanticOrderDepth(a, b, 0);

int _semanticOrderDepth(Uint8List a, Uint8List b, int depth) {
  // Bound recursion into nested containers so hostile deeply-nested input is
  // rejected rather than overflowing the stack (Item 5).
  if (depth > _maxDepth) {
    throw const StrupleException('nesting too deep');
  }
  final ra = Reader(a);
  final rb = Reader(b);
  while (true) {
    final ea = ra.next();
    final eb = rb.next();
    if (ea == null && eb == null) return 0;
    if (ea == null) return -1; // a is a prefix of b
    if (eb == null) return 1;
    final c = _compareElements(ea, eb, depth);
    if (c != 0) return c;
  }
}

/// Whether two encoded streams compare equal by value.
bool semanticEqual(Uint8List a, Uint8List b) => semanticOrder(a, b) == 0;

/// Normalizes any comparison result to -1, 0, or +1.
int _sign(int c) => c < 0 ? -1 : (c > 0 ? 1 : 0);

int _classRank(Kind k) {
  switch (k) {
    case Kind.nil:
      return 0;
    case Kind.undefined:
      return 1;
    case Kind.boolean:
      return 2;
    case Kind.int_:
    case Kind.bigInt:
    case Kind.float32:
    case Kind.float64:
    case Kind.decimal:
      return 3; // unified "number" class
    case Kind.timestamp:
      return 4;
    case Kind.uuid:
      return 5;
    case Kind.string:
      return 6;
    case Kind.bytes:
      return 7;
    case Kind.array:
      return 8;
    case Kind.map:
      return 9;
    case Kind.set:
      return 10;
  }
}

int _compareElements(Element a, Element b, int depth) {
  final ra = _classRank(a.kind);
  final rb = _classRank(b.kind);
  if (ra != rb) return _sign(ra.compareTo(rb));
  switch (a.kind) {
    case Kind.nil:
    case Kind.undefined:
      return 0;
    case Kind.boolean:
      return _sign(_boolToInt(a.boolValue).compareTo(_boolToInt(b.boolValue)));
    case Kind.int_:
    case Kind.bigInt:
    case Kind.float32:
    case Kind.float64:
    case Kind.decimal:
      return _compareNumbers(a, b);
    case Kind.timestamp:
      return _sign(a.timestampValue.compareTo(b.timestampValue));
    case Kind.uuid:
      return compareBytes(a.uuidValue!, b.uuidValue!);
    case Kind.string:
    case Kind.bytes:
      // content order == framed-byte order (the wire format is built so a
      // compare of the framed slice already gives content order).
      return compareBytes(a.body!, b.body!);
    case Kind.array:
    case Kind.set:
    case Kind.map:
      return _semanticOrderDepth(
          unescape(a.body!), unescape(b.body!), depth + 1);
  }
}

// ---------------------------------------------------------------------------
// Numbers — every finite number maps exactly to a rational (BigInt num/den)
// ---------------------------------------------------------------------------

/// Ranks within the number class: -inf(0) < finite(1) < +inf(2) < NaN(3).
int _numClass(Element e) {
  // Integers and decimals are always finite.
  if (e.kind != Kind.float32 && e.kind != Kind.float64) return 1;
  final f = e.doubleValue;
  if (f.isNaN) return 3;
  if (f == double.infinity) return 2;
  if (f == double.negativeInfinity) return 0;
  return 1;
}

int _compareNumbers(Element a, Element b) {
  final ca = _numClass(a);
  final cb = _numClass(b);
  if (ca != cb) return _sign(ca.compareTo(cb));
  if (ca != 1) return 0; // both -inf, both +inf, or both NaN
  return _sign(_numToRat(a).compareTo(_numToRat(b)));
}

/// An exact rational num/den (den > 0).
class _Rat {
  final BigInt num;
  final BigInt den;
  const _Rat(this.num, this.den);

  /// Compares this to [other]: num/den vs o.num/o.den == num*o.den vs o.num*den.
  int compareTo(_Rat other) {
    final left = num * other.den;
    final right = other.num * den;
    return left.compareTo(right);
  }
}

_Rat _numToRat(Element e) {
  switch (e.kind) {
    case Kind.int_:
    case Kind.bigInt:
      return _Rat(e.intValue!, BigInt.one);
    case Kind.float32:
    case Kind.float64:
      return _doubleToRat(e.doubleValue);
    case Kind.decimal:
      return _decimalToRat(e.decimalValue!);
    default:
      return _Rat(BigInt.zero, BigInt.one);
  }
}

final ByteData _scratch = ByteData(8);

/// Exact rational value of a finite double: mantissa * 2^exp.
_Rat _doubleToRat(double v) {
  if (v == 0.0) return _Rat(BigInt.zero, BigInt.one);
  _scratch.setFloat64(0, v, Endian.big);
  final bits = (BigInt.from(_scratch.getUint32(0, Endian.big)) << 32) |
      BigInt.from(_scratch.getUint32(4, Endian.big));
  final negative = (bits >> 63) != BigInt.zero;
  final rawExp = ((bits >> 52) & BigInt.from(0x7FF)).toInt();
  final frac = bits & ((BigInt.one << 52) - BigInt.one);

  BigInt mant;
  int exp;
  if (rawExp == 0) {
    mant = frac; // subnormal
    exp = -1074;
  } else {
    mant = (BigInt.one << 52) | frac;
    exp = rawExp - 1075;
  }
  if (negative) mant = -mant;

  if (exp >= 0) {
    return _Rat(mant << exp, BigInt.one);
  }
  return _Rat(mant, BigInt.one << (-exp));
}

/// Exact rational value of a decimal: coefficient * 10^exp.
_Rat _decimalToRat(Decimal d) {
  if (d.isZero) return _Rat(BigInt.zero, BigInt.one);
  final digits = d.coefficientDigits();
  var coeff = BigInt.zero;
  final ten = BigInt.from(10);
  for (final dch in digits) {
    coeff = coeff * ten + BigInt.from(dch);
  }
  if (d.negative) coeff = -coeff;
  final exp = d.exponent;
  if (exp >= 0) {
    return _Rat(coeff * ten.pow(exp), BigInt.one);
  }
  return _Rat(coeff, ten.pow(-exp));
}

int _boolToInt(bool b) => b ? 1 : 0;
