// Navigation / query over an encoded struple buffer.
//
// A buffer is a stream of elements; these helpers slice and inspect it without
// decoding values. Everything is zero-copy — results are sub-slices of the
// input, each itself a valid struple buffer, so it all composes and recurses.
//
// Stream ops (`count`, `at`, `head`, `tail`, `nthRest`, `take`) operate on the
// buffer's top-level element stream. To descend into an array/map/set, use
// `containedItems` to get its inner stream, then view that.

public func view(_ bytes: [UInt8]) -> View {
    View(bytes[...])
}

public struct View {
    public let bytes: ArraySlice<UInt8>

    public init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }
    public init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

    public func reader() -> Reader { Reader(bytes) }

    /// Number of top-level elements.
    public func count() throws -> Int {
        var r = reader()
        var n = 0
        while try r.skip() { n += 1 }
        return n
    }

    /// The element at `index`, as a zero-copy sub-view (nil if out of range).
    public func at(_ index: Int) throws -> ArraySlice<UInt8>? {
        var r = reader()
        var i = 0
        while let v = try r.nextView() {
            if i == index { return v }
            i += 1
        }
        return nil
    }

    /// The first element (nil if empty).
    public func head() throws -> ArraySlice<UInt8>? { try at(0) }

    /// Everything after the first element (empty if 0 or 1 elements).
    public func tail() throws -> ArraySlice<UInt8> {
        var r = reader()
        _ = try r.nextView()
        return r.rest
    }

    /// Drop `n` elements; return the remaining stream.
    public func nthRest(_ n: Int) throws -> ArraySlice<UInt8> {
        var r = reader()
        var i = 0
        while i < n {
            if try !r.skip() { break }
            i += 1
        }
        return r.rest
    }

    /// The first `n` elements, as a contiguous sub-view.
    public func take(_ n: Int) throws -> ArraySlice<UInt8> {
        var r = reader()
        var i = 0
        while i < n {
            if try !r.skip() { break }
            i += 1
        }
        // r.pos is an index into r's own (copied) buffer; it equals the number of
        // bytes consumed, so prefix that many of this view's bytes.
        return bytes.prefix(r.pos)
    }

    /// The type code of the first element (nil if empty).
    public var headType: UInt8? { bytes.isEmpty ? nil : bytes.first }

    public var isNil: Bool { headType == TypeCode.nilCode }
    public var isUndefined: Bool { headType == TypeCode.undef }
    public var isBool: Bool {
        guard let t = headType else { return false }
        return t == TypeCode.boolFalse || t == TypeCode.boolTrue
    }
    public var isInt: Bool {
        guard let t = headType else { return false }
        return t == TypeCode.intZero || t == TypeCode.intNegBig || t == TypeCode.intPosBig
            || (t >= TypeCode.intNegMin && t <= TypeCode.intNegMax)
            || (t >= TypeCode.intPosMin && t <= TypeCode.intPosMax)
    }
    public var isFloat: Bool {
        guard let t = headType else { return false }
        return t == TypeCode.float32 || t == TypeCode.float64
    }
    public var isDecimal: Bool { headType == TypeCode.decimal }
    public var isNumber: Bool { isInt || isFloat || isDecimal }
    public var isTimestamp: Bool { headType == TypeCode.timestamp }
    public var isUuid: Bool { headType == TypeCode.uuid }
    public var isString: Bool { headType == TypeCode.string }
    public var isBytes: Bool { headType == TypeCode.bytes }
    public var isArray: Bool { headType == TypeCode.array }
    public var isMap: Bool { headType == TypeCode.map }
    public var isSet: Bool { headType == TypeCode.set }
    public var isContainer: Bool {
        guard let t = headType else { return false }
        return t == TypeCode.array || t == TypeCode.map || t == TypeCode.set
    }

    /// The first element's framed body when it is a container (escapes intact,
    /// zero-copy). nil if the head isn't a container.
    public func containerBody() throws -> ArraySlice<UInt8>? {
        if !isContainer { return nil }
        var r = reader()
        guard let e = try r.next() else { return nil }
        switch e {
        case .array(let b), .map(let b), .set(let b): return b
        default: return nil
        }
    }

    /// The container's inner element stream, un-escaped. View it with `view`, or
    /// a map with `MapView`.
    public func containedItems() throws -> [UInt8]? {
        guard let body = try containerBody() else { return nil }
        return unescape(body)
    }
}

/// Reads key/value pairs from a map's *inner* stream (the un-escaped body from
/// `View.containedItems`). Keys are in canonical (sorted) order, so `get`
/// early-exits.
public struct MapView {
    public let inner: [UInt8]

    public init(_ inner: [UInt8]) { self.inner = inner }

    public func count() throws -> Int {
        try View(inner).count() / 2
    }

    public struct Entry {
        public let key: ArraySlice<UInt8>
        public let value: ArraySlice<UInt8>
    }

    public struct Iterator {
        var r: Reader
        public mutating func next() throws -> Entry? {
            guard let k = try r.nextView() else { return nil }
            guard let v = try r.nextView() else { throw StrupleError.truncated }
            return Entry(key: k, value: v)
        }
    }

    public func makeIterator() -> Iterator { Iterator(r: Reader(inner)) }

    /// Look up `key` (the encoded bytes of a key element). Returns the value's
    /// encoded bytes, or nil. Ordered scan with early exit thanks to canonical
    /// key order.
    public func get(_ key: [UInt8]) throws -> ArraySlice<UInt8>? {
        var it = makeIterator()
        while let e = try it.next() {
            switch lexCompare(e.key, key[...]) {
            case 0: return e.value
            case 1: return nil
            default: break
            }
        }
        return nil
    }

    /// Materialize a random-access index for O(log n) `get` and O(1) `at`.
    public func indexed() throws -> IndexedMap {
        try IndexedMap(inner)
    }
}

/// A map's entries materialized into a random-access index. Building it is one
/// O(n) pass over the inner stream; thereafter `get` is an O(log n) binary
/// search (canonical key order means a key memcmp *is* the sort order) and `at`
/// is O(1).
public struct IndexedMap {
    public let entries: [MapView.Entry]

    /// Build the index from a map's *inner* stream (the un-escaped body from
    /// `View.containedItems`).
    public init(_ inner: [UInt8]) throws {
        var list: [MapView.Entry] = []
        var r = Reader(inner)
        while let k = try r.nextView() {
            guard let v = try r.nextView() else { throw StrupleError.truncated }
            list.append(MapView.Entry(key: k, value: v))
        }
        self.entries = list
    }

    /// Number of entries — O(1).
    public var count: Int { entries.count }

    /// The entry at `index` in canonical (sorted) order — O(1); nil if out of range.
    public func at(_ index: Int) -> MapView.Entry? {
        (index >= 0 && index < entries.count) ? entries[index] : nil
    }

    /// Look up `key` (an encoded key element) — O(log n) binary search.
    public func get(_ key: [UInt8]) -> ArraySlice<UInt8>? {
        if let i = find(key) { return entries[i].value }
        return nil
    }

    /// The index of `key` in canonical order, or nil — O(log n).
    public func find(_ key: [UInt8]) -> Int? {
        var lo = 0
        var hi = entries.count
        let k = key[...]
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            switch lexCompare(entries[mid].key, k) {
            case 0: return mid
            case -1: lo = mid + 1
            default: hi = mid
            }
        }
        return nil
    }

    public struct Iterator {
        let entries: [MapView.Entry]
        var i = 0
        public mutating func next() -> MapView.Entry? {
            if i >= entries.count { return nil }
            defer { i += 1 }
            return entries[i]
        }
    }

    /// Entries in canonical (sorted) order.
    public func makeIterator() -> Iterator { Iterator(entries: entries) }
}
