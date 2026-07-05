// JSON <-> struple conversion.
//
//   fromJson: JSON text     -> struple encoding (one element for the root value)
//   toJson:   struple bytes -> canonical JSON text (renders the first element)
//
// JSON type mapping:
//
//   null              <-> nil
//   true / false      <-> bool
//   integer number    <-> integer (arbitrary precision — big JSON ints are kept
//                          losslessly, unlike a JS f64 / Dart int round-trip)
//   fractional number <-> float64
//   string            <-> string
//   array             <-> array
//   object            <-> map (canonical: keys come back sorted)
//
// struple types with no JSON equivalent degrade on toJson: undefined -> null,
// decimal -> number (exact literal), timestamp -> number (µs), uuid ->
// hyphenated string, bytes -> base64 string, set -> array.
//
// Dart's jsonDecode parses integers to native 64-bit ints (which would corrupt
// the corpus's >2^64 values), so this module hand-rolls a small JSON parser
// that keeps number tokens as text -> BigInt.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'codec.dart';

/// Maximum container/JSON nesting depth accepted by the recursive walks (the
/// hand-rolled JSON parse and the JSON render). Bounds stack use so hostile
/// deeply-nested input is rejected instead of overflowing the stack (Item 5).
/// Mirrors the Zig reference's `max_depth`; no real value nests anywhere near
/// this deep.
const int _maxDepth = 256;

/// JSON node kinds for the hand-rolled parser (also used by the conformance
/// runner to read the corpus).
enum JsonKind { nullValue, boolValue, number, string_, array, object }

/// A parsed JSON value. Number tokens are kept as raw text (`numberText`) so
/// arbitrary-precision integers survive losslessly.
class JsonValue {
  final JsonKind kind;
  final bool boolVal;
  final String numberText; // raw token for kind == number
  final String str; // decoded text for kind == string_
  final List<JsonValue> arr;
  final List<JsonMember> obj;

  const JsonValue._({
    required this.kind,
    this.boolVal = false,
    this.numberText = '',
    this.str = '',
    this.arr = const [],
    this.obj = const [],
  });

  static const JsonValue nullV = JsonValue._(kind: JsonKind.nullValue);
  static const JsonValue trueV =
      JsonValue._(kind: JsonKind.boolValue, boolVal: true);
  static const JsonValue falseV =
      JsonValue._(kind: JsonKind.boolValue, boolVal: false);

  /// True if the number token is integer-valued (no '.', 'e' or 'E').
  bool get isIntegerNumber =>
      kind == JsonKind.number &&
      !numberText.contains('.') &&
      !numberText.contains('e') &&
      !numberText.contains('E');
}

class JsonMember {
  final String key;
  final JsonValue val;
  const JsonMember(this.key, this.val);
}

/// Parses JSON text and returns its struple encoding.
Uint8List fromJson(String text) {
  final v = parseJson(text);
  final w = Writer();
  _encodeJson(w, v);
  return w.bytes();
}

/// Renders a struple encoding's first element as canonical JSON text.
String toJson(Uint8List encoded) {
  final e = Reader(encoded).next();
  if (e == null) return 'null';
  final sb = StringBuffer();
  _renderJson(sb, e, 0);
  return sb.toString();
}

// ---------------------------------------------------------------------------
// JSON -> struple
// ---------------------------------------------------------------------------

void _encodeJson(Writer w, JsonValue v) {
  switch (v.kind) {
    case JsonKind.nullValue:
      w.appendNil();
    case JsonKind.boolValue:
      w.appendBool(v.boolVal);
    case JsonKind.number:
      if (v.isIntegerNumber) {
        var digits = v.numberText;
        var negative = false;
        if (digits.startsWith('-')) {
          negative = true;
          digits = digits.substring(1);
        } else if (digits.startsWith('+')) {
          digits = digits.substring(1);
        }
        final mag = BigInt.parse(digits);
        w.appendBigInt(negative, _magBytes(mag));
      } else {
        w.appendF64(double.parse(v.numberText));
      }
    case JsonKind.string_:
      w.appendString(utf8.encode(v.str));
    case JsonKind.array:
      final child = Writer();
      for (final item in v.arr) {
        _encodeJson(child, item);
      }
      w.appendArray(child.bytes());
    case JsonKind.object:
      final entries = <List<Uint8List>>[];
      for (final m in v.obj) {
        final kw = Writer();
        kw.appendString(utf8.encode(m.key));
        final vw = Writer();
        _encodeJson(vw, m.val);
        entries.add([kw.bytes(), vw.bytes()]);
      }
      w.appendMap(entries);
  }
}

Uint8List _magBytes(BigInt v) {
  if (v.sign == 0) return Uint8List(0);
  final out = <int>[];
  var x = v.abs();
  final mask = BigInt.from(0xFF);
  while (x > BigInt.zero) {
    out.insert(0, (x & mask).toInt());
    x = x >> 8;
  }
  return Uint8List.fromList(out);
}

// ---------------------------------------------------------------------------
// struple -> JSON
// ---------------------------------------------------------------------------

void _renderJson(StringBuffer sb, Element e, int depth) {
  // Bound recursion into nested containers so hostile deeply-nested input is
  // rejected rather than overflowing the stack (Item 5).
  if (depth > _maxDepth) {
    throw const StrupleException('JSON nesting too deep');
  }
  switch (e.kind) {
    case Kind.nil:
    case Kind.undefined:
      sb.write('null');
    case Kind.boolean:
      sb.write(e.boolValue ? 'true' : 'false');
    case Kind.int_:
    case Kind.bigInt:
      sb.write(e.intValue!.toString());
    case Kind.float32:
      _renderFloat(sb, e.doubleValue);
    case Kind.float64:
      _renderFloat(sb, e.doubleValue);
    case Kind.decimal:
      _renderDecimal(sb, e.decimalValue!);
    case Kind.timestamp:
      sb.write(e.timestampValue.toString());
    case Kind.uuid:
      _renderString(sb, _renderUuid(e.uuidValue!));
    case Kind.string:
      _renderString(sb, utf8.decode(unescape(e.body!)));
    case Kind.bytes:
      _renderString(sb, _base64Std(unescape(e.body!)));
    case Kind.array:
    case Kind.set:
      _renderArray(sb, e.body!, depth);
    case Kind.map:
      _renderMap(sb, e.body!, depth);
  }
}

void _renderFloat(StringBuffer sb, double f) {
  if (f.isFinite) {
    sb.write(formatDouble(f));
  } else {
    sb.write('null'); // JSON has no inf/nan (matches JSON.stringify)
  }
}

void _renderArray(StringBuffer sb, Uint8List framed, int depth) {
  final r = Reader(unescape(framed));
  sb.write('[');
  var first = true;
  Element? e;
  while ((e = r.next()) != null) {
    if (!first) sb.write(',');
    first = false;
    _renderJson(sb, e!, depth + 1);
  }
  sb.write(']');
}

void _renderMap(StringBuffer sb, Uint8List framed, int depth) {
  final r = Reader(unescape(framed));
  sb.write('{');
  var first = true;
  Element? k;
  while ((k = r.next()) != null) {
    final v = r.next();
    if (v == null) throw const StrupleException('malformed map');
    if (!first) sb.write(',');
    first = false;
    if (k!.kind == Kind.string) {
      _renderString(sb, utf8.decode(unescape(k.body!)));
    } else {
      // Non-string key: render its JSON and quote the result.
      final tmp = StringBuffer();
      _renderJson(tmp, k, depth + 1);
      _renderString(sb, tmp.toString());
    }
    sb.write(':');
    _renderJson(sb, v, depth + 1);
  }
  sb.write('}');
}

void _renderString(StringBuffer sb, String s) {
  sb.write('"');
  for (final c in utf8.encode(s)) {
    switch (c) {
      case 0x22: // "
        sb.write('\\"');
      case 0x5C: // backslash
        sb.write('\\\\');
      case 0x0A:
        sb.write('\\n');
      case 0x0D:
        sb.write('\\r');
      case 0x09:
        sb.write('\\t');
      case 0x08:
        sb.write('\\b');
      case 0x0C:
        sb.write('\\f');
      default:
        if (c < 0x20) {
          sb.write('\\u');
          const hex = '0123456789abcdef';
          sb.write('00');
          sb.write(hex[(c >> 4) & 0xF]);
          sb.write(hex[c & 0xF]);
        } else {
          sb.writeCharCode(c);
        }
    }
  }
  sb.write('"');
}

String _renderUuid(Uint8List u) {
  const hex = '0123456789abcdef';
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
    sb.write(hex[(u[i] >> 4) & 0xF]);
    sb.write(hex[u[i] & 0xF]);
  }
  return sb.toString();
}

/// Renders a decimal as an exact JSON number literal (plain notation, no
/// exponent).
void _renderDecimal(StringBuffer sb, Decimal d) {
  if (d.isZero) {
    sb.write('0');
    return;
  }
  final digs = d.coefficientDigits(); // 0..9 values, most-significant first
  final k = digs.length;
  final exp10 = d.exponent; // value = C * 10^exp10

  if (d.negative) sb.write('-');

  // Plain notation would pad this many zeros; past the threshold, render in
  // scientific notation so a huge (i32-bounded) exponent can't emit gigabytes
  // from a tiny input (Item 2).
  const maxPlainPad = 40;
  final int pad;
  if (exp10 >= 0) {
    pad = exp10;
  } else {
    final pp = k + exp10;
    pad = pp > 0 ? 0 : -pp;
  }
  if (pad > maxPlainPad) {
    // d1[.d2…dk]e±E, where E = exp10 + k − 1 (power of ten of the MSD). The
    // exponent sign is always present (e+/e-), followed by |E|.
    sb.writeCharCode(0x30 + digs[0]);
    if (k > 1) {
      sb.write('.');
      for (var i = 1; i < k; i++) {
        sb.writeCharCode(0x30 + digs[i]);
      }
    }
    final sciExp = exp10 + k - 1;
    sb.write('e');
    sb.write(sciExp >= 0 ? '+' : '-');
    sb.write(sciExp.abs());
    return;
  }

  if (exp10 >= 0) {
    for (final dd in digs) {
      sb.writeCharCode(0x30 + dd);
    }
    for (var z = 0; z < exp10; z++) {
      sb.write('0');
    }
    return;
  }
  final pointPos = k + exp10; // number of integer-part digits
  if (pointPos > 0) {
    for (var i = 0; i < pointPos; i++) {
      sb.writeCharCode(0x30 + digs[i]);
    }
    sb.write('.');
    for (var i = pointPos; i < k; i++) {
      sb.writeCharCode(0x30 + digs[i]);
    }
  } else {
    sb.write('0.');
    for (var z = pointPos; z < 0; z++) {
      sb.write('0');
    }
    for (final dd in digs) {
      sb.writeCharCode(0x30 + dd);
    }
  }
}

const String _b64Table =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _base64Std(Uint8List data) {
  final out = StringBuffer();
  for (var i = 0; i < data.length; i += 3) {
    final b0 = data[i];
    var b1 = 0;
    var b2 = 0;
    var n = 1;
    if (i + 1 < data.length) {
      b1 = data[i + 1];
      n = 2;
    }
    if (i + 2 < data.length) {
      b2 = data[i + 2];
      n = 3;
    }
    final v = (b0 << 16) | (b1 << 8) | b2;
    out.write(_b64Table[(v >> 18) & 63]);
    out.write(_b64Table[(v >> 12) & 63]);
    out.write(n > 1 ? _b64Table[(v >> 6) & 63] : '=');
    out.write(n > 2 ? _b64Table[v & 63] : '=');
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Shortest round-trip double formatting — ECMAScript Number#toString form
// (no trailing ".0", plain decimal where reasonable). Matches the corpus float
// text exactly.
// ---------------------------------------------------------------------------

/// Formats a finite double as JS `Number.prototype.toString` would.
String formatDouble(double v) {
  if (v == 0.0) return '0';
  final neg = v.isNegative;
  final av = v.abs();

  // Dart's toStringAsExponential() with no precision gives the shortest
  // round-tripping significant digits plus an exponent: e.g. "8.75e+1".
  final rep = av.toStringAsExponential();
  final eIdx = rep.indexOf('e');
  var mantissa = rep.substring(0, eIdx);
  final exp = int.parse(rep.substring(eIdx + 1));

  // Significant digits, leading + trailing zeros stripped.
  var digits = mantissa.replaceAll('.', '');
  // Strip any trailing zeros (shortest form normally has none, but be safe).
  var end = digits.length;
  while (end > 1 && digits[end - 1] == '0') {
    end--;
  }
  digits = digits.substring(0, end);
  // pointExp: number of digits before the decimal point in plain notation.
  // mantissa MSD has place value 10^exp, so pointExp = exp + 1.
  final pointExp = exp + 1;

  String out;
  if (pointExp >= -5 && pointExp <= 21) {
    out = _plain(digits, pointExp);
  } else {
    out = _exponential(digits, pointExp);
  }
  return neg ? '-$out' : out;
}

String _plain(String digits, int pointExp) {
  final k = digits.length;
  if (pointExp <= 0) {
    final sb = StringBuffer('0.');
    for (var i = 0; i < -pointExp; i++) {
      sb.write('0');
    }
    sb.write(digits);
    return sb.toString();
  }
  if (pointExp >= k) {
    final sb = StringBuffer(digits);
    for (var i = 0; i < pointExp - k; i++) {
      sb.write('0');
    }
    return sb.toString();
  }
  return '${digits.substring(0, pointExp)}.${digits.substring(pointExp)}';
}

String _exponential(String digits, int pointExp) {
  var e = pointExp - 1; // exponent for d.ddd form
  final sb = StringBuffer();
  sb.write(digits[0]);
  if (digits.length > 1) {
    sb.write('.');
    sb.write(digits.substring(1));
  }
  sb.write('e');
  if (e >= 0) {
    sb.write('+');
  } else {
    sb.write('-');
    e = -e;
  }
  sb.write(e);
  return sb.toString();
}

// ---------------------------------------------------------------------------
// A small JSON parser (no dependencies; keeps number tokens as text)
// ---------------------------------------------------------------------------

/// Parses JSON text into the [JsonValue] model. Number tokens are kept as raw
/// text so arbitrary-precision integers survive losslessly.
JsonValue parseJson(String s) {
  final p = _JsonParser(s);
  final v = p.value(0);
  p.ws();
  if (p.i != p.b.length) {
    throw const StrupleException('trailing data after JSON value');
  }
  return v;
}

class _JsonParser {
  final String b;
  int i = 0;
  _JsonParser(this.b);

  int? _peek() => i < b.length ? b.codeUnitAt(i) : null;

  void ws() {
    while (true) {
      final c = _peek();
      if (c == null ||
          (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) {
        return;
      }
      i++;
    }
  }

  JsonValue value(int depth) {
    // Bound recursion into nested [ / { so hostile deeply-nested JSON is
    // rejected rather than overflowing the stack (Item 5).
    if (depth > _maxDepth) {
      throw const StrupleException('JSON nesting too deep');
    }
    ws();
    final c = _peek();
    if (c == null) throw const StrupleException('unexpected end of input');
    if (c == 0x6E /* n */) {
      _lit('null');
      return JsonValue.nullV;
    }
    if (c == 0x74 /* t */) {
      _lit('true');
      return JsonValue.trueV;
    }
    if (c == 0x66 /* f */) {
      _lit('false');
      return JsonValue.falseV;
    }
    if (c == 0x22 /* " */) {
      return JsonValue._(kind: JsonKind.string_, str: _string());
    }
    if (c == 0x5B /* [ */) return _array(depth);
    if (c == 0x7B /* { */) return _object(depth);
    if (c == 0x2D /* - */ || (c >= 0x30 && c <= 0x39)) return _number();
    throw const StrupleException('unexpected byte in JSON');
  }

  void _lit(String lit) {
    if (i + lit.length <= b.length && b.substring(i, i + lit.length) == lit) {
      i += lit.length;
      return;
    }
    throw StrupleException('expected literal $lit');
  }

  String _string() {
    i++; // opening quote
    final out = StringBuffer();
    while (true) {
      final c = _peek();
      if (c == null) throw const StrupleException('unterminated string');
      i++;
      if (c == 0x22 /* " */) return out.toString();
      if (c == 0x5C /* backslash */) {
        final e = _peek();
        if (e == null) throw const StrupleException('unterminated escape');
        i++;
        switch (e) {
          case 0x22:
            out.write('"');
          case 0x5C:
            out.write('\\');
          case 0x2F:
            out.write('/');
          case 0x6E:
            out.write('\n');
          case 0x74:
            out.write('\t');
          case 0x72:
            out.write('\r');
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x75:
            var cp = _hex4();
            if (cp >= 0xD800 && cp <= 0xDBFF) {
              if (i + 1 < b.length &&
                  b.codeUnitAt(i) == 0x5C &&
                  b.codeUnitAt(i + 1) == 0x75) {
                i += 2;
                final lo = _hex4();
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
              } else {
                throw const StrupleException('lone surrogate');
              }
            }
            out.writeCharCode(cp);
          default:
            throw const StrupleException('bad escape');
        }
      } else {
        out.writeCharCode(c);
      }
    }
  }

  int _hex4() {
    if (i + 4 > b.length) {
      throw const StrupleException('unterminated \\u escape');
    }
    final v = int.parse(b.substring(i, i + 4), radix: 16);
    i += 4;
    return v;
  }

  JsonValue _number() {
    final start = i;
    if (_peek() == 0x2D /* - */) i++;
    while (true) {
      final c = _peek();
      if (c == null || c < 0x30 || c > 0x39) break;
      i++;
    }
    if (_peek() == 0x2E /* . */) {
      i++;
      while (true) {
        final c = _peek();
        if (c == null || c < 0x30 || c > 0x39) break;
        i++;
      }
    }
    final ec = _peek();
    if (ec == 0x65 || ec == 0x45 /* e/E */) {
      i++;
      final sc = _peek();
      if (sc == 0x2B || sc == 0x2D /* +/- */) i++;
      while (true) {
        final c = _peek();
        if (c == null || c < 0x30 || c > 0x39) break;
        i++;
      }
    }
    final tok = b.substring(start, i);
    if (tok.isEmpty || tok == '-') {
      throw const StrupleException('invalid number');
    }
    return JsonValue._(kind: JsonKind.number, numberText: tok);
  }

  JsonValue _array(int depth) {
    i++; // [
    final items = <JsonValue>[];
    ws();
    if (_peek() == 0x5D /* ] */) {
      i++;
      return JsonValue._(kind: JsonKind.array, arr: items);
    }
    while (true) {
      items.add(value(depth + 1));
      ws();
      final c = _peek();
      if (c == null) throw const StrupleException('expected , or ]');
      if (c == 0x2C /* , */) {
        i++;
        continue;
      }
      if (c == 0x5D /* ] */) {
        i++;
        break;
      }
      throw const StrupleException('expected , or ]');
    }
    return JsonValue._(kind: JsonKind.array, arr: items);
  }

  JsonValue _object(int depth) {
    i++; // {
    final members = <JsonMember>[];
    ws();
    if (_peek() == 0x7D /* } */) {
      i++;
      return JsonValue._(kind: JsonKind.object, obj: members);
    }
    while (true) {
      ws();
      if (_peek() != 0x22 /* " */) {
        throw const StrupleException('expected object key');
      }
      final key = _string();
      ws();
      if (_peek() != 0x3A /* : */) {
        throw const StrupleException('expected :');
      }
      i++;
      final val = value(depth + 1);
      members.add(JsonMember(key, val));
      ws();
      final c = _peek();
      if (c == null) throw const StrupleException('expected , or }');
      if (c == 0x2C /* , */) {
        i++;
        continue;
      }
      if (c == 0x7D /* } */) {
        i++;
        break;
      }
      throw const StrupleException('expected , or }');
    }
    return JsonValue._(kind: JsonKind.object, obj: members);
  }
}
