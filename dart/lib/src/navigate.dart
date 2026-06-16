// Navigation / query over an encoded struple buffer.
//
// A buffer is a stream of elements; these helpers slice and inspect it without
// decoding values. Everything is zero-copy — results are sub-slices of the
// input, each itself a valid struple buffer, so it all composes and recurses.
//
// Stream ops (count, at, head, tail, nthRest, take) operate on the buffer's
// top-level element stream. To descend into an array/map/set, use
// containedItems to get its inner stream, then view that.

import 'dart:typed_data';

import 'codec.dart';

/// A zero-copy inspector over an encoded struple buffer.
class View {
  final Uint8List bytes;

  View(this.bytes);

  Reader _reader() => Reader(bytes);

  /// The number of top-level elements.
  int count() {
    final r = _reader();
    var n = 0;
    while (r.skip()) {
      n++;
    }
    return n;
  }

  /// The element at [index] as a zero-copy sub-view, or null if out of range.
  Uint8List? at(int index) {
    final r = _reader();
    var i = 0;
    Uint8List? v;
    while ((v = r.nextView()) != null) {
      if (i == index) return v;
      i++;
    }
    return null;
  }

  /// The first element, or null if empty.
  Uint8List? head() => at(0);

  /// Everything after the first element (empty if 0 or 1 elements).
  Uint8List tail() {
    final r = _reader();
    r.nextView();
    return r.rest();
  }

  /// Drops [n] elements and returns the remaining stream.
  Uint8List nthRest(int n) {
    final r = _reader();
    for (var i = 0; i < n; i++) {
      if (!r.skip()) break;
    }
    return r.rest();
  }

  /// The first [n] elements as a contiguous sub-view.
  Uint8List take(int n) {
    final r = _reader();
    for (var i = 0; i < n; i++) {
      if (!r.skip()) break;
    }
    return Uint8List.sublistView(bytes, 0, bytes.length - r.rest().length);
  }

  /// The type code of the first element, or null if empty.
  int? headType() => bytes.isNotEmpty ? bytes[0] : null;

  bool isNil() => headType() == TypeCode.nil;
  bool isUndefined() => headType() == TypeCode.undef;

  bool isBool() {
    final t = headType();
    return t == TypeCode.boolFalse || t == TypeCode.boolTrue;
  }

  bool isInt() {
    final t = headType();
    if (t == null) return false;
    return t == TypeCode.intZero ||
        t == TypeCode.intNegBig ||
        t == TypeCode.intPosBig ||
        (t >= TypeCode.intNegMin && t <= TypeCode.intNegMax) ||
        (t >= TypeCode.intPosMin && t <= TypeCode.intPosMax);
  }

  bool isFloat() {
    final t = headType();
    return t == TypeCode.float32 || t == TypeCode.float64;
  }

  bool isDecimal() => headType() == TypeCode.decimal;

  bool isNumber() => isInt() || isFloat() || isDecimal();

  bool isTimestamp() => headType() == TypeCode.timestamp;
  bool isUuid() => headType() == TypeCode.uuid;
  bool isString() => headType() == TypeCode.string;
  bool isBytes() => headType() == TypeCode.bytes;
  bool isArray() => headType() == TypeCode.array;
  bool isMap() => headType() == TypeCode.map;
  bool isSet() => headType() == TypeCode.set;

  bool isContainer() {
    final t = headType();
    return t == TypeCode.array || t == TypeCode.map || t == TypeCode.set;
  }

  /// The first element's framed body when it is a container (escapes intact,
  /// zero-copy), or null if the head isn't a container.
  Uint8List? containerBody() {
    if (!isContainer()) return null;
    final e = _reader().next();
    if (e == null) return null;
    switch (e.kind) {
      case Kind.array:
      case Kind.map:
      case Kind.set:
        return e.body;
      default:
        return null;
    }
  }

  /// The container's inner element stream, un-escaped (a fresh slice). View it
  /// with [View], or a map with [MapView]. Null if the head isn't a container.
  Uint8List? containedItems() {
    final body = containerBody();
    if (body == null) return null;
    return unescape(body);
  }
}

// ---------------------------------------------------------------------------
// MapView — reads key/value pairs from a map's inner stream
// ---------------------------------------------------------------------------

/// A key/value pair of encoded element views.
class MapEntry {
  final Uint8List key;
  final Uint8List value;
  const MapEntry(this.key, this.value);
}

/// Reads key/value pairs from a map's inner stream (the un-escaped body from
/// [View.containedItems]). Keys are in canonical (sorted) order, so [get]
/// early-exits.
class MapView {
  final Uint8List inner;
  MapView(this.inner);

  /// The number of entries.
  int count() => View(inner).count() ~/ 2;

  /// An iterator over the map's entries in canonical order.
  MapIterator iterator() => MapIterator(Reader(inner));

  /// Looks up [key] (the encoded bytes of a key element). Returns the value's
  /// encoded bytes, or null. Ordered scan with early exit.
  Uint8List? get(Uint8List key) {
    final it = iterator();
    MapEntry? e;
    while ((e = it.next()) != null) {
      final c = compareBytes(e!.key, key);
      if (c == 0) return e.value;
      if (c > 0) return null;
    }
    return null;
  }

  /// Materializes a random-access index for O(log n) get and O(1) at.
  IndexedMap indexed() => IndexedMap(inner);
}

/// Yields entries of a [MapView] in canonical order.
class MapIterator {
  final Reader _r;
  MapIterator(this._r);

  /// The next entry, or null at end of stream.
  MapEntry? next() {
    final k = _r.nextView();
    if (k == null) return null;
    final v = _r.nextView();
    if (v == null) throw const StrupleException('truncated input');
    return MapEntry(k, v);
  }
}

// ---------------------------------------------------------------------------
// IndexedMap — random-access index over a map's entries
// ---------------------------------------------------------------------------

/// Materializes a map's entries into a random-access index. Building it is one
/// O(n) pass over the inner stream; thereafter [get] is an O(log n) binary
/// search (canonical key order means a key compare is the sort order) and [at]
/// is O(1). The entry slices borrow the inner stream, so keep it alive.
class IndexedMap {
  final List<MapEntry> entries;

  IndexedMap._(this.entries);

  /// Builds an index from a map's inner stream (the un-escaped body from
  /// [View.containedItems]).
  factory IndexedMap(Uint8List inner) {
    final list = <MapEntry>[];
    final r = Reader(inner);
    Uint8List? k;
    while ((k = r.nextView()) != null) {
      final v = r.nextView();
      if (v == null) throw const StrupleException('truncated input');
      list.add(MapEntry(k!, v));
    }
    return IndexedMap._(list);
  }

  /// The number of entries — O(1).
  int count() => entries.length;

  /// The entry at [index] in canonical order — O(1), or null if out of range.
  MapEntry? at(int index) {
    if (index < 0 || index >= entries.length) return null;
    return entries[index];
  }

  /// Looks up [key] (an encoded key element) — O(log n). Returns the value's
  /// encoded bytes, or null.
  Uint8List? get(Uint8List key) {
    final i = find(key);
    return i == null ? null : entries[i].value;
  }

  /// The index of [key] in canonical order — O(log n), or null if absent.
  int? find(Uint8List key) {
    var lo = 0;
    var hi = entries.length;
    while (lo < hi) {
      final mid = lo + (hi - lo) ~/ 2;
      final c = compareBytes(entries[mid].key, key);
      if (c == 0) return mid;
      if (c < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return null;
  }

  /// The entries in canonical (sorted) order.
  Iterable<MapEntry> get iterable => entries;
}
