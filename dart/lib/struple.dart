/// struple — streaming, lexicographically-ordered tuple packing for Dart.
///
/// A struple value is a stream of self-delimiting, typed elements packed into a
/// byte buffer such that the raw encoded bytes are directly memcmp-comparable:
///
///     compareBytes(pack(a), pack(b)) == the semantic order of a and b
///
/// Drop two packed tuples into any byte-ordered store and they sort correctly
/// with no custom comparator. Pure, zero-dependency Dart port of the Zig
/// reference implementation, byte-identical across all language ports and driven
/// by the shared conformance corpus.
///
/// ```dart
/// final w = Writer()
///   ..appendString(utf8.encode('users'))
///   ..appendInt(12345)
///   ..appendString(utf8.encode('alice'))
///   ..appendBool(true);
/// final key = w.bytes(); // memcmp-orderable bytes
///
/// final r = Reader(key);
/// Element? e;
/// while ((e = r.next()) != null) { /* ... */ }
///
/// compareBytes(keyA, keyB); // -1 / 0 / 1 — that's the comparator
/// ```
library;

export 'src/codec.dart'
    show
        TypeCode,
        Kind,
        Element,
        Decimal,
        Writer,
        Reader,
        StrupleException,
        compare,
        compareBytes,
        transcode,
        unescape;

export 'src/json.dart'
    show
        fromJson,
        toJson,
        formatDouble,
        parseJson,
        JsonValue,
        JsonKind,
        JsonMember;

export 'src/navigate.dart'
    show View, MapView, MapIterator, MapEntry, IndexedMap;

export 'src/semantic.dart' show semanticOrder, semanticEqual;
