/*
 * Conformance runner — drives the shared corpus (../conformance/vectors.json +
 * ../conformance/semantic_vectors.json) against the Kotlin codec. Mirrors the
 * methodology of c/test_conformance.c and the Zig gen_vectors buildInto op
 * interpreter. Prints a summary and exits nonzero on any failure.
 *
 * CWD must be kotlin/ so the relative ../conformance paths resolve.
 */

import struple.*
import java.io.File
import java.math.BigDecimal
import java.math.BigInteger

// ---------------------------------------------------------------------------
// Tiny standalone JSON reader for the corpus (the package parser is private).
// Numbers are kept as raw token strings so big ints stay lossless.
// ---------------------------------------------------------------------------

private sealed class J {
    object Null : J()
    data class B(val v: Boolean) : J()
    data class Num(val token: String) : J()  // raw token text
    data class S(val v: String) : J()
    data class A(val items: List<J>) : J()
    data class O(val members: List<Pair<String, J>>) : J()
}

private class CorpusJson(private val s: String) {
    private var i = 0
    fun parseTop(): J { ws(); val v = value(); ws(); return v }

    private fun ws() { while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++ }

    private fun value(): J {
        ws()
        return when (s[i]) {
            '{' -> obj()
            '[' -> arr()
            '"' -> J.S(str())
            't' -> { i += 4; J.B(true) }
            'f' -> { i += 5; J.B(false) }
            'n' -> { i += 4; J.Null }
            else -> num()
        }
    }

    private fun obj(): J {
        i++; val m = ArrayList<Pair<String, J>>(); ws()
        if (s[i] == '}') { i++; return J.O(m) }
        while (true) {
            ws(); val k = str(); ws(); i++ /* ':' */; val v = value()
            m.add(Pair(k, v)); ws()
            if (s[i] == ',') { i++; continue }
            i++; break // '}'
        }
        return J.O(m)
    }

    private fun arr(): J {
        i++; val a = ArrayList<J>(); ws()
        if (s[i] == ']') { i++; return J.A(a) }
        while (true) {
            a.add(value()); ws()
            if (s[i] == ',') { i++; continue }
            i++; break // ']'
        }
        return J.A(a)
    }

    private fun str(): String {
        i++ // opening quote
        val sb = StringBuilder()
        while (s[i] != '"') {
            if (s[i] == '\\') {
                i++
                when (s[i]) {
                    '"' -> sb.append('"'); '\\' -> sb.append('\\'); '/' -> sb.append('/')
                    'b' -> sb.append('\b'); 'f' -> sb.append('\u000C'); 'n' -> sb.append('\n')
                    'r' -> sb.append('\r'); 't' -> sb.append('\t')
                    'u' -> { sb.append(s.substring(i + 1, i + 5).toInt(16).toChar()); i += 4 }
                }
                i++
            } else { sb.append(s[i]); i++ }
        }
        i++ // closing quote
        return sb.toString()
    }

    private fun num(): J {
        val start = i
        while (i < s.length && (s[i] in '0'..'9' || s[i] == '-' || s[i] == '+' || s[i] == '.' || s[i] == 'e' || s[i] == 'E')) i++
        return J.Num(s.substring(start, i))
    }
}

// ---------------------------------------------------------------------------
// Build-op interpreter — mirrors gen_vectors.zig buildInto exactly.
// ---------------------------------------------------------------------------

private fun hexDecode(s: String): ByteArray {
    val out = ByteArray(s.length / 2)
    for (k in out.indices) out[k] = s.substring(k * 2, k * 2 + 2).toInt(16).toByte()
    return out
}

private fun buildInto(out: Writer, op: J) {
    op as J.O
    val (key, value) = op.members[0]
    when (key) {
        "nil" -> out.appendNil()
        "undef" -> out.appendUndefined()
        "bool" -> out.appendBool((value as J.B).v)
        "int" -> out.appendInt(BigInteger((value as J.S).v))
        "float64" -> out.appendFloat64(numAsDouble(value))
        "float32" -> out.appendFloat32(numAsDouble(value).toFloat())
        "timestamp" -> out.appendTimestamp((value as J.S).v.toLong())
        "uuid" -> out.appendUuid(hexDecode((value as J.S).v))
        "decimal" -> out.appendDecimalString((value as J.S).v)
        "string" -> out.appendString((value as J.S).v)
        "bytes" -> out.appendBytes(hexDecode((value as J.S).v))
        "array" -> {
            val child = Writer()
            for (item in (value as J.A).items) buildInto(child, item)
            out.appendArray(child.bytes())
        }
        "set" -> {
            val elems = (value as J.A).items.map { val w = Writer(); buildInto(w, it); w.bytes() }
            out.appendSet(elems)
        }
        "map" -> {
            val entries = (value as J.A).items.map { pair ->
                pair as J.A
                val kp = Writer(); buildInto(kp, pair.items[0])
                val vp = Writer(); buildInto(vp, pair.items[1])
                Pair(kp.bytes(), vp.bytes())
            }
            out.appendMap(entries)
        }
        else -> throw RuntimeException("unknown op: $key")
    }
}

private fun numAsDouble(j: J): Double = when (j) {
    is J.Num -> j.token.toDouble()
    is J.S -> j.v.toDouble()
    else -> 0.0
}

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

private fun toHex(b: ByteArray): String {
    val sb = StringBuilder(b.size * 2)
    for (x in b) sb.append("%02x".format(x.toInt() and 0xFF))
    return sb.toString()
}

private fun fromHex(s: String): ByteArray = hexDecode(s)

// ---------------------------------------------------------------------------
// Render a corpus J value back to its canonical JSON text (only what's needed
// for fromJson inputs: numbers stay verbatim tokens).
// ---------------------------------------------------------------------------

private fun jsonText(j: J): String {
    val sb = StringBuilder()
    writeJ(sb, j)
    return sb.toString()
}

private fun writeJ(sb: StringBuilder, j: J) {
    when (j) {
        is J.Null -> sb.append("null")
        is J.B -> sb.append(if (j.v) "true" else "false")
        is J.Num -> sb.append(j.token)
        is J.S -> { sb.append('"'); for (c in j.v) escapeChar(sb, c); sb.append('"') }
        is J.A -> { sb.append('['); j.items.forEachIndexed { k, it -> if (k > 0) sb.append(','); writeJ(sb, it) }; sb.append(']') }
        is J.O -> {
            sb.append('{')
            j.members.forEachIndexed { k, (key, v) ->
                if (k > 0) sb.append(',')
                sb.append('"'); for (c in key) escapeChar(sb, c); sb.append('"'); sb.append(':')
                writeJ(sb, v)
            }
            sb.append('}')
        }
    }
}

private fun escapeChar(sb: StringBuilder, c: Char) {
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

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

private var pass = 0
private var fail = 0

private fun check(name: String, ok: Boolean, detail: String = "") {
    if (ok) pass++ else { fail++; System.err.println("  FAIL: $name${if (detail.isEmpty()) "" else "  ($detail)"}") }
}

fun main() {
    val vectorsText = File("../conformance/vectors.json").readText()
    val semText = File("../conformance/semantic_vectors.json").readText()

    val vectors = (CorpusJson(vectorsText).parseTop() as J.A).items
    var jsonCount = 0
    var buildCount = 0

    for (entry in vectors) {
        entry as J.O
        val byKey = entry.members.toMap()
        val expectedBytes = (byKey["bytes"] as J.S).v

        if (byKey.containsKey("json")) {
            jsonCount++
            val jsonStr = (byKey["json"] as J.S).v
            // fromJson(json) == bytes
            val enc = fromJson(jsonStr)
            check("fromJson $jsonStr", toHex(enc) == expectedBytes, "got ${toHex(enc)} want $expectedBytes")
            // toJson(bytes) == json
            val back = toJson(fromHex(expectedBytes))
            check("toJson $expectedBytes", back == jsonStr, "got $back want $jsonStr")
        } else {
            buildCount++
            val op = byKey["build"]!!
            // encode(build(op)) == bytes
            val w = Writer()
            buildInto(w, op)
            val enc = w.bytes()
            check("build ${jsonText(op)}", toHex(enc) == expectedBytes, "got ${toHex(enc)} want $expectedBytes")
            // transcode(bytes) == bytes
            val tc = transcode(fromHex(expectedBytes))
            check("transcode ${jsonText(op)}", toHex(tc) == expectedBytes, "got ${toHex(tc)} want $expectedBytes")
        }
    }

    // Semantic vectors: semanticOrder(a, b) == order
    val pairs = (CorpusJson(semText).parseTop() as J.A).items
    var semCount = 0
    for (pair in pairs) {
        pair as J.O
        val byKey = pair.members.toMap()
        val a = fromHex((byKey["a"] as J.S).v)
        val b = fromHex((byKey["b"] as J.S).v)
        val want = (byKey["order"] as J.Num).token.toInt()
        val got = semanticOrder(a, b)
        check("semantic ${(byKey["a"] as J.S).v} vs ${(byKey["b"] as J.S).v}", got == want, "got $got want $want")
        semCount++
    }

    // -----------------------------------------------------------------------
    // Malformed / hostile inputs (../conformance/malformed.json). Each case must
    // be rejected with the port's own clean decode error (StrupleException) when
    // the ENTIRE stream is decoded — never a native crash (AIOOBE / RangeError /
    // wrong exception type) and never a silent success. HARDENING items 1,2,5,6,7.
    val malformedText = File("../conformance/malformed.json").readText()
    val malformedTop = CorpusJson(malformedText).parseTop() as J.O
    val cases = (malformedTop.members.toMap()["cases"] as J.A).items
    var mfRejected = 0
    for (c in cases) {
        c as J.O
        val byKey = c.members.toMap()
        val hexStr = (byKey["hex"] as J.S).v
        val note = (byKey["note"] as? J.S)?.v ?: ""
        val bytes = fromHex(hexStr)
        var rejected = false
        try {
            // Walk & re-encode the WHOLE stream; a clean StrupleException is a pass.
            transcode(bytes)
        } catch (e: StrupleException) {
            rejected = true
        } catch (e: Throwable) {
            // Any other throwable (AIOOBE, IllegalArgument, Overflow, …) is a
            // FAILURE: the port must surface its own decode error, not leak a
            // native exception or crash.
            rejected = false
        }
        check("malformed $hexStr", rejected, "expected StrupleException; $note")
        if (rejected) mfRejected++
    }
    println("  malformed: $mfRejected/${cases.size} rejected")

    println("conformance: $jsonCount json vectors (x2), $buildCount build vectors (x2), $semCount semantic pairs")
    println("  passed=$pass failed=$fail")
    if (fail != 0) {
        System.err.println("CONFORMANCE FAILED")
        kotlin.system.exitProcess(1)
    }
    println("ALL CONFORMANCE CHECKS PASSED")
}
