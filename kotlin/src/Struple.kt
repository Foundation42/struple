/*
 * struple core codec — a faithful, zero-dependency Kotlin/JVM port of the Zig
 * reference (mirrors py/struple/_core.py most closely, since JVM BigInteger /
 * BigDecimal map onto Python's int / Decimal for exactness).
 *
 * The encoded bytes are directly memcmp-comparable: comparing pack(a) and
 * pack(b) as unsigned byte sequences matches the semantic order of a and b. The
 * shared conformance corpus (../conformance/vectors.json) pins byte identity
 * across every language.
 */
package struple

import java.math.BigDecimal
import java.math.BigInteger

// ---------------------------------------------------------------------------
// Type codes. Their numeric order IS the cross-type sort order.
// ---------------------------------------------------------------------------

object Tc {
    const val TERMINATOR = 0x00
    const val NIL = 0x01
    const val UNDEF = 0x02
    const val BOOL_FALSE = 0x05
    const val BOOL_TRUE = 0x06
    const val INT_NEG_BIG = 0x0F // arbitrary-precision negative (beyond i128)
    const val INT_NEG_MIN = 0x10 // widest fixed negative (16-byte magnitude)
    const val INT_NEG_MAX = 0x1F // 1-byte fixed negative
    const val INT_ZERO = 0x20
    const val INT_POS_MIN = 0x21 // 1-byte fixed positive
    const val INT_POS_MAX = 0x30 // widest fixed positive (16-byte magnitude)
    const val INT_POS_BIG = 0x31 // arbitrary-precision positive (beyond i128)
    const val FLOAT32 = 0x34
    const val FLOAT64 = 0x35
    const val DECIMAL = 0x38
    const val TIMESTAMP = 0x40
    const val UUID = 0x44
    const val STRING = 0x48
    const val BYTES = 0x49
    const val ARRAY = 0x50
    const val MAP = 0x52
    const val SET = 0x54
}

// Leading sign markers inside a decimal payload, isolating the three sign groups
// so memcmp keeps negative < zero < positive. For negatives the rest of the
// payload is bit-complemented, so a larger magnitude sorts earlier.
private const val DEC_SIGN_NEG = 0x01
private const val DEC_SIGN_ZERO = 0x02
private const val DEC_SIGN_POS = 0x03

private const val ESCAPE_BYTE = 0xFF

/**
 * Maximum container/JSON nesting depth accepted by the recursive walks (JSON
 * parse, JSON render, semantic compare). Bounds stack use so hostile
 * deeply-nested input is rejected with a StrupleException instead of a
 * StackOverflowError. Mirrors `struple.max_depth` in src/struple.zig; shared
 * across all 12 ports — no real value nests anywhere near this deep.
 */
const val MAX_DEPTH = 256

// The fixed integer slots span the i128 range; values beyond use the big-int codes.
private val I128_MAX: BigInteger = BigInteger.ONE.shiftLeft(127).subtract(BigInteger.ONE)
private val I128_MIN: BigInteger = BigInteger.ONE.shiftLeft(127).negate()
private val MASK64: BigInteger = BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE)
private val SIGN64: BigInteger = BigInteger.ONE.shiftLeft(63)

class StrupleException(message: String) : RuntimeException(message)

// ---------------------------------------------------------------------------
// Decoded element view. The variable-length kinds (String/Bytes/Array/Map/Set)
// carry the already-unescaped content/inner stream.
// ---------------------------------------------------------------------------

sealed class Element {
    object Nil : Element()
    object Undef : Element()
    data class Bool(val value: Boolean) : Element()

    /** Any integer (fixed or arbitrary precision) — value carried as a BigInteger. */
    data class Int(val value: BigInteger) : Element()
    data class Float32(val value: Float) : Element()
    data class Float64(val value: Double) : Element()

    /** Arbitrary-precision base-10 number, carried as a BigDecimal. */
    data class Dec(val value: BigDecimal) : Element()

    /** Microseconds since the Unix epoch, UTC. */
    data class Timestamp(val micros: Long) : Element()

    /** 16 raw bytes (network/big-endian order). */
    data class Uuid(val bytes: ByteArray) : Element() {
        override fun equals(other: Any?) = other is Uuid && bytes.contentEquals(other.bytes)
        override fun hashCode() = bytes.contentHashCode()
    }

    data class Str(val value: String) : Element()
    data class Bin(val value: ByteArray) : Element() {
        override fun equals(other: Any?) = other is Bin && value.contentEquals(other.value)
        override fun hashCode() = value.contentHashCode()
    }

    /** Inner (un-escaped) element stream of an array. */
    data class Arr(val inner: ByteArray) : Element() {
        override fun equals(other: Any?) = other is Arr && inner.contentEquals(other.inner)
        override fun hashCode() = inner.contentHashCode()
    }

    /** Inner (un-escaped) [k][v]... stream of a map (canonical key order). */
    data class MapElem(val inner: ByteArray) : Element() {
        override fun equals(other: Any?) = other is MapElem && inner.contentEquals(other.inner)
        override fun hashCode() = inner.contentHashCode()
    }

    /** Inner (un-escaped) element stream of a set (canonical, deduped). */
    data class SetElem(val inner: ByteArray) : Element() {
        override fun equals(other: Any?) = other is SetElem && inner.contentEquals(other.inner)
        override fun hashCode() = inner.contentHashCode()
    }
}

// ---------------------------------------------------------------------------
// Writer / Packer — builds an encoded tuple
// ---------------------------------------------------------------------------

class Writer {
    private val buf = java.io.ByteArrayOutputStream()

    fun bytes(): ByteArray = buf.toByteArray()

    private fun put(b: Int) = buf.write(b and 0xFF)
    private fun put(bs: ByteArray) = buf.write(bs)

    fun appendNil(): Writer { put(Tc.NIL); return this }
    fun appendUndefined(): Writer { put(Tc.UNDEF); return this }
    fun appendBool(v: Boolean): Writer { put(if (v) Tc.BOOL_TRUE else Tc.BOOL_FALSE); return this }

    fun appendInt(v: Long): Writer { appendLong(buf, v); return this }
    fun appendInt(v: BigInteger): Writer { appendInteger(buf, v); return this }

    fun appendFloat64(v: Double): Writer { appendFloat64(buf, v); return this }
    fun appendFloat32(v: Float): Writer { appendFloat32(buf, v); return this }

    /** Append an arbitrary-precision decimal via a native BigDecimal. */
    fun appendDecimal(v: BigDecimal): Writer {
        val (negative, digits, exp) = decimalToComponents(v)
        appendDecimal(buf, negative, digits, exp)
        return this
    }

    /** Append a decimal from explicit (negative, digits 0-9 MSD-first, exp) components. */
    fun appendDecimal(negative: Boolean, digits: IntArray, exp: Int): Writer {
        appendDecimal(buf, negative, digits, exp)
        return this
    }

    fun appendDecimalString(s: String): Writer { appendDecimalString(buf, s); return this }

    fun appendTimestamp(micros: Long): Writer { appendTimestamp(buf, micros); return this }

    fun appendUuid(raw: ByteArray): Writer {
        if (raw.size != 16) throw StrupleException("struple: uuid must be 16 bytes")
        put(Tc.UUID); put(raw); return this
    }

    fun appendUuid(u: java.util.UUID): Writer {
        val b = ByteArray(16)
        var hi = u.mostSignificantBits
        var lo = u.leastSignificantBits
        for (i in 7 downTo 0) { b[i] = (hi and 0xFF).toByte(); hi = hi ushr 8 }
        for (i in 15 downTo 8) { b[i] = (lo and 0xFF).toByte(); lo = lo ushr 8 }
        return appendUuid(b)
    }

    fun appendString(s: String): Writer { writeFramed(buf, Tc.STRING, s.toByteArray(Charsets.UTF_8)); return this }
    fun appendBytes(b: ByteArray): Writer { writeFramed(buf, Tc.BYTES, b); return this }

    /** Append a nested array given the encoded element stream of its children. */
    fun appendArray(child: ByteArray): Writer { writeFramed(buf, Tc.ARRAY, child); return this }

    /** Append a map from (encodedKey, encodedValue) pairs; sorted into canonical order. */
    fun appendMap(entries: List<Pair<ByteArray, ByteArray>>): Writer { appendMap(buf, entries); return this }

    /** Append a set from element encodings; sorted and de-duplicated into canonical order. */
    fun appendSet(elements: List<ByteArray>): Writer { appendSet(buf, elements); return this }

    /** Convenience dispatch over common Kotlin/Java types. */
    fun append(value: Any?): Writer {
        appendValue(buf, value)
        return this
    }
}

/** Pack a single value alone. */
fun encode(value: Any?): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    appendValue(out, value)
    return out.toByteArray()
}

/** Pack several values into one tuple. */
fun pack(vararg values: Any?): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    for (v in values) appendValue(out, v)
    return out.toByteArray()
}

private fun appendValue(out: java.io.ByteArrayOutputStream, value: Any?) {
    when (value) {
        null -> out.write(Tc.NIL)
        is Boolean -> out.write(if (value) Tc.BOOL_TRUE else Tc.BOOL_FALSE)
        is BigInteger -> appendInteger(out, value)
        is Byte, is Short, is Int, is Long -> appendInteger(out, BigInteger.valueOf((value as Number).toLong()))
        is Float -> appendFloat32(out, value)
        is Double -> appendFloat64(out, value)
        is BigDecimal -> {
            val (negative, digits, exp) = decimalToComponents(value)
            appendDecimal(out, negative, digits, exp)
        }
        is String -> writeFramed(out, Tc.STRING, value.toByteArray(Charsets.UTF_8))
        is ByteArray -> writeFramed(out, Tc.BYTES, value)
        is java.util.UUID -> {
            val b = ByteArray(16)
            var hi = value.mostSignificantBits
            var lo = value.leastSignificantBits
            for (i in 7 downTo 0) { b[i] = (hi and 0xFF).toByte(); hi = hi ushr 8 }
            for (i in 15 downTo 8) { b[i] = (lo and 0xFF).toByte(); lo = lo ushr 8 }
            out.write(Tc.UUID); out.write(b)
        }
        is List<*> -> {
            val child = java.io.ByteArrayOutputStream()
            for (item in value) appendValue(child, item)
            writeFramed(out, Tc.ARRAY, child.toByteArray())
        }
        is Map<*, *> -> {
            val entries = value.entries.map { Pair(encode(it.key), encode(it.value)) }
            appendMap(out, entries)
        }
        is Set<*> -> appendSet(out, value.map { encode(it) })
        else -> throw StrupleException("struple: cannot encode value of type ${value::class.java.name}")
    }
}

// -- integers ---------------------------------------------------------------

// Fixed-path integer encode straight from a Long — no BigInteger allocation
// (a Long always fits the i128 fixed slots). Byte-identical to appendInteger.
private fun appendLong(out: java.io.ByteArrayOutputStream, v: Long) {
    if (v == 0L) { out.write(Tc.INT_ZERO); return }
    val negative = v < 0
    val mag = if (negative) -v else v // unsigned magnitude (wraps for MIN_VALUE)
    if (negative) {
        var n = byteLenLong(mag - 1)
        if (n == 0) n = 1
        out.write(Tc.INT_ZERO - n)
        writeBigEndianLong(out, -mag, n) // low n bytes = 2^(8n) - magnitude
    } else {
        val n = byteLenLong(mag)
        out.write(Tc.INT_ZERO + n)
        writeBigEndianLong(out, mag, n)
    }
}

private fun byteLenLong(magUnsigned: Long): Int =
    if (magUnsigned == 0L) 0 else (64 - java.lang.Long.numberOfLeadingZeros(magUnsigned) + 7) / 8

private fun writeBigEndianLong(out: java.io.ByteArrayOutputStream, value: Long, n: Int) {
    for (i in n - 1 downTo 0) out.write(((value ushr (8 * i)) and 0xFF).toInt())
}

private fun appendInteger(out: java.io.ByteArrayOutputStream, value: BigInteger) {
    if (value.signum() == 0) { out.write(Tc.INT_ZERO); return }
    val negative = value.signum() < 0
    val mag = value.abs()
    if (value >= I128_MIN && value <= I128_MAX) {
        // Fixed slots span the whole i128 range (1-16 byte magnitudes).
        if (negative) {
            val posVal = mag.subtract(BigInteger.ONE)
            var n = (posVal.bitLength() + 7) / 8
            if (n == 0) n = 1
            out.write(Tc.INT_ZERO - n)
            // excess form: 2^(8n) - mag, taken from the low n bytes
            val excess = BigInteger.ONE.shiftLeft(8 * n).subtract(mag)
            out.write(toBytesBE(excess, n))
        } else {
            val n = (mag.bitLength() + 7) / 8
            out.write(Tc.INT_ZERO + n)
            out.write(toBytesBE(mag, n))
        }
        return
    }
    // arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
    out.write(if (negative) Tc.INT_NEG_BIG else Tc.INT_POS_BIG)
    val n = (mag.bitLength() + 7) / 8
    var m = (BigInteger.valueOf(n.toLong()).bitLength() + 7) / 8
    if (m == 0) m = 1
    val comp = { b: Int -> if (negative) b.inv() and 0xFF else b and 0xFF }
    out.write(comp(m))
    for (b in toBytesBE(BigInteger.valueOf(n.toLong()), m)) out.write(comp(b.toInt() and 0xFF))
    for (b in toBytesBE(mag, n)) out.write(comp(b.toInt() and 0xFF))
}

/** Non-negative BigInteger -> exactly n big-endian bytes (left zero-padded). */
private fun toBytesBE(value: BigInteger, n: Int): ByteArray {
    val out = ByteArray(n)
    val raw = value.toByteArray() // two's-complement, may have a leading 0x00 sign byte
    var src = raw.size - 1
    var dst = n - 1
    while (dst >= 0 && src >= 0) { out[dst] = raw[src]; dst--; src-- }
    return out
}

// -- floats -----------------------------------------------------------------

private fun appendFloat64(out: java.io.ByteArrayOutputStream, value: Double) {
    var bits: Long = if (value.isNaN()) {
        0x7FF8000000000000L
    } else {
        val v = if (value == 0.0) 0.0 else value // squash -0.0
        java.lang.Double.doubleToRawLongBits(v)
    }
    bits = if (bits and (1L shl 63) != 0L) bits.inv() else bits xor (1L shl 63)
    out.write(Tc.FLOAT64)
    for (i in 7 downTo 0) out.write(((bits ushr (i * 8)) and 0xFF).toInt())
}

private fun appendFloat32(out: java.io.ByteArrayOutputStream, value: Float) {
    var bits: Int = if (value.isNaN()) {
        0x7FC00000
    } else {
        val v = if (value == 0.0f) 0.0f else value
        java.lang.Float.floatToRawIntBits(v)
    }
    bits = if (bits and (1 shl 31) != 0) bits.inv() else bits xor (1 shl 31)
    out.write(Tc.FLOAT32)
    for (i in 3 downTo 0) out.write((bits ushr (i * 8)) and 0xFF)
}

// -- timestamp / uuid -------------------------------------------------------

private fun appendTimestamp(out: java.io.ByteArrayOutputStream, micros: Long) {
    val bits = micros xor (1L shl 63) // flip sign bit
    out.write(Tc.TIMESTAMP)
    for (i in 7 downTo 0) out.write(((bits ushr (i * 8)) and 0xFF).toInt())
}

// -- decimal ----------------------------------------------------------------

/** A native BigDecimal -> (negative, digits MSD-first, exp) where value = ±C·10^exp. */
internal fun decimalToComponents(value: BigDecimal): Triple<Boolean, IntArray, Int> {
    val unscaled = value.unscaledValue() // coefficient C (signed)
    val exp = -value.scale()             // BigDecimal value = unscaled * 10^(-scale)
    val negative = unscaled.signum() < 0
    val digitsStr = unscaled.abs().toString()
    val digits = if (digitsStr == "0") IntArray(0) else IntArray(digitsStr.length) { digitsStr[it] - '0' }
    return Triple(negative, digits, exp)
}

private fun appendDecimal(out: java.io.ByteArrayOutputStream, negative: Boolean, digits: IntArray, exp: Int) {
    // Strip leading zeros.
    var lead = 0
    while (lead < digits.size && digits[lead] == 0) lead++
    val sig = digits.copyOfRange(lead, digits.size)

    out.write(Tc.DECIMAL)
    if (sig.isEmpty()) { out.write(DEC_SIGN_ZERO); return } // canonical zero

    // Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
    // Trailing zeros change neither value nor E, so drop them for storage.
    val adjExp = BigInteger.valueOf(sig.size.toLong() + exp.toLong())
    var end = sig.size
    while (end > 0 && sig[end - 1] == 0) end--
    val store = sig.copyOfRange(0, end)

    // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
    val tail = java.io.ByteArrayOutputStream()
    appendInteger(tail, adjExp)
    var i = 0
    while (i < store.size) {
        val hi = store[i]
        val lo = if (i + 1 < store.size) store[i + 1] else 0 // pad odd tail with 0
        tail.write(hi * 10 + lo + 1) // pair 0-99 -> byte 1-100
        i += 2
    }
    tail.write(Tc.TERMINATOR)

    out.write(if (negative) DEC_SIGN_NEG else DEC_SIGN_POS)
    val tb = tail.toByteArray()
    if (negative) for (b in tb) out.write((b.toInt() xor 0xFF) and 0xFF)
    else out.write(tb)
}

private fun appendDecimalString(out: java.io.ByteArrayOutputStream, s: String) {
    var i = 0
    val n = s.length
    var negative = false
    if (i < n && (s[i] == '+' || s[i] == '-')) { negative = s[i] == '-'; i++ }
    val digits = ArrayList<Int>()
    var exp = 0
    var seenPoint = false
    var anyDigit = false
    while (i < n) {
        val c = s[i]
        if (c == '.') {
            if (seenPoint) throw StrupleException("struple: invalid decimal")
            seenPoint = true; i++; continue
        }
        if (c == 'e' || c == 'E') break
        if (c < '0' || c > '9') throw StrupleException("struple: invalid decimal")
        digits.add(c - '0')
        if (seenPoint) exp--
        anyDigit = true
        i++
    }
    if (!anyDigit) throw StrupleException("struple: invalid decimal")
    if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        i++
        var esign = 1
        if (i < n && (s[i] == '+' || s[i] == '-')) { if (s[i] == '-') esign = -1; i++ }
        var ev = 0
        var edig = false
        while (i < n) {
            if (s[i] < '0' || s[i] > '9') throw StrupleException("struple: invalid decimal")
            ev = ev * 10 + (s[i] - '0'); edig = true; i++
        }
        if (!edig) throw StrupleException("struple: invalid decimal")
        exp += esign * ev
    }
    appendDecimal(out, negative, digits.toIntArray(), exp)
}

// -- containers / framing ---------------------------------------------------

private fun appendMap(out: java.io.ByteArrayOutputStream, entries: List<Pair<ByteArray, ByteArray>>) {
    val items = entries.sortedWith(compareBy(UnsignedByteArrayComparator) { it.first })
    out.write(Tc.MAP)
    for ((k, v) in items) { writeEscaped(out, k); writeEscaped(out, v) }
    out.write(Tc.TERMINATOR)
}

private fun appendSet(out: java.io.ByteArrayOutputStream, elements: List<ByteArray>) {
    val items = elements.sortedWith(UnsignedByteArrayComparator)
    out.write(Tc.SET)
    var prev: ByteArray? = null
    for (e in items) {
        if (prev != null && prev.contentEquals(e)) continue // skip duplicate
        writeEscaped(out, e)
        prev = e
    }
    out.write(Tc.TERMINATOR)
}

private fun writeFramed(out: java.io.ByteArrayOutputStream, typeCode: Int, content: ByteArray) {
    out.write(typeCode)
    writeEscaped(out, content)
    out.write(Tc.TERMINATOR)
}

private fun writeEscaped(out: java.io.ByteArrayOutputStream, content: ByteArray) {
    for (b in content) {
        out.write(b.toInt() and 0xFF)
        if (b.toInt() and 0xFF == 0x00) out.write(ESCAPE_BYTE)
    }
}

// ---------------------------------------------------------------------------
// Reader — streams elements back out
// ---------------------------------------------------------------------------

class Reader(val buf: ByteArray, var pos: Int = 0) {

    fun done(): Boolean = pos >= buf.size

    private fun byteAt(i: Int): Int = buf[i].toInt() and 0xFF

    fun next(): Element? {
        if (pos >= buf.size) return null
        val t = byteAt(pos); pos++
        return when (t) {
            Tc.NIL -> Element.Nil
            Tc.UNDEF -> Element.Undef
            Tc.BOOL_FALSE -> Element.Bool(false)
            Tc.BOOL_TRUE -> Element.Bool(true)
            Tc.INT_ZERO -> Element.Int(BigInteger.ZERO)
            Tc.INT_NEG_BIG, Tc.INT_POS_BIG -> Element.Int(readBigInt(t))
            Tc.FLOAT32 -> Element.Float32(readF32())
            Tc.FLOAT64 -> Element.Float64(readF64())
            Tc.DECIMAL -> Element.Dec(readDecimal())
            Tc.TIMESTAMP -> Element.Timestamp(readTimestamp())
            Tc.UUID -> Element.Uuid(take(16))
            Tc.STRING -> Element.Str(String(takeFramedUnescaped(), Charsets.UTF_8))
            Tc.BYTES -> Element.Bin(takeFramedUnescaped())
            Tc.ARRAY -> Element.Arr(takeFramedUnescaped())
            Tc.MAP -> Element.MapElem(takeFramedUnescaped())
            Tc.SET -> Element.SetElem(takeFramedUnescaped())
            in 0x10..0x1F, in 0x21..0x30 -> Element.Int(readFixedInt(t))
            else -> throw StrupleException("struple: invalid type code 0x${t.toString(16)}")
        }
    }

    /** The next element's type code without consuming it (null at end). */
    fun peekType(): Int? = if (pos < buf.size) byteAt(pos) else null

    /** The remaining unread bytes (a valid struple stream). */
    fun rest(): ByteArray = buf.copyOfRange(pos, buf.size)

    /** The next element's raw bytes, advancing the cursor (null at end). */
    fun nextView(): ByteArray? {
        val start = pos
        if (next() == null) return null
        return buf.copyOfRange(start, pos)
    }

    /** Advance past the next element; false at end of stream. */
    fun skip(): Boolean = nextView() != null

    private fun take(n: Int): ByteArray {
        // Guard as `n > remaining` (never `pos + n > size`): the addition would
        // overflow Int for an attacker-supplied length before it could be caught.
        // `pos <= buf.size` is a Reader invariant, so `buf.size - pos` never
        // underflows; a negative n (from an overflowed length) is rejected too.
        if (n < 0 || n > buf.size - pos) throw StrupleException("struple: truncated")
        val s = buf.copyOfRange(pos, pos + n)
        pos += n
        return s
    }

    private fun takeFramed(): ByteArray {
        val start = pos
        var i = pos
        while (i < buf.size) {
            if (byteAt(i) == 0x00) {
                if (i + 1 < buf.size && byteAt(i + 1) == ESCAPE_BYTE) { i += 2; continue }
                val s = buf.copyOfRange(start, i)
                pos = i + 1
                return s
            }
            i++
        }
        throw StrupleException("struple: truncated (unterminated framed value)")
    }

    private fun takeFramedUnescaped(): ByteArray = unescape(takeFramed())

    private fun readFixedInt(t: Int): BigInteger {
        val positive = t > Tc.INT_ZERO
        val n = if (positive) t - Tc.INT_ZERO else Tc.INT_ZERO - t
        val payload = take(n)
        // The widest (16-byte) slots can address values outside i128; a canonical
        // encoder uses the big-int codes for those, so reject them here.
        if (n == 16 && ((positive && (payload[0].toInt() and 0xFF) >= 0x80) ||
                (!positive && (payload[0].toInt() and 0xFF) < 0x80))) {
            throw StrupleException("struple: non-canonical 16-byte integer")
        }
        val raw = BigInteger(1, payload)
        return if (positive) raw else raw.subtract(BigInteger.ONE.shiftLeft(8 * n))
    }

    private fun readBigInt(t: Int): BigInteger {
        val negative = t == Tc.INT_NEG_BIG
        val comp = { b: Int -> if (negative) b.inv() and 0xFF else b and 0xFF }
        val m = comp(take(1)[0].toInt() and 0xFF)
        // Length-of-length is capped at 8 bytes: no real magnitude needs a length
        // that doesn't fit in u64, and without this bound `m` (0-255) lets the
        // assembled `n` overflow and address the whole space. The take() bound then
        // rejects any n beyond the buffer cleanly.
        if (m > 8) throw StrupleException("struple: big-int length header too large")
        var n = 0L
        for (b in take(m)) n = (n shl 8) or comp(b.toInt() and 0xFF).toLong()
        // `n` is assembled unsigned into 64 bits; reject before allocating/reading.
        // A negative value here means the top bit is set (n >= 2^63) — astronomically
        // past any real buffer — so treat it (and any n past the buffer) as truncated.
        if (n < 0L || n > (buf.size - pos).toLong()) throw StrupleException("struple: truncated")
        val magBytes = take(n.toInt())
        val mag = ByteArray(magBytes.size) { comp(magBytes[it].toInt() and 0xFF).toByte() }
        val v = BigInteger(1, mag)
        return if (negative) v.negate() else v
    }

    private fun readF64(): Double {
        var bits = 0L
        for (b in take(8)) bits = (bits shl 8) or (b.toLong() and 0xFF)
        bits = if (bits and (1L shl 63) != 0L) bits xor (1L shl 63) else bits.inv()
        return java.lang.Double.longBitsToDouble(bits)
    }

    private fun readF32(): Float {
        var bits = 0
        for (b in take(4)) bits = (bits shl 8) or (b.toInt() and 0xFF)
        bits = if (bits and (1 shl 31) != 0) bits xor (1 shl 31) else bits.inv()
        return java.lang.Float.intBitsToFloat(bits)
    }

    private fun readTimestamp(): Long {
        var raw = 0L
        for (b in take(8)) raw = (raw shl 8) or (b.toLong() and 0xFF)
        return raw xor (1L shl 63)
    }

    private fun readDecimal(): BigDecimal {
        val sign = take(1)[0].toInt() and 0xFF
        if (sign == DEC_SIGN_ZERO) return BigDecimal.ZERO
        if (sign != DEC_SIGN_NEG && sign != DEC_SIGN_POS) throw StrupleException("struple: invalid decimal sign")
        val negative = sign == DEC_SIGN_NEG
        val adjExp = readDecExponent(negative)
        // Digit bytes are 1-100 (positive) or their complement (negative), never the
        // terminator (0x00, or 0xFF when complemented).
        val term = if (negative) 0xFF else 0x00
        val start = pos
        var i = pos
        while (i < buf.size && byteAt(i) != term) i++
        if (i >= buf.size) throw StrupleException("struple: truncated decimal")
        if (i == start) throw StrupleException("struple: nonzero decimal must carry digits")
        val coeffStored = buf.copyOfRange(start, i)
        pos = i + 1 // consume terminator

        // Unpack base-100 coefficient into decimal digits (MSD-first).
        val digits = StringBuilder()
        val last = coeffStored.size - 1
        for ((idx, raw) in coeffStored.withIndex()) {
            val pair = (if (negative) (raw.toInt() xor 0xFF) and 0xFF else raw.toInt() and 0xFF) - 1
            digits.append(('0' + (pair / 10)))
            val lo = pair % 10
            if (!(idx == last && lo == 0)) digits.append(('0' + lo)) // skip synthetic trailing pad
        }
        val exp = adjExp - digits.length
        var coeff = BigInteger(digits.toString())
        if (negative) coeff = coeff.negate()
        // BigDecimal(unscaled, scale) where value = unscaled * 10^(-scale).
        return BigDecimal(coeff, -exp)
    }

    private fun readDecExponent(complement: Boolean): Int {
        val comp = { b: Int -> if (complement) b xor 0xFF else b }
        val tb = comp(take(1)[0].toInt() and 0xFF)
        if (tb == Tc.INT_ZERO) return 0
        if ((tb in 0x10..0x1F) || (tb in 0x21..0x30)) {
            val positive = tb > Tc.INT_ZERO
            val n = if (positive) tb - Tc.INT_ZERO else Tc.INT_ZERO - tb
            val rawBytes = take(n)
            val payload = ByteArray(n) { comp(rawBytes[it].toInt() and 0xFF).toByte() }
            if (n == 16 && ((positive && (payload[0].toInt() and 0xFF) >= 0x80) ||
                    (!positive && (payload[0].toInt() and 0xFF) < 0x80))) {
                throw StrupleException("struple: non-canonical 16-byte decimal exponent")
            }
            val raw = BigInteger(1, payload)
            val v = if (positive) raw else raw.subtract(BigInteger.ONE.shiftLeft(8 * n))
            if (v > BigInteger.valueOf(Int.MAX_VALUE.toLong()) || v < BigInteger.valueOf(Int.MIN_VALUE.toLong())) {
                // BigDecimal can only carry an int scale; reject exponents beyond that.
                throw StrupleException("struple: decimal exponent out of range")
            }
            return v.toInt()
        }
        throw StrupleException("struple: invalid decimal exponent")
    }
}

fun reader(buf: ByteArray): Reader = Reader(buf)

// ---------------------------------------------------------------------------
// transcode — decode every element and re-encode it (round-trip validation)
// ---------------------------------------------------------------------------

fun transcode(data: ByteArray): ByteArray {
    val r = Reader(data)
    val out = java.io.ByteArrayOutputStream()
    while (true) {
        val e = r.next() ?: break
        appendElement(out, e)
    }
    return out.toByteArray()
}

private fun appendElement(out: java.io.ByteArrayOutputStream, e: Element) {
    when (e) {
        is Element.Nil -> out.write(Tc.NIL)
        is Element.Undef -> out.write(Tc.UNDEF)
        is Element.Bool -> out.write(if (e.value) Tc.BOOL_TRUE else Tc.BOOL_FALSE)
        is Element.Int -> appendInteger(out, e.value)
        is Element.Float32 -> appendFloat32(out, e.value)
        is Element.Float64 -> appendFloat64(out, e.value)
        is Element.Dec -> {
            val (negative, digits, exp) = decimalToComponents(e.value)
            appendDecimal(out, negative, digits, exp)
        }
        is Element.Timestamp -> appendTimestamp(out, e.micros)
        is Element.Uuid -> { out.write(Tc.UUID); out.write(e.bytes) }
        is Element.Str -> writeFramed(out, Tc.STRING, e.value.toByteArray(Charsets.UTF_8))
        is Element.Bin -> writeFramed(out, Tc.BYTES, e.value)
        // Container inner streams are already un-escaped; re-frame (which re-escapes).
        is Element.Arr -> writeFramed(out, Tc.ARRAY, e.inner)
        is Element.MapElem -> writeFramed(out, Tc.MAP, e.inner)
        is Element.SetElem -> writeFramed(out, Tc.SET, e.inner)
    }
}

// ---------------------------------------------------------------------------
// Ordering + escaping helpers
// ---------------------------------------------------------------------------

/** Unsigned lexicographic ByteArray comparator — this IS the wire order. */
object UnsignedByteArrayComparator : Comparator<ByteArray> {
    override fun compare(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val d = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (d != 0) return if (d < 0) -1 else 1
        }
        return a.size.compareTo(b.size)
    }
}

/** Lexicographic (unsigned) byte comparison: -1 / 0 / 1. */
fun order(a: ByteArray, b: ByteArray): Int {
    val c = UnsignedByteArrayComparator.compare(a, b)
    return if (c < 0) -1 else if (c > 0) 1 else 0
}

internal fun unescape(framed: ByteArray): ByteArray {
    var has = false
    for (b in framed) if (b.toInt() and 0xFF == 0x00) { has = true; break }
    if (!has) return framed
    val out = java.io.ByteArrayOutputStream(framed.size)
    var i = 0
    while (i < framed.size) {
        out.write(framed[i].toInt() and 0xFF)
        if (framed[i].toInt() and 0xFF == 0x00) i++ // skip the 0xFF companion
        i++
    }
    return out.toByteArray()
}
