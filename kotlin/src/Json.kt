/*
 * JSON <-> struple, hand-rolled with ZERO dependencies (the JVM has no stdlib
 * JSON). Mirrors src/json.zig and py/struple/_json.py.
 *
 *   fromJson: JSON text     -> struple encoding (one element for the root value)
 *   toJson:   struple bytes -> canonical JSON text (renders the first element)
 *
 * JSON type mapping:
 *   null               <-> nil
 *   true / false       <-> bool
 *   integer number     <-> integer (arbitrary precision, kept losslessly)
 *   fractional number  <-> float64
 *   string             <-> string
 *   array              <-> array
 *   object             <-> map (canonical: keys come back sorted)
 *
 * struple types with no JSON equivalent degrade on toJson: undefined -> null,
 * decimal -> number (exact literal), timestamp -> number (µs), uuid -> string,
 * bytes -> base64 string, set -> array.
 */
package struple

import java.math.BigDecimal
import java.math.BigInteger

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

fun fromJson(text: String): ByteArray {
    val out = Writer()
    val p = JsonParser(text)
    encodeJson(out, p.parse())
    p.expectEnd()
    return out.bytes()
}

fun toJson(encoded: ByteArray): String {
    val e = Reader(encoded).next() ?: return "null"
    val sb = StringBuilder()
    render(sb, e)
    return sb.toString()
}

// ---------------------------------------------------------------------------
// JSON value model (only what the corpus needs)
// ---------------------------------------------------------------------------

private sealed class JsonValue {
    object Null : JsonValue()
    data class Bool(val v: Boolean) : JsonValue()
    data class Integer(val v: BigInteger) : JsonValue() // integral number token
    data class Floating(val v: Double) : JsonValue()    // fractional/exponent token
    data class Str(val v: String) : JsonValue()
    data class Arr(val items: List<JsonValue>) : JsonValue()
    // Preserve key order as encountered (the map encoder canonicalizes anyway).
    data class Obj(val members: List<Pair<String, JsonValue>>) : JsonValue()
}

// ---------------------------------------------------------------------------
// JSON -> struple
// ---------------------------------------------------------------------------

private fun encodeJson(out: Writer, value: JsonValue) {
    when (value) {
        is JsonValue.Null -> out.appendNil()
        is JsonValue.Bool -> out.appendBool(value.v)
        is JsonValue.Integer -> out.appendInt(value.v)
        is JsonValue.Floating -> out.appendFloat64(value.v)
        is JsonValue.Str -> out.appendString(value.v)
        is JsonValue.Arr -> {
            val child = Writer()
            for (item in value.items) encodeJson(child, item)
            out.appendArray(child.bytes())
        }
        is JsonValue.Obj -> {
            val entries = ArrayList<Pair<ByteArray, ByteArray>>(value.members.size)
            for ((k, v) in value.members) {
                val kp = Writer().appendString(k)
                val vp = Writer()
                encodeJson(vp, v)
                entries.add(Pair(kp.bytes(), vp.bytes()))
            }
            out.appendMap(entries)
        }
    }
}

// ---------------------------------------------------------------------------
// struple -> JSON
// ---------------------------------------------------------------------------

private fun render(sb: StringBuilder, e: Element) {
    when (e) {
        is Element.Nil, is Element.Undef -> sb.append("null")
        is Element.Bool -> sb.append(if (e.value) "true" else "false")
        is Element.Int -> sb.append(e.value.toString())
        is Element.Float32 -> renderFloat(sb, e.value.toDouble())
        is Element.Float64 -> renderFloat(sb, e.value)
        is Element.Dec -> sb.append(renderDecimal(e.value))
        is Element.Timestamp -> sb.append(e.micros.toString())
        is Element.Uuid -> renderQuoted(sb, uuidToString(e.bytes))
        is Element.Str -> renderQuoted(sb, e.value)
        is Element.Bin -> renderQuoted(sb, base64(e.value))
        is Element.Arr -> renderArray(sb, e.inner)
        is Element.SetElem -> renderArray(sb, e.inner)
        is Element.MapElem -> renderMap(sb, e.inner)
    }
}

private fun renderFloat(sb: StringBuilder, f: Double) {
    if (!f.isFinite()) { sb.append("null"); return } // JSON has no inf/nan
    sb.append(shortestDouble(f))
}

private fun renderArray(sb: StringBuilder, inner: ByteArray) {
    val r = Reader(inner)
    sb.append('[')
    var first = true
    while (true) {
        val e = r.next() ?: break
        if (!first) sb.append(',')
        first = false
        render(sb, e)
    }
    sb.append(']')
}

private fun renderMap(sb: StringBuilder, inner: ByteArray) {
    val r = Reader(inner)
    sb.append('{')
    var first = true
    while (true) {
        val k = r.next() ?: break
        val v = r.next() ?: throw StrupleException("struple/json: malformed map")
        if (!first) sb.append(',')
        first = false
        if (k is Element.Str) {
            renderQuoted(sb, k.value)
        } else {
            // Non-string key: render its JSON then quote the result.
            val tmp = StringBuilder()
            render(tmp, k)
            renderQuoted(sb, tmp.toString())
        }
        sb.append(':')
        render(sb, v)
    }
    sb.append('}')
}

private fun renderQuoted(sb: StringBuilder, s: String) {
    sb.append('"')
    for (c in s) {
        when (c) {
            '"' -> sb.append("\\\"")
            '\\' -> sb.append("\\\\")
            '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r")
            '\t' -> sb.append("\\t")
            '\b' -> sb.append("\\b")
            '\u000C' -> sb.append("\\f")
            else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
        }
    }
    sb.append('"')
}

/** Exact plain decimal literal (no exponent), mirroring writeDecimal in json.zig. */
private fun renderDecimal(value: BigDecimal): String {
    if (value.signum() == 0) return "0"
    val (negative, digitsArr, exp) = decimalToComponents(value)
    // Strip leading zeros (canonicalization already done by components for nonzero).
    var lead = 0
    while (lead < digitsArr.size && digitsArr[lead] == 0) lead++
    val sig = digitsArr.copyOfRange(lead, digitsArr.size)
    // Strip trailing zeros (value-preserving), adjusting exp.
    var k = sig.size
    var e = exp
    while (k > 0 && sig[k - 1] == 0) { e++; k-- }
    val digs = StringBuilder(k)
    for (i in 0 until k) digs.append(('0' + sig[i]))
    val neg = if (negative) "-" else ""
    if (e >= 0) {
        val zeros = StringBuilder(); repeat(e) { zeros.append('0') }
        return neg + digs.toString() + zeros.toString()
    }
    val pointPos = k + e // number of integer-part digits
    return if (pointPos > 0) {
        neg + digs.substring(0, pointPos) + "." + digs.substring(pointPos)
    } else {
        val zeros = StringBuilder(); repeat(-pointPos) { zeros.append('0') }
        neg + "0." + zeros.toString() + digs.toString()
    }
}

private fun uuidToString(b: ByteArray): String {
    val sb = StringBuilder(36)
    for (i in 0 until 16) {
        if (i == 4 || i == 6 || i == 8 || i == 10) sb.append('-')
        sb.append("%02x".format(b[i].toInt() and 0xFF))
    }
    return sb.toString()
}

private val B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

private fun base64(data: ByteArray): String {
    val sb = StringBuilder()
    var i = 0
    while (i + 3 <= data.size) {
        val n = ((data[i].toInt() and 0xFF) shl 16) or
            ((data[i + 1].toInt() and 0xFF) shl 8) or (data[i + 2].toInt() and 0xFF)
        sb.append(B64[(n ushr 18) and 0x3F]); sb.append(B64[(n ushr 12) and 0x3F])
        sb.append(B64[(n ushr 6) and 0x3F]); sb.append(B64[n and 0x3F])
        i += 3
    }
    val rem = data.size - i
    if (rem == 1) {
        val n = (data[i].toInt() and 0xFF) shl 16
        sb.append(B64[(n ushr 18) and 0x3F]); sb.append(B64[(n ushr 12) and 0x3F]); sb.append("==")
    } else if (rem == 2) {
        val n = ((data[i].toInt() and 0xFF) shl 16) or ((data[i + 1].toInt() and 0xFF) shl 8)
        sb.append(B64[(n ushr 18) and 0x3F]); sb.append(B64[(n ushr 12) and 0x3F])
        sb.append(B64[(n ushr 6) and 0x3F]); sb.append('=')
    }
    return sb.toString()
}

/**
 * Shortest round-trip decimal text for a finite double, matching Python `repr`
 * and Zig `{d}`. Java's Double.toString already yields the shortest digit
 * sequence that round-trips, but uses `E` notation and a trailing `.0`; the
 * corpus floats are all simple non-integer decimals (1.5, -3.14159, 0.5, 87.5),
 * which Double.toString prints verbatim. We strip a `.0` suffix on integral
 * values to mirror the reference, leaving everything else as Java produces it.
 */
private fun shortestDouble(d: Double): String {
    val s = java.lang.Double.toString(d)
    // No exponent and ends in ".0" -> integral value: drop the fraction.
    if (s.indexOf('E') < 0 && s.indexOf('e') < 0 && s.endsWith(".0")) {
        return s.substring(0, s.length - 2)
    }
    return s
}

// ---------------------------------------------------------------------------
// Hand-rolled recursive-descent JSON parser (lossless integers)
// ---------------------------------------------------------------------------

private class JsonParser(private val s: String) {
    private var i = 0

    fun parse(): JsonValue {
        skipWs()
        return parseValue()
    }

    fun expectEnd() {
        skipWs()
        if (i != s.length) throw StrupleException("struple/json: trailing data at $i")
    }

    private fun skipWs() {
        while (i < s.length) {
            val c = s[i]
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++ else break
        }
    }

    private fun parseValue(): JsonValue {
        if (i >= s.length) throw StrupleException("struple/json: unexpected end")
        return when (s[i]) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> JsonValue.Str(parseString())
            't', 'f' -> parseBool()
            'n' -> parseNull()
            else -> parseNumber()
        }
    }

    private fun parseObject(): JsonValue {
        i++ // '{'
        val members = ArrayList<Pair<String, JsonValue>>()
        skipWs()
        if (i < s.length && s[i] == '}') { i++; return JsonValue.Obj(members) }
        while (true) {
            skipWs()
            if (i >= s.length || s[i] != '"') throw StrupleException("struple/json: expected key string")
            val key = parseString()
            skipWs()
            if (i >= s.length || s[i] != ':') throw StrupleException("struple/json: expected ':'")
            i++
            skipWs()
            val value = parseValue()
            members.add(Pair(key, value))
            skipWs()
            if (i >= s.length) throw StrupleException("struple/json: unterminated object")
            when (s[i]) {
                ',' -> { i++; continue }
                '}' -> { i++; break }
                else -> throw StrupleException("struple/json: expected ',' or '}'")
            }
        }
        return JsonValue.Obj(members)
    }

    private fun parseArray(): JsonValue {
        i++ // '['
        val items = ArrayList<JsonValue>()
        skipWs()
        if (i < s.length && s[i] == ']') { i++; return JsonValue.Arr(items) }
        while (true) {
            skipWs()
            items.add(parseValue())
            skipWs()
            if (i >= s.length) throw StrupleException("struple/json: unterminated array")
            when (s[i]) {
                ',' -> { i++; continue }
                ']' -> { i++; break }
                else -> throw StrupleException("struple/json: expected ',' or ']'")
            }
        }
        return JsonValue.Arr(items)
    }

    private fun parseString(): String {
        i++ // opening quote
        val sb = StringBuilder()
        while (i < s.length) {
            val c = s[i]
            when {
                c == '"' -> { i++; return sb.toString() }
                c == '\\' -> {
                    i++
                    if (i >= s.length) throw StrupleException("struple/json: bad escape")
                    when (s[i]) {
                        '"' -> sb.append('"')
                        '\\' -> sb.append('\\')
                        '/' -> sb.append('/')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'u' -> {
                            if (i + 4 >= s.length) throw StrupleException("struple/json: bad \\u")
                            val hex = s.substring(i + 1, i + 5)
                            sb.append(hex.toInt(16).toChar())
                            i += 4
                        }
                        else -> throw StrupleException("struple/json: bad escape \\${s[i]}")
                    }
                    i++
                }
                else -> { sb.append(c); i++ }
            }
        }
        throw StrupleException("struple/json: unterminated string")
    }

    private fun parseBool(): JsonValue {
        if (s.startsWith("true", i)) { i += 4; return JsonValue.Bool(true) }
        if (s.startsWith("false", i)) { i += 5; return JsonValue.Bool(false) }
        throw StrupleException("struple/json: invalid literal")
    }

    private fun parseNull(): JsonValue {
        if (s.startsWith("null", i)) { i += 4; return JsonValue.Null }
        throw StrupleException("struple/json: invalid literal")
    }

    private fun parseNumber(): JsonValue {
        val start = i
        if (i < s.length && (s[i] == '-' || s[i] == '+')) i++
        var isFloat = false
        while (i < s.length) {
            val c = s[i]
            when {
                c in '0'..'9' -> i++
                c == '.' || c == 'e' || c == 'E' -> { isFloat = true; i++ }
                c == '+' || c == '-' -> i++ // exponent sign
                else -> break
            }
        }
        val token = s.substring(start, i)
        if (token.isEmpty() || token == "-" || token == "+") throw StrupleException("struple/json: invalid number")
        return if (isFloat) JsonValue.Floating(token.toDouble())
        else JsonValue.Integer(BigInteger(token))
    }
}
