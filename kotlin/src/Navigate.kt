/*
 * Navigation / query over an encoded struple buffer. Mirrors src/navigate.zig
 * and py/struple/_core.py (View / MapView / IndexedMap + Reader cursor).
 *
 * A buffer is a stream of elements; these helpers slice and inspect it without
 * decoding values. Results are sub-slices of the input, each itself a valid
 * struple buffer, so navigation composes and recurses.
 *
 * Stream ops (count/at/head/tail/nthRest/take) operate on the top-level element
 * stream; to descend into an array/map/set use containedItems to get its inner
 * stream, then view that.
 */
package struple

fun view(buf: ByteArray): View = View(buf)

class View(val buf: ByteArray) {

    fun reader(): Reader = Reader(buf)

    /** Number of top-level elements. */
    fun count(): Int {
        val r = reader()
        var n = 0
        while (r.skip()) n++
        return n
    }

    /** The element at [index] as a zero-copy sub-view, or null if out of range. */
    fun at(index: Int): ByteArray? {
        val r = reader()
        var i = 0
        while (true) {
            val v = r.nextView() ?: return null
            if (i == index) return v
            i++
        }
    }

    /** The first element (null if empty). */
    fun head(): ByteArray? = at(0)

    /** Everything after the first element (empty if 0 or 1 elements). */
    fun tail(): ByteArray {
        val r = reader()
        r.nextView()
        return r.rest()
    }

    /** Drop [n] elements; return the remaining stream. */
    fun nthRest(n: Int): ByteArray {
        val r = reader()
        var i = 0
        while (i < n) { if (!r.skip()) break; i++ }
        return r.rest()
    }

    /** The first [n] elements, as a contiguous sub-view. */
    fun take(n: Int): ByteArray {
        val r = reader()
        var i = 0
        while (i < n) { if (!r.skip()) break; i++ }
        return buf.copyOfRange(0, r.pos)
    }

    /** The type code of the first element (null if empty). */
    fun headType(): Int? = if (buf.isNotEmpty()) buf[0].toInt() and 0xFF else null

    fun isNil(): Boolean = headType() == Tc.NIL
    fun isUndefined(): Boolean = headType() == Tc.UNDEF
    fun isBool(): Boolean { val t = headType() ?: return false; return t == Tc.BOOL_FALSE || t == Tc.BOOL_TRUE }
    fun isInt(): Boolean {
        val t = headType() ?: return false
        return t == Tc.INT_ZERO || t == Tc.INT_NEG_BIG || t == Tc.INT_POS_BIG ||
            (t in 0x10..0x1F) || (t in 0x21..0x30)
    }
    fun isFloat(): Boolean { val t = headType(); return t == Tc.FLOAT32 || t == Tc.FLOAT64 }
    fun isDecimal(): Boolean = headType() == Tc.DECIMAL
    fun isNumber(): Boolean = isInt() || isFloat() || isDecimal()
    fun isTimestamp(): Boolean = headType() == Tc.TIMESTAMP
    fun isUuid(): Boolean = headType() == Tc.UUID
    fun isString(): Boolean = headType() == Tc.STRING
    fun isBytes(): Boolean = headType() == Tc.BYTES
    fun isArray(): Boolean = headType() == Tc.ARRAY
    fun isMap(): Boolean = headType() == Tc.MAP
    fun isSet(): Boolean = headType() == Tc.SET
    fun isContainer(): Boolean { val t = headType(); return t == Tc.ARRAY || t == Tc.MAP || t == Tc.SET }

    /**
     * The first element's framed body when it is a container (escapes intact,
     * zero-copy). Null if the head isn't a container. The Reader returns the
     * un-escaped inner stream, so for the framed body we slice it out of the raw
     * element bytes: [type code][escaped body][terminator].
     */
    fun containerBody(): ByteArray? {
        if (!isContainer()) return null
        val raw = reader().nextView() ?: return null
        return raw.copyOfRange(1, raw.size - 1)
    }

    /** The container's inner element stream, un-escaped (null if head isn't a container). */
    fun containedItems(): ByteArray? {
        if (!isContainer()) return null
        return when (val e = reader().next() ?: return null) {
            is Element.Arr -> e.inner
            is Element.MapElem -> e.inner
            is Element.SetElem -> e.inner
            else -> null
        }
    }
}

/**
 * Reads key/value pairs from a map's inner stream (the un-escaped body from
 * View.containedItems). Keys are canonical (sorted), so get early-exits.
 */
class MapView(val inner: ByteArray) {

    fun count(): Int = View(inner).count() / 2

    data class Entry(val key: ByteArray, val value: ByteArray) {
        override fun equals(other: Any?) =
            other is Entry && key.contentEquals(other.key) && value.contentEquals(other.value)
        override fun hashCode() = 31 * key.contentHashCode() + value.contentHashCode()
    }

    fun entries(): List<Entry> {
        val r = Reader(inner)
        val out = ArrayList<Entry>()
        while (true) {
            val k = r.nextView() ?: break
            val v = r.nextView() ?: throw StrupleException("struple: malformed map")
            out.add(Entry(k, v))
        }
        return out
    }

    /** Look up the value bytes for an encoded key element. Ordered scan, early exit. */
    fun get(key: ByteArray): ByteArray? {
        val r = Reader(inner)
        while (true) {
            val k = r.nextView() ?: return null
            val v = r.nextView() ?: throw StrupleException("struple: malformed map")
            when (order(k, key)) {
                0 -> return v
                1 -> return null // gt -> past it (canonical order)
            }
        }
    }

    /** Materialize a random-access index for O(log n) get and O(1) at. */
    fun indexed(): IndexedMap = IndexedMap(inner)
}

/**
 * A map's entries materialized into a random-access index. Building it is one
 * O(n) pass over the inner stream; thereafter get is an O(log n) binary search
 * (canonical key order means a key byte compare IS the sort order) and at is O(1).
 */
class IndexedMap(inner: ByteArray) {
    val entries: List<MapView.Entry>

    init {
        val list = ArrayList<MapView.Entry>()
        val r = Reader(inner)
        while (true) {
            val k = r.nextView() ?: break
            val v = r.nextView() ?: throw StrupleException("struple: malformed map")
            list.add(MapView.Entry(k, v))
        }
        entries = list
    }

    /** Number of entries — O(1). */
    fun count(): Int = entries.size

    /** The entry at [index] in canonical (sorted) order — O(1); null if out of range. */
    fun at(index: Int): MapView.Entry? = if (index in entries.indices) entries[index] else null

    /** The index of [key] in canonical order, or null — O(log n). */
    fun find(key: ByteArray): Int? {
        var lo = 0
        var hi = entries.size
        while (lo < hi) {
            val mid = lo + (hi - lo) / 2
            when (order(entries[mid].key, key)) {
                0 -> return mid
                -1 -> lo = mid + 1
                else -> hi = mid
            }
        }
        return null
    }

    /** Look up the value bytes for an encoded key — O(log n) binary search. */
    fun get(key: ByteArray): ByteArray? {
        val i = find(key) ?: return null
        return entries[i].value
    }

    /** Entries in canonical (sorted) order. */
    fun iterator(): Iterator<MapView.Entry> = entries.iterator()
}
