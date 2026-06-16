// struple — streaming, lexicographically-ordered tuple packing (Dart).
//
// A struple value is a stream of self-delimiting, typed elements packed into a
// byte buffer such that the raw encoded bytes are directly memcmp-comparable:
//
//     compareBytes(pack(a), pack(b)) == the semantic order of a and b
//
// Drop two packed tuples into any byte-ordered store and they sort correctly
// with no custom comparator. This is a pure, zero-dependency Dart port of the
// Zig reference implementation, byte-identical across all language ports and
// driven by the shared conformance corpus.
//
// Every element starts with a one-byte type code, assigned so that a byte-wise
// compare of the type byte alone gives the cross-type order:
//
//     nil < undefined < false < true
//         < negative ints < zero < positive ints
//         < float32 < float64 < decimal < timestamp < uuid
//         < string < bytes < array < map < set

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Type codes
// ---------------------------------------------------------------------------

/// One-byte type tags. Their numeric order is the cross-type sort order. Gaps
/// are reserved for the future tower (float128, date/time-only, intervals, ...).
class TypeCode {
  TypeCode._();

  /// Terminator / escape sentinel for variable-length framing. Never a type.
  static const int terminator = 0x00;

  static const int nil = 0x01; // null (Python None / JS null)
  static const int undef = 0x02; // JS undefined

  static const int boolFalse = 0x05;
  static const int boolTrue = 0x06;

  static const int intNegBig = 0x0F; // arbitrary-precision negative (beyond i128)
  static const int intNegMin = 0x10; // widest fixed negative (16-byte magnitude)
  static const int intNegMax = 0x1F; // 1-byte fixed negative
  static const int intZero = 0x20;
  static const int intPosMin = 0x21; // 1-byte fixed positive
  static const int intPosMax = 0x30; // widest fixed positive (16-byte magnitude)
  static const int intPosBig = 0x31; // arbitrary-precision positive (beyond i128)

  static const int float32 = 0x34;
  static const int float64 = 0x35;

  static const int decimal = 0x38; // arbitrary-precision base-10 number

  static const int timestamp = 0x40;

  static const int uuid = 0x44; // 16-byte fixed payload (no framing)

  static const int string = 0x48;
  static const int bytes = 0x49;

  static const int array = 0x50;
  static const int map = 0x52;
  static const int set = 0x54;
}

/// Companion byte written after a literal 0x00 inside variable-length payloads.
const int _escapeByte = 0xFF;

// Decimal sign markers, isolating the three sign groups so a byte compare keeps
// negative < zero < positive. For negatives the rest of the payload is
// bit-complemented, so a larger magnitude sorts earlier.
const int _decSignNeg = 0x01;
const int _decSignZero = 0x02;
const int _decSignPos = 0x03;

/// Error raised by the decoder and the decimal-string parser.
class StrupleException implements Exception {
  final String message;
  const StrupleException(this.message);
  @override
  String toString() => 'StrupleException: $message';
}

/// Identifies the type of a decoded [Element].
enum Kind {
  nil,
  undefined,
  boolean,
  int_,
  bigInt,
  float32,
  float64,
  decimal,
  timestamp,
  uuid,
  string,
  bytes,
  array,
  map,
  set,
}

// ---------------------------------------------------------------------------
// Decoded element
// ---------------------------------------------------------------------------

/// A decoded element. For string/bytes/array/map/set the [body] slice points
/// into the source buffer and is the *framed* payload (literal 0x00 still
/// appears as 0x00 0xFF); when it contains no 0x00 it is already the literal
/// content. Use [unescape], then a child [Reader] for containers.
class Element {
  final Kind kind;

  final bool boolValue; // boolean
  final BigInt? intValue; // int_ / bigInt (the exact integer value)
  final double doubleValue; // float32 / float64
  final Decimal? decimalValue; // decimal
  final int timestampValue; // timestamp (microseconds since the Unix epoch, UTC)
  final Uint8List? uuidValue; // uuid (16 bytes)
  final Uint8List? body; // string/bytes/array/map/set (framed)

  const Element._({
    required this.kind,
    this.boolValue = false,
    this.intValue,
    this.doubleValue = 0.0,
    this.decimalValue,
    this.timestampValue = 0,
    this.uuidValue,
    this.body,
  });

  factory Element.nil() => const Element._(kind: Kind.nil);
  factory Element.undefined() => const Element._(kind: Kind.undefined);
  factory Element.boolean(bool v) => Element._(kind: Kind.boolean, boolValue: v);
  factory Element.int_(BigInt v) => Element._(kind: Kind.int_, intValue: v);
  factory Element.bigInt(BigInt v) => Element._(kind: Kind.bigInt, intValue: v);
  factory Element.float32(double v) =>
      Element._(kind: Kind.float32, doubleValue: v);
  factory Element.float64(double v) =>
      Element._(kind: Kind.float64, doubleValue: v);
  factory Element.decimal(Decimal v) =>
      Element._(kind: Kind.decimal, decimalValue: v);
  factory Element.timestamp(int micros) =>
      Element._(kind: Kind.timestamp, timestampValue: micros);
  factory Element.uuid(Uint8List v) => Element._(kind: Kind.uuid, uuidValue: v);
  factory Element.string(Uint8List framed) =>
      Element._(kind: Kind.string, body: framed);
  factory Element.bytes(Uint8List framed) =>
      Element._(kind: Kind.bytes, body: framed);
  factory Element.array(Uint8List framed) =>
      Element._(kind: Kind.array, body: framed);
  factory Element.map(Uint8List framed) =>
      Element._(kind: Kind.map, body: framed);
  factory Element.set_(Uint8List framed) =>
      Element._(kind: Kind.set, body: framed);
}

/// A decoded decimal value: (-1)^[negative] * coefficient * 10^exponent, with
/// the coefficient's significant digits carried base-100 packed (two digits per
/// byte). [adjExp] is the adjusted exponent (the power of ten of the
/// most-significant digit). The zero value has an empty coefficient.
class Decimal {
  final bool negative;
  final int adjExp;

  /// Base-100 packed digit bytes *as stored*: each pair is value+1 (1..100),
  /// bit-complemented when [negative]. Empty for the canonical zero.
  final Uint8List coeffStored;

  const Decimal(this.negative, this.adjExp, this.coeffStored);

  /// Whether this is the canonical zero.
  bool get isZero => coeffStored.isEmpty;

  /// Number of significant decimal digits in the coefficient.
  int get digitCount {
    if (coeffStored.isEmpty) return 0;
    var last = coeffStored[coeffStored.length - 1];
    if (negative) last = (~last) & 0xFF;
    final pair = last - 1;
    // An odd digit count pads the final pair's low digit with a (canonical) zero.
    var n = coeffStored.length * 2;
    if (pair % 10 == 0) n--;
    return n;
  }

  /// The power of ten applied to the integer coefficient, i.e.
  /// value = +/- coefficient * 10^exponent.
  int get exponent => adjExp - digitCount;

  /// The coefficient's decimal digits (each 0..9, most-significant first).
  Uint8List coefficientDigits() {
    final out = <int>[];
    for (var idx = 0; idx < coeffStored.length; idx++) {
      var raw = coeffStored[idx];
      if (negative) raw = (~raw) & 0xFF;
      final pair = raw - 1;
      out.add(pair ~/ 10);
      final lo = pair % 10;
      final isLast = idx + 1 == coeffStored.length;
      if (!(isLast && lo == 0)) {
        out.add(lo); // skip only the synthetic trailing pad
      }
    }
    return Uint8List.fromList(out);
  }
}

// ---------------------------------------------------------------------------
// Writer — builds an encoded tuple
// ---------------------------------------------------------------------------

/// Accumulates encoded elements into a memcmp-comparable byte buffer.
class Writer {
  final BytesBuilder _bb = BytesBuilder(copy: false);

  /// The encoded bytes accumulated so far (a fresh copy).
  Uint8List bytes() => _bb.toBytes();

  /// Clears the buffer.
  void reset() => _bb.clear();

  void _byte(int b) => _bb.addByte(b & 0xFF);

  void appendNil() => _byte(TypeCode.nil);
  void appendUndefined() => _byte(TypeCode.undef);

  void appendBool(bool v) => _byte(v ? TypeCode.boolTrue : TypeCode.boolFalse);

  /// Appends a signed integer element.
  void appendInt(int v) => appendBigIntValue(BigInt.from(v));

  /// Appends an arbitrary-precision integer. Values inside the i128 range use
  /// the fixed-width codes; values beyond it use the big-int codes.
  void appendBigIntValue(BigInt v) {
    if (v.sign == 0) {
      _byte(TypeCode.intZero);
      return;
    }
    appendBigInt(v.sign < 0, _magnitudeBytes(v.abs()));
  }

  /// Appends an integer given its sign and big-endian magnitude bytes (leading
  /// zeros are trimmed). Routes through the fixed path when the value fits the
  /// i128 range, else the big-int codes.
  void appendBigInt(bool negative, List<int> magnitudeBE) {
    final mag = _trimLeadingZeros(magnitudeBE);
    if (mag.isEmpty) {
      _byte(TypeCode.intZero);
      return;
    }
    if (_fitsFixed(negative, mag)) {
      if (negative) {
        _encodeNegative(mag);
      } else {
        _encodePositive(mag);
      }
      return;
    }
    _byte(negative ? TypeCode.intNegBig : TypeCode.intPosBig);
    _writeBigIntFields(mag, negative);
  }

  /// Appends a 32-bit float element.
  void appendF32(double v) {
    final bits = _orderableF32Bits(v);
    _byte(TypeCode.float32);
    _byte(bits >> 24);
    _byte(bits >> 16);
    _byte(bits >> 8);
    _byte(bits);
  }

  /// Appends a 64-bit float element.
  void appendF64(double v) {
    final bits = _orderableF64Bits(v);
    _byte(TypeCode.float64);
    final mask = BigInt.from(0xFF);
    for (var s = 56; s >= 0; s -= 8) {
      _byte(((bits >> s) & mask).toInt());
    }
  }

  /// Appends an arbitrary-precision decimal (-1)^[negative] * C * 10^[exp],
  /// where [digits] are the coefficient C's decimal digits (each 0..9,
  /// most-significant first). Canonicalized on the way in: leading/trailing
  /// zeros are stripped and any all-zero coefficient collapses to the single
  /// zero form.
  void appendDecimal(bool negative, List<int> digits, int exp) {
    var lead = 0;
    while (lead < digits.length && digits[lead] == 0) {
      lead++;
    }
    final sig = digits.sublist(lead);

    _byte(TypeCode.decimal);
    if (sig.isEmpty) {
      _byte(_decSignZero); // canonical zero — one form regardless of scale
      return;
    }

    // Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
    final adjExp = sig.length + exp;
    var end = sig.length;
    while (end > 0 && sig[end - 1] == 0) {
      end--;
    }
    final store = sig.sublist(0, end);

    // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
    final tail = Writer();
    _appendFixedInt(tail, BigInt.from(adjExp));
    for (var i = 0; i < store.length; i += 2) {
      final hi = store[i];
      final lo = (i + 1 < store.length) ? store[i + 1] : 0;
      tail._byte(hi * 10 + lo + 1); // pair 0..99 -> byte 1..100
    }
    tail._byte(TypeCode.terminator);

    final tb = tail.bytes();
    if (negative) {
      _byte(_decSignNeg);
      for (final b in tb) {
        _byte(~b);
      }
    } else {
      _byte(_decSignPos);
      _bb.add(tb);
    }
  }

  /// Appends a decimal parsed from text:
  /// [+/-] digits [. digits] [ (e|E) [+/-] digits ].
  void appendDecimalString(String s) {
    var i = 0;
    var negative = false;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) {
      negative = s[i] == '-';
      i++;
    }
    final digits = <int>[];
    var exp = 0;
    var seenPoint = false;
    var any = false;
    for (; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x2E /* . */) {
        if (seenPoint) throw const StrupleException('invalid decimal');
        seenPoint = true;
        continue;
      }
      if (c == 0x65 /* e */ || c == 0x45 /* E */) break;
      if (c < 0x30 || c > 0x39) throw const StrupleException('invalid decimal');
      digits.add(c - 0x30);
      if (seenPoint) exp--;
      any = true;
    }
    if (!any) throw const StrupleException('invalid decimal');
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
      i++;
      var esign = 1;
      if (i < s.length && (s[i] == '+' || s[i] == '-')) {
        if (s[i] == '-') esign = -1;
        i++;
      }
      var ev = 0;
      var edig = false;
      for (; i < s.length; i++) {
        final c = s.codeUnitAt(i);
        if (c < 0x30 || c > 0x39) throw const StrupleException('invalid decimal');
        ev = ev * 10 + (c - 0x30);
        edig = true;
      }
      if (!edig) throw const StrupleException('invalid decimal');
      exp += esign * ev;
    }
    appendDecimal(negative, digits, exp);
  }

  /// Appends a timestamp: microseconds since the Unix epoch, UTC.
  void appendTimestamp(int micros) {
    // Flip the sign bit so two's-complement order matches unsigned byte order.
    final u = BigInt.from(micros).toUnsigned(64) ^ (BigInt.one << 63);
    _byte(TypeCode.timestamp);
    final mask = BigInt.from(0xFF);
    for (var s = 56; s >= 0; s -= 8) {
      _byte(((u >> s) & mask).toInt());
    }
  }

  /// Appends a 128-bit UUID, stored as its 16 raw bytes.
  void appendUuid(Uint8List v) {
    _byte(TypeCode.uuid);
    _bb.add(v);
  }

  /// Appends a UTF-8 string element.
  void appendString(List<int> utf8Bytes) =>
      _writeFramed(TypeCode.string, utf8Bytes);

  /// Appends a binary element.
  void appendBytes(List<int> v) => _writeFramed(TypeCode.bytes, v);

  /// Appends a nested array. [child] is the encoded element stream of another
  /// tuple (e.g. another Writer's bytes()).
  void appendArray(List<int> child) => _writeFramed(TypeCode.array, child);

  /// Appends a map. [entries] is a list of [key, value] encodings; they are
  /// sorted by key into canonical order. (Duplicate keys are the caller's
  /// responsibility.)
  void appendMap(List<List<Uint8List>> entries) {
    final idx = List<int>.generate(entries.length, (i) => i);
    idx.sort((a, b) => compareBytes(entries[a][0], entries[b][0]));
    _byte(TypeCode.map);
    for (final i in idx) {
      _writeEscaped(entries[i][0]);
      _writeEscaped(entries[i][1]);
    }
    _byte(TypeCode.terminator);
  }

  /// Appends a set. [elements] (each an element encoding) are sorted and
  /// de-duplicated into canonical order.
  void appendSet(List<Uint8List> elements) {
    final idx = List<int>.generate(elements.length, (i) => i);
    idx.sort((a, b) => compareBytes(elements[a], elements[b]));
    _byte(TypeCode.set);
    Uint8List? prev;
    for (final i in idx) {
      final e = elements[i];
      if (prev != null && compareBytes(prev, e) == 0) continue;
      _writeEscaped(e);
      prev = e;
    }
    _byte(TypeCode.terminator);
  }

  void _encodePositive(List<int> mag) {
    _byte(TypeCode.intZero + mag.length);
    _bb.add(mag);
  }

  void _encodeNegative(List<int> mag) {
    // Excess form: store 2^(8n) - magnitude, where n is the byte width chosen so
    // that (magnitude-1) fits. The low n bytes of the two's-complement negation
    // give exactly that.
    final magV = _bigFromBytes(mag);
    final posVal = magV - BigInt.one;
    var n = _magnitudeBytes(posVal).length;
    if (n == 0) n = 1;
    _byte(TypeCode.intZero - n);
    final span = BigInt.one << (n * 8);
    final excess = span - magV;
    _bb.add(_leftPad(_magnitudeBytes(excess), n));
  }

  void _writeBigIntFields(List<int> mag, bool complement) {
    final n = mag.length;
    final nBytes = _bigEndianBytes(n);
    final m = nBytes.length;
    if (complement) {
      _byte(~m);
      for (final b in nBytes) {
        _byte(~b);
      }
      for (final b in mag) {
        _byte(~b);
      }
    } else {
      _byte(m);
      _bb.add(nBytes);
      _bb.add(mag);
    }
  }

  void _writeEscaped(List<int> content) {
    for (final b in content) {
      _byte(b);
      if (b == 0x00) _byte(_escapeByte);
    }
  }

  void _writeFramed(int typeCode, List<int> content) {
    _byte(typeCode);
    _writeEscaped(content);
    _byte(TypeCode.terminator);
  }
}

// ---------------------------------------------------------------------------
// Reader — streams elements back out
// ---------------------------------------------------------------------------

/// Streams decoded elements out of an encoded buffer.
class Reader {
  final Uint8List buf;
  int pos = 0;

  Reader(this.buf);

  /// Whether the reader has consumed the whole buffer.
  bool get done => pos >= buf.length;

  /// Decodes and returns the next element, or null at end of stream.
  Element? next() {
    if (pos >= buf.length) return null;
    final tc = buf[pos];
    pos++;

    if (tc == TypeCode.nil) return Element.nil();
    if (tc == TypeCode.undef) return Element.undefined();
    if (tc == TypeCode.boolFalse) return Element.boolean(false);
    if (tc == TypeCode.boolTrue) return Element.boolean(true);
    if (tc == TypeCode.intZero) return Element.int_(BigInt.zero);
    if ((tc >= 0x10 && tc <= 0x1F) || (tc >= 0x21 && tc <= 0x30)) {
      final positive = tc > TypeCode.intZero;
      final n = positive ? tc - TypeCode.intZero : TypeCode.intZero - tc;
      final payload = _take(n);
      // A canonical encoder uses the big-int codes for 16-byte values outside
      // the i128 range, so such a fixed payload is malformed.
      if (n == 16 &&
          ((positive && payload[0] >= 0x80) ||
              (!positive && payload[0] < 0x80))) {
        throw const StrupleException('invalid type code');
      }
      return Element.int_(_decodeIntPayload(positive, payload));
    }
    if (tc == TypeCode.intNegBig || tc == TypeCode.intPosBig) {
      final negative = tc == TypeCode.intNegBig;
      final m = _decodeByte(_take(1)[0], negative);
      final nbytes = _take(m);
      var n = 0;
      for (final b in nbytes) {
        n = (n << 8) | _decodeByte(b, negative);
      }
      final mag = _take(n);
      return Element.bigInt(_bigIntFromStored(negative, mag));
    }
    if (tc == TypeCode.float32) return Element.float32(_decodeF32(_take(4)));
    if (tc == TypeCode.float64) return Element.float64(_decodeF64(_take(8)));
    if (tc == TypeCode.decimal) return Element.decimal(_takeDecimal());
    if (tc == TypeCode.timestamp) {
      final p = _take(8);
      var raw = BigInt.zero;
      for (final b in p) {
        raw = (raw << 8) | BigInt.from(b);
      }
      final v = raw ^ (BigInt.one << 63);
      return Element.timestamp(v.toSigned(64).toInt());
    }
    if (tc == TypeCode.uuid) {
      return Element.uuid(Uint8List.fromList(_take(16)));
    }
    if (tc == TypeCode.string) return Element.string(_takeFramed());
    if (tc == TypeCode.bytes) return Element.bytes(_takeFramed());
    if (tc == TypeCode.array) return Element.array(_takeFramed());
    if (tc == TypeCode.map) return Element.map(_takeFramed());
    if (tc == TypeCode.set) return Element.set_(_takeFramed());
    throw const StrupleException('invalid type code');
  }

  /// The type code of the next element without consuming it (null at end).
  int? peekType() => pos < buf.length ? buf[pos] : null;

  /// The remaining unread bytes (a valid struple stream).
  Uint8List rest() => Uint8List.sublistView(buf, pos);

  /// The next element's raw bytes (a zero-copy view, itself a valid one-element
  /// struple buffer), advancing the cursor. Null at end of stream.
  Uint8List? nextView() {
    final start = pos;
    if (next() == null) return null;
    return Uint8List.sublistView(buf, start, pos);
  }

  /// Advances past the next element; false at end of stream.
  bool skip() => nextView() != null;

  Decimal _takeDecimal() {
    final sign = _take(1)[0];
    if (sign == _decSignZero) {
      return Decimal(false, 0, Uint8List.sublistView(buf, pos, pos));
    }
    if (sign != _decSignNeg && sign != _decSignPos) {
      throw const StrupleException('invalid type code');
    }
    final negative = sign == _decSignNeg;
    final adjExp = _readDecExponent(negative);
    // Digit bytes are 1..100 (positive) or their complement (negative), and
    // never collide with the terminator (0x00, or 0xFF when complemented).
    final term = negative ? 0xFF : 0x00;
    final start = pos;
    var i = pos;
    while (i < buf.length && buf[i] != term) {
      i++;
    }
    if (i >= buf.length) throw const StrupleException('truncated input');
    if (i == start) {
      throw const StrupleException('invalid type code'); // nonzero needs digits
    }
    pos = i + 1; // consume the terminator
    return Decimal(negative, adjExp, Uint8List.sublistView(buf, start, i));
  }

  int _readDecExponent(bool complement) {
    final tb = _decodeByte(_take(1)[0], complement);
    if (tb == TypeCode.intZero) return 0;
    if ((tb >= TypeCode.intNegMin && tb <= TypeCode.intNegMax) ||
        (tb >= TypeCode.intPosMin && tb <= TypeCode.intPosMax)) {
      final positive = tb > TypeCode.intZero;
      final n = positive ? tb - TypeCode.intZero : TypeCode.intZero - tb;
      final raw = _take(n);
      final tmp = Uint8List(n);
      for (var k = 0; k < raw.length; k++) {
        tmp[k] = _decodeByte(raw[k], complement);
      }
      if (n == 16 &&
          ((positive && tmp[0] >= 0x80) || (!positive && tmp[0] < 0x80))) {
        throw const StrupleException('invalid type code');
      }
      final v = _decodeIntPayload(positive, tmp);
      if (!v.isValidInt) throw const StrupleException('invalid type code');
      return v.toInt();
    }
    throw const StrupleException('invalid type code');
  }

  Uint8List _take(int n) {
    if (pos + n > buf.length) throw const StrupleException('truncated input');
    final s = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return s;
  }

  Uint8List _takeFramed() {
    final start = pos;
    var i = pos;
    while (i < buf.length) {
      if (buf[i] == 0x00) {
        if (i + 1 < buf.length && buf[i + 1] == _escapeByte) {
          i += 2; // escaped literal 0x00
          continue;
        }
        pos = i + 1; // consume terminator
        return Uint8List.sublistView(buf, start, i);
      }
      i++;
    }
    throw const StrupleException('truncated input');
  }
}

// ---------------------------------------------------------------------------
// Ordering and transcode
// ---------------------------------------------------------------------------

/// The raw memcmp order of two encoded streams: -1, 0, or +1. This is the
/// lexicographic byte order, the defining property of the format. For
/// value-based ordering across number representations use semanticOrder.
int compare(List<int> a, List<int> b) => compareBytes(a, b);

/// Lexicographic byte comparison: -1, 0, or +1.
int compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  if (a.length < b.length) return -1;
  if (a.length > b.length) return 1;
  return 0;
}

/// Decodes every element of an encoded buffer and re-encodes it, yielding
/// canonical bytes. For canonical input it is the identity.
Uint8List transcode(Uint8List encoded) {
  final r = Reader(encoded);
  final w = Writer();
  Element? e;
  while ((e = r.next()) != null) {
    _reencode(w, e!);
  }
  return w.bytes();
}

void _reencode(Writer w, Element e) {
  switch (e.kind) {
    case Kind.nil:
      w.appendNil();
    case Kind.undefined:
      w.appendUndefined();
    case Kind.boolean:
      w.appendBool(e.boolValue);
    case Kind.int_:
    case Kind.bigInt:
      w.appendBigIntValue(e.intValue!);
    case Kind.float32:
      w.appendF32(e.doubleValue);
    case Kind.float64:
      w.appendF64(e.doubleValue);
    case Kind.decimal:
      _reencodeDecimal(w, e.decimalValue!);
    case Kind.timestamp:
      w.appendTimestamp(e.timestampValue);
    case Kind.uuid:
      w.appendUuid(e.uuidValue!);
    case Kind.string:
      w.appendString(unescape(e.body!));
    case Kind.bytes:
      w.appendBytes(unescape(e.body!));
    case Kind.array:
    case Kind.map:
    case Kind.set:
      final inner = unescape(e.body!);
      final sub = Writer();
      final r = Reader(inner);
      Element? ie;
      while ((ie = r.next()) != null) {
        _reencode(sub, ie!);
      }
      // The inner stream is already canonical; re-frame it directly so map/set
      // ordering is preserved exactly.
      w._writeFramed(_containerTypeCode(e.kind), sub.bytes());
  }
}

int _containerTypeCode(Kind k) {
  switch (k) {
    case Kind.array:
      return TypeCode.array;
    case Kind.map:
      return TypeCode.map;
    default:
      return TypeCode.set;
  }
}

void _reencodeDecimal(Writer w, Decimal d) {
  if (d.isZero) {
    w.appendDecimal(false, const [], 0);
    return;
  }
  w.appendDecimal(d.negative, d.coefficientDigits(), d.exponent);
}

// ---------------------------------------------------------------------------
// Escaping helpers for variable-length payloads
// ---------------------------------------------------------------------------

/// Converts a framed payload (0x00 0xFF -> 0x00) into its literal inner bytes
/// (a fresh slice).
Uint8List unescape(Uint8List framed) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < framed.length; i++) {
    out.addByte(framed[i]);
    if (framed[i] == 0x00) i++; // skip the escape byte
  }
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Integer encode/decode helpers
// ---------------------------------------------------------------------------

void _appendFixedInt(Writer w, BigInt v) {
  if (v.sign == 0) {
    w._byte(TypeCode.intZero);
    return;
  }
  final mag = _magnitudeBytes(v.abs());
  if (v.sign < 0) {
    w._encodeNegative(mag);
  } else {
    w._encodePositive(mag);
  }
}

BigInt _decodeIntPayload(bool positive, List<int> payload) {
  final raw = _bigFromBytes(payload);
  if (positive) return raw;
  // Negative: value = raw - 2^(8*len).
  final span = BigInt.one << (payload.length * 8);
  return raw - span;
}

/// Whether sign + trimmed big-endian magnitude fits the i128 range
/// [-2^127, 2^127-1].
bool _fitsFixed(bool negative, List<int> mag) {
  if (mag.length < 16) return true;
  if (mag.length > 16) return false;
  if (mag[0] < 0x80) return true; // |value| < 2^127
  if (!negative) return false; // positive >= 2^127 -> big-int
  if (mag[0] != 0x80) return false; // magnitude > 2^127 -> big-int
  for (var i = 1; i < mag.length; i++) {
    if (mag[i] != 0) return false;
  }
  return true; // exactly -2^127
}

BigInt _bigIntFromStored(bool negative, List<int> magStored) {
  final mag = Uint8List(magStored.length);
  for (var i = 0; i < magStored.length; i++) {
    mag[i] = negative ? (~magStored[i]) & 0xFF : magStored[i];
  }
  final v = _bigFromBytes(mag);
  return negative ? -v : v;
}

List<int> _bigEndianBytes(int n) {
  if (n == 0) return [0];
  final out = <int>[];
  while (n > 0) {
    out.insert(0, n & 0xFF);
    n >>= 8;
  }
  return out;
}

/// Big-endian magnitude bytes of a non-negative BigInt (no leading zeros; empty
/// for zero).
Uint8List _magnitudeBytes(BigInt v) {
  if (v.sign == 0) return Uint8List(0);
  final out = <int>[];
  var x = v;
  final mask = BigInt.from(0xFF);
  while (x > BigInt.zero) {
    out.insert(0, (x & mask).toInt());
    x = x >> 8;
  }
  return Uint8List.fromList(out);
}

BigInt _bigFromBytes(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List _leftPad(List<int> bytes, int n) {
  final out = Uint8List(n);
  final off = n - bytes.length;
  for (var i = 0; i < bytes.length; i++) {
    out[off + i] = bytes[i];
  }
  return out;
}

List<int> _trimLeadingZeros(List<int> b) {
  var s = 0;
  while (s < b.length && b[s] == 0) {
    s++;
  }
  return b.sublist(s);
}

int _decodeByte(int b, bool complemented) => complemented ? (~b) & 0xFF : b;

// ---------------------------------------------------------------------------
// Float encode/decode (IEEE-754 total ordering)
// ---------------------------------------------------------------------------

final ByteData _scratch = ByteData(8);

int _orderableF32Bits(double v) {
  int bits;
  if (v.isNaN) {
    bits = 0x7fc00000;
  } else {
    if (v == 0) v = 0.0; // squash -0.0
    _scratch.setFloat32(0, v, Endian.big);
    bits = _scratch.getUint32(0, Endian.big);
  }
  if ((bits & 0x80000000) != 0) {
    return (~bits) & 0xFFFFFFFF;
  }
  return bits ^ 0x80000000;
}

BigInt _orderableF64Bits(double v) {
  BigInt bits;
  if (v.isNaN) {
    bits = BigInt.parse('7ff8000000000000', radix: 16);
  } else {
    if (v == 0) v = 0.0;
    _scratch.setFloat64(0, v, Endian.big);
    bits = (BigInt.from(_scratch.getUint32(0, Endian.big)) << 32) |
        BigInt.from(_scratch.getUint32(4, Endian.big));
  }
  final signBit = BigInt.one << 63;
  if ((bits & signBit) != BigInt.zero) {
    return bits ^ _u64Mask;
  }
  return bits ^ signBit;
}

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;

double _decodeF32(List<int> p) {
  var bits = 0;
  for (final b in p) {
    bits = ((bits << 8) | b) & 0xFFFFFFFF;
  }
  if ((bits & 0x80000000) != 0) {
    bits ^= 0x80000000;
  } else {
    bits = (~bits) & 0xFFFFFFFF;
  }
  _scratch.setUint32(0, bits, Endian.big);
  return _scratch.getFloat32(0, Endian.big);
}

double _decodeF64(List<int> p) {
  var bits = BigInt.zero;
  for (final b in p) {
    bits = (bits << 8) | BigInt.from(b);
  }
  final signBit = BigInt.one << 63;
  if ((bits & signBit) != BigInt.zero) {
    bits ^= signBit;
  } else {
    bits ^= _u64Mask;
  }
  _scratch.setUint32(0, (bits >> 32).toInt(), Endian.big);
  _scratch.setUint32(4, (bits & BigInt.from(0xFFFFFFFF)).toInt(), Endian.big);
  return _scratch.getFloat64(0, Endian.big);
}
