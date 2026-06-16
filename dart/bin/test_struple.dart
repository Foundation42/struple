// Navigation / IndexedMap mirror of src/tests.zig "navigate: indexed map …"
// plus golden / round-trip checks for decimal, uuid, and wide integers.
//
// Prints a summary and exits nonzero on any failure.

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:struple/struple.dart';

int _failures = 0;
int _checks = 0;

void _check(bool ok, String what) {
  _checks++;
  if (!ok) {
    _failures++;
    stderr.writeln('FAIL: $what');
  }
}

String _toHex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _packString(String s) {
  final w = Writer();
  w.appendString(utf8.encode(s));
  return w.bytes();
}

Uint8List _packInt(int n) {
  final w = Writer();
  w.appendInt(n);
  return w.bytes();
}

int _intOf(Uint8List encoded) {
  final e = Reader(encoded).next();
  if (e == null || (e.kind != Kind.int_ && e.kind != Kind.bigInt)) {
    throw StateError('intOf: not an int');
  }
  return e.intValue!.toInt();
}

void _testIndexedMap() {
  // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts.
  final keys = ['h', 'c', 'a', 'g', 'd', 'f', 'b', 'e'];
  final entries = <List<Uint8List>>[];
  for (var i = 0; i < keys.length; i++) {
    entries.add([_packString(keys[i]), _packInt(i + 1)]);
  }
  final w = Writer();
  w.appendMap(entries);

  final mv = View(w.bytes());
  final inner = mv.containedItems();
  _check(inner != null, 'IndexedMap: containedItems non-null');
  final im = IndexedMap(inner!);

  _check(im.count() == 8, 'IndexedMap: count == 8 (got ${im.count()})');

  // At walks canonical (sorted) order: a,b,c,...,h.
  const abc = 'abcdefgh';
  for (var i = 0; i < abc.length; i++) {
    final e = im.at(i);
    _check(e != null, 'IndexedMap: At($i) present');
    if (e != null) {
      final ke = Reader(e.key).next();
      final got = utf8.decode(unescape(ke!.body!));
      _check(got == abc[i], 'IndexedMap: At($i) key = "$got", want "${abc[i]}"');
    }
  }
  _check(im.at(8) == null, 'IndexedMap: At(8) out of range');

  // Get binary-searches; agrees with the linear MapView.Get on every key.
  final m = MapView(inner);
  for (var i = 0; i < abc.length; i++) {
    final key = _packString(abc[i]);
    final want = m.get(key);
    _check(want != null, 'MapView.get("${abc[i]}") present');
    final got = im.get(key);
    _check(got != null && want != null && _toHex(got) == _toHex(want),
        'IndexedMap.get("${abc[i]}") agrees with MapView');
  }

  // "e" was inserted 8th (value 8) but sits at sorted position 4.
  _check(im.find(_packString('e')) == 4, 'IndexedMap: find(e) == 4');
  final ev = im.get(_packString('e'));
  _check(ev != null && _intOf(ev) == 8, 'IndexedMap: get(e) value == 8');

  // Misses: before, between, and after the key range.
  _check(im.get(_packString('A')) == null, 'IndexedMap: get(A) misses (below a)');
  _check(im.get(_packString('cc')) == null,
      'IndexedMap: get(cc) misses (between c and d)');
  _check(im.get(_packString('z')) == null, 'IndexedMap: get(z) misses (above h)');
  _check(im.find(_packString('a')) == 0, 'IndexedMap: find(a) == 0');
  _check(im.find(_packString('h')) == 7, 'IndexedMap: find(h) == 7');

  // Iterator yields the same canonical order.
  var n = 0;
  for (final _ in im.iterable) {
    n++;
  }
  _check(n == 8, 'IndexedMap: iterator yields 8 entries (got $n)');
}

void _testViewStreamOps() {
  final w = Writer();
  w.appendString(utf8.encode('users'));
  w.appendInt(12345);
  w.appendString(utf8.encode('alice'));
  w.appendBool(true);
  final v = View(w.bytes());

  _check(v.count() == 4, 'View: count == 4 (got ${v.count()})');
  _check(v.isString(), 'View: head is a string');
  final at2 = v.at(2);
  _check(at2 != null && View(at2).isString(), 'View: At(2) is a string');
  final head = v.head();
  _check(head != null && toJson(head) == '"users"', 'View: Head == "users"');
  final tail = v.tail();
  _check(View(tail).count() == 3, 'View: Tail count == 3');
  final take2 = v.take(2);
  _check(View(take2).count() == 2, 'View: Take(2) count == 2');
  final rest = v.nthRest(2);
  _check(View(rest).count() == 2, 'View: NthRest(2) count == 2');

  // Predicate sweep over each element type.
  final p = Writer();
  p.appendNil();
  _check(View(p.bytes()).isNil(), 'predicate: isNil');
  p.reset();
  p.appendBool(false);
  _check(View(p.bytes()).isBool(), 'predicate: isBool');
  p.reset();
  p.appendF32(1.5);
  _check(View(p.bytes()).isFloat() && View(p.bytes()).isNumber(),
      'predicate: isFloat/isNumber (f32)');
  p.reset();
  p.appendDecimalString('1.5');
  _check(View(p.bytes()).isDecimal() && View(p.bytes()).isNumber(),
      'predicate: isDecimal/isNumber');
  p.reset();
  p.appendTimestamp(0);
  _check(View(p.bytes()).isTimestamp(), 'predicate: isTimestamp');
  p.reset();
  p.appendUuid(Uint8List(16));
  _check(View(p.bytes()).isUuid(), 'predicate: isUuid');
  p.reset();
  p.appendBytes([1, 2, 3]);
  _check(View(p.bytes()).isBytes(), 'predicate: isBytes');
}

void _testGoldenDecimal() {
  const cases = [
    ['12.345', '380321020d233300'],
    ['-12.345', '3801defdf2dcccff'],
    ['100', '380321030b00'],
    ['0.001', '38031ffe0b00'],
    ['12.300', '380321020d1f00'], // canonicalizes to 12.3
    ['0', '3802'],
    ['1e-9', '38031ff80b00'],
  ];
  for (final c in cases) {
    final w = Writer();
    w.appendDecimalString(c[0]);
    final got = _toHex(w.bytes());
    _check(got == c[1], 'decimal "${c[0]}" = $got, want ${c[1]}');
  }
}

void _testGoldenUuid() {
  final zero = Uint8List(16);
  final w = Writer();
  w.appendUuid(zero);
  final want = '44${'00' * 16}';
  _check(_toHex(w.bytes()) == want, 'zero uuid bytes');
  final js = toJson(w.bytes());
  _check(js == '"00000000-0000-0000-0000-000000000000"', 'zero uuid json = $js');
}

void _testGoldenWideInt() {
  const cases = [
    ['12345', '223039'],
    ['18446744073709551616', '29010000000000000000'], // 2^64
    [
      '170141183460469231731687303715884105728',
      '31011080000000000000000000000000000000',
    ], // 2^127
    [
      '-170141183460469231731687303715884105728',
      '1080000000000000000000000000000000',
    ], // -2^127
  ];
  for (final c in cases) {
    final got = _toHex(fromJson(c[0]));
    _check(got == c[1], 'int "${c[0]}" = $got, want ${c[1]}');
    final back = toJson(fromJson(c[0]));
    _check(back == c[0], 'int "${c[0]}" round-trip = $back');
  }
}

void _testRoundTripBigIntValue() {
  // 2^200 + 1 as a big-int value, packed and decoded exactly.
  final v = (BigInt.one << 200) + BigInt.one;
  final w = Writer();
  w.appendBigIntValue(v);
  final e = Reader(w.bytes()).next();
  _check(e != null && e.intValue == v, 'round-trip big int 2^200+1');
}

void _testAppendString() {
  final w = Writer();
  w.appendString(utf8.encode('app'));
  _check(_toHex(w.bytes()) == '4861707000', '"app" golden bytes');
}

void _testFloatFormatting() {
  // Sanity check the JS-style shortest round-trip formatter.
  const cases = [
    [1.5, '1.5'],
    [-3.14159, '-3.14159'],
    [0.5, '0.5'],
    [87.5, '87.5'],
    [5.0, '5'],
    [100.0, '100'],
    [0.0, '0'],
  ];
  for (final c in cases) {
    final got = formatDouble(c[0] as double);
    _check(got == c[1], 'formatDouble(${c[0]}) = $got, want ${c[1]}');
  }
}

void main() {
  _testIndexedMap();
  _testViewStreamOps();
  _testGoldenDecimal();
  _testGoldenUuid();
  _testGoldenWideInt();
  _testRoundTripBigIntValue();
  _testAppendString();
  _testFloatFormatting();

  stdout.writeln('struple: ${_checks - _failures}/$_checks checks passed');
  if (_failures > 0) {
    stderr.writeln('struple: $_failures FAILURES');
    exit(1);
  }
  stdout.writeln('struple: ALL PASS');
}
