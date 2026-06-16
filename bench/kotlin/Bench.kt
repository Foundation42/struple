/*
 * struple reference benchmark (Kotlin / JVM).
 *
 * Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
 * stream from prepared in-memory records) and decode (walk the whole stream,
 * descending and un-escaping every container body and touching every scalar)
 * throughput for the seven shared workloads — four realistic streaming shapes
 * (stock quotes, geospatial points, tweets, blockchain transactions) plus three
 * structural micro-benchmarks (an integer stream, a string stream, a nested
 * document).
 *
 * The native records are parsed from bench/data/<name>.json once (setup,
 * untimed) with a tiny tokenizer for the simple array-of-typed-strings shape;
 * the encoder then rebuilds the bytes with the same appendX sequence the Zig
 * reference uses. Byte-identity is verified against bench/payloads.json (sha256)
 * before any throughput figure is reported.
 *
 * Methodology (per (payload, op)): generous JVM warm-up so the JIT settles
 * (N_WARMUP = 50 runs), auto-calibrate the iteration count to a ~100 ms trial,
 * then 9 trials — the MEDIAN ns/op is reported. A global checksum sink consumes
 * every result so the JIT can't elide the work. Steady-state buffers retain
 * capacity. Single-threaded. System.nanoTime for timing.
 *
 * Zero dependencies beyond the JDK and the struple codec in ../../kotlin/src.
 *
 * Compile + run (from repo root):
 *   KOTLINC="${KOTLINC:-$HOME/kotlin-dist/kotlinc/bin/kotlinc}"
 *   "$KOTLINC" kotlin/src/Struple.kt bench/kotlin/Bench.kt \
 *       -include-runtime -d bench/kotlin/bench.jar
 *   java -cp bench/kotlin/bench.jar BenchKt
 * (run-bench.sh wraps exactly this; paths are resolved relative to the repo root,
 *  which is the parent of bench/, so run from repo root or pass it as argv[0].)
 */

import struple.Reader
import struple.Writer
import struple.Element
import java.io.File
import java.math.BigInteger
import java.security.MessageDigest

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the JIT must
// actually perform the work. A Long accumulator (wrapping 2's-complement add)
// mirrors the Zig `g_sink: u64` exactly (unsigned wraparound == signed wraparound
// over the same bit pattern).
// ---------------------------------------------------------------------------
var gSink: Long = 0L

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

class Dec(@JvmField val digits: IntArray, @JvmField val exp: Int)
class Quote(
    @JvmField val symbol: String,
    @JvmField val bid: Dec,
    @JvmField val ask: Dec,
    @JvmField val last: Double,
    @JvmField val volume: BigInteger,
    @JvmField val ts: Long,
)
class Geo(
    @JvmField val lat: Double,
    @JvmField val lon: Double,
    @JvmField val elevation: Double,
    @JvmField val name: String,
    @JvmField val ts: Long,
)
class Tweet(
    @JvmField val id: BigInteger,
    @JvmField val user: String,
    @JvmField val text: String,
    @JvmField val createdAt: Long,
    @JvmField val likes: BigInteger,
    @JvmField val retweets: BigInteger,
)
class Tx(
    @JvmField val height: BigInteger,
    @JvmField val txHash: ByteArray,
    @JvmField val from: ByteArray,
    @JvmField val to: ByteArray,
    @JvmField val value: BigInteger, // wei; appendInt routes i128 vs big-int by magnitude
    @JvmField val gas: BigInteger,
    @JvmField val nonce: BigInteger,
    @JvmField val ts: Long,
)
class Nested(
    @JvmField val uid: BigInteger,
    @JvmField val name: String,
    @JvmField val active: Boolean,
    @JvmField val scores: Array<BigInteger>,
)

enum class PKind { QUOTES, GEO, TWEETS, TXS, INTS, STRINGS, NESTED }

class PayloadMeta(val kind: PKind, val name: String, val category: String)

val payloads = listOf(
    PayloadMeta(PKind.QUOTES, "stock_quotes", "streaming"),
    PayloadMeta(PKind.GEO, "geo_points", "streaming"),
    PayloadMeta(PKind.TWEETS, "tweets", "streaming"),
    PayloadMeta(PKind.TXS, "blockchain_txs", "streaming"),
    PayloadMeta(PKind.INTS, "int_stream", "structural"),
    PayloadMeta(PKind.STRINGS, "string_stream", "structural"),
    PayloadMeta(PKind.NESTED, "nested_doc", "structural"),
)

class Data(
    @JvmField val quotes: Array<Quote>,
    @JvmField val geo: Array<Geo>,
    @JvmField val tweets: Array<Tweet>,
    @JvmField val txs: Array<Tx>,
    @JvmField val ints: Array<BigInteger>,
    @JvmField val strings: Array<String>,
    @JvmField val nested: Array<Nested>,
)

// ---------------------------------------------------------------------------
// Tiny JSON tokenizer for the SIMPLE data shape: arrays of arrays of quoted
// strings (or, for int_stream/string_stream, a flat array of strings). Only `[`
// `]` `,` and `"`-quoted strings with `\"` / `\\` / `\uXXXX` escapes appear.
// ---------------------------------------------------------------------------

private const val FORM_FEED: Char = 0x0C.toChar()

private class JsonTok(private val s: String) {
    private var i = 0

    private fun ws() {
        while (i < s.length) {
            val c = s[i]
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++ else break
        }
    }

    /** Parse a flat top-level array of strings: ["a","b",...]. */
    fun parseStringArray(): Array<String> {
        val out = ArrayList<String>()
        ws(); expect('[')
        ws()
        if (peek() == ']') { i++; return out.toTypedArray() }
        while (true) {
            ws(); out.add(str()); ws()
            val c = s[i++]
            if (c == ',') continue
            if (c == ']') break
            throw RuntimeException("bench JSON: expected , or ] at $i")
        }
        return out.toTypedArray()
    }

    /** Parse a top-level array of rows, each row a flat array of strings. */
    fun parseRows(): Array<Array<String>> {
        val out = ArrayList<Array<String>>()
        ws(); expect('[')
        ws()
        if (peek() == ']') { i++; return out.toTypedArray() }
        while (true) {
            ws(); out.add(row()); ws()
            val c = s[i++]
            if (c == ',') continue
            if (c == ']') break
            throw RuntimeException("bench JSON: expected , or ] at $i")
        }
        return out.toTypedArray()
    }

    private fun row(): Array<String> {
        val cells = ArrayList<String>()
        ws(); expect('[')
        ws()
        if (peek() == ']') { i++; return cells.toTypedArray() }
        while (true) {
            ws(); cells.add(str()); ws()
            val c = s[i++]
            if (c == ',') continue
            if (c == ']') break
            throw RuntimeException("bench JSON: expected , or ] in row at $i")
        }
        return cells.toTypedArray()
    }

    private fun str(): String {
        if (s[i] != '"') throw RuntimeException("bench JSON: expected string at $i")
        i++ // opening quote
        val sb = StringBuilder()
        while (s[i] != '"') {
            val c = s[i]
            if (c == '\\') {
                i++
                when (s[i]) {
                    '"' -> sb.append('"')
                    '\\' -> sb.append('\\')
                    '/' -> sb.append('/')
                    'b' -> sb.append('\b')
                    'f' -> sb.append(FORM_FEED)
                    'n' -> sb.append('\n')
                    'r' -> sb.append('\r')
                    't' -> sb.append('\t')
                    'u' -> { sb.append(s.substring(i + 1, i + 5).toInt(16).toChar()); i += 4 }
                    else -> throw RuntimeException("bench JSON: bad escape at $i")
                }
                i++
            } else {
                sb.append(c); i++
            }
        }
        i++ // closing quote
        return sb.toString()
    }

    private fun peek(): Char = s[i]
    private fun expect(c: Char) {
        if (s[i] != c) throw RuntimeException("bench JSON: expected '$c' at $i")
        i++
    }
}

// ---------------------------------------------------------------------------
// Parsing helpers — the shared data fields are all typed strings (so any JSON
// library reads them identically across languages). See bench/README.md.
// ---------------------------------------------------------------------------

// 16 hex digits of the IEEE-754 bits (big-endian) -> Double.
private fun f64FromHex(hex: String): Double =
    java.lang.Double.longBitsToDouble(java.lang.Long.parseUnsignedLong(hex, 16))

// digit string "12345" -> [1,2,3,4,5]
private fun digitsFromStr(s: String): IntArray = IntArray(s.length) { s[it] - '0' }

// hex string (even length) -> bytes
private fun bytesFromHex(hex: String): ByteArray {
    val out = ByteArray(hex.length / 2)
    for (k in out.indices) out[k] = hex.substring(k * 2, k * 2 + 2).toInt(16).toByte()
    return out
}

// big-endian hex magnitude -> BigInteger (both `big` and `fix` blockchain paths
// reduce to this: appendInt(BigInteger) routes magnitudes within i128 through the
// fixed slots and beyond i128 through the big-int codes, byte-for-byte identical
// to the Zig appendI128 / appendBigInt split).
private fun bigFromHex(hex: String): BigInteger =
    if (hex.isEmpty()) BigInteger.ZERO else BigInteger(hex, 16)

private fun readData(dataDir: File): Data {
    fun load(name: String): String = File(dataDir, "$name.json").readText(Charsets.UTF_8)

    val quotesRaw = JsonTok(load("stock_quotes")).parseRows()
    val quotes = Array(quotesRaw.size) { idx ->
        val r = quotesRaw[idx]
        Quote(
            symbol = r[0],
            bid = Dec(digitsFromStr(r[1]), r[2].toInt()),
            ask = Dec(digitsFromStr(r[3]), r[4].toInt()),
            last = f64FromHex(r[5]),
            volume = BigInteger(r[6]),
            ts = r[7].toLong(),
        )
    }

    val geoRaw = JsonTok(load("geo_points")).parseRows()
    val geo = Array(geoRaw.size) { idx ->
        val r = geoRaw[idx]
        Geo(
            lat = f64FromHex(r[0]),
            lon = f64FromHex(r[1]),
            elevation = f64FromHex(r[2]),
            name = r[3],
            ts = r[4].toLong(),
        )
    }

    val tweetsRaw = JsonTok(load("tweets")).parseRows()
    val tweets = Array(tweetsRaw.size) { idx ->
        val r = tweetsRaw[idx]
        Tweet(
            id = BigInteger(r[0]),
            user = r[1],
            text = r[2],
            createdAt = r[3].toLong(),
            likes = BigInteger(r[4]),
            retweets = BigInteger(r[5]),
        )
    }

    val txsRaw = JsonTok(load("blockchain_txs")).parseRows()
    val txs = Array(txsRaw.size) { idx ->
        val r = txsRaw[idx]
        // r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both
        // collapse to a BigInteger for appendInt.
        Tx(
            height = BigInteger(r[0]),
            txHash = bytesFromHex(r[1]),
            from = bytesFromHex(r[2]),
            to = bytesFromHex(r[3]),
            value = bigFromHex(r[5]),
            gas = BigInteger(r[6]),
            nonce = BigInteger(r[7]),
            ts = r[8].toLong(),
        )
    }

    val intsRaw = JsonTok(load("int_stream")).parseStringArray()
    val ints = Array(intsRaw.size) { BigInteger(intsRaw[it]) }

    val strings = JsonTok(load("string_stream")).parseStringArray()

    val nestedRaw = JsonTok(load("nested_doc")).parseRows()
    val nested = Array(nestedRaw.size) { idx ->
        val r = nestedRaw[idx]
        Nested(
            active = r[0] == "1",
            uid = BigInteger(r[1]),
            name = r[2],
            scores = arrayOf(BigInteger(r[3]), BigInteger(r[4]), BigInteger(r[5])),
        )
    }

    return Data(quotes, geo, tweets, txs, ints, strings, nested)
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. A fresh `out` Writer per iteration (the JVM
// amortizes the underlying ByteArrayOutputStream growth quickly under JIT); a
// reused `scratch` Writer frames one record at a time. Mirrors encodeOnce in
// bench/zig/bench.zig and bench/js/bench.ts.
//
// The nested-doc map keys never change; the Zig harness re-encodes them per
// record from an arena, but the keys are invariant, so caching them is
// byte-identical and avoids needless work (matches the JS port).
// ---------------------------------------------------------------------------

private val KEY_ACTIVE = Writer().appendString("active").bytes()
private val KEY_SCORES = Writer().appendString("scores").bytes()
private val KEY_USER = Writer().appendString("user").bytes()
private val KEY_ID = Writer().appendString("id").bytes()
private val KEY_NAME = Writer().appendString("name").bytes()

private fun encInt(v: BigInteger): ByteArray = Writer().appendInt(v).bytes()
private fun encStr(s: String): ByteArray = Writer().appendString(s).bytes()
private fun encBool(v: Boolean): ByteArray = Writer().appendBool(v).bytes()

private fun encodeOnce(kind: PKind, d: Data, out: Writer) {
    when (kind) {
        PKind.QUOTES -> for (q in d.quotes) {
            val scratch = Writer()
            scratch.appendString(q.symbol)
            scratch.appendDecimal(false, q.bid.digits, q.bid.exp)
            scratch.appendDecimal(false, q.ask.digits, q.ask.exp)
            scratch.appendFloat64(q.last)
            scratch.appendInt(q.volume)
            scratch.appendTimestamp(q.ts)
            out.appendArray(scratch.bytes())
        }
        PKind.GEO -> for (g in d.geo) {
            val scratch = Writer()
            scratch.appendFloat64(g.lat)
            scratch.appendFloat64(g.lon)
            scratch.appendFloat64(g.elevation)
            scratch.appendString(g.name)
            scratch.appendTimestamp(g.ts)
            out.appendArray(scratch.bytes())
        }
        PKind.TWEETS -> for (t in d.tweets) {
            val scratch = Writer()
            scratch.appendInt(t.id) // u64 id; appendInt(BigInteger) == appendUint here (positive)
            scratch.appendString(t.user)
            scratch.appendString(t.text)
            scratch.appendTimestamp(t.createdAt)
            scratch.appendInt(t.likes)
            scratch.appendInt(t.retweets)
            out.appendArray(scratch.bytes())
        }
        PKind.TXS -> for (x in d.txs) {
            val scratch = Writer()
            scratch.appendInt(x.height)
            scratch.appendBytes(x.txHash)
            scratch.appendBytes(x.from)
            scratch.appendBytes(x.to)
            scratch.appendInt(x.value) // big-int or i128 fixed path, chosen by magnitude
            scratch.appendInt(x.gas)
            scratch.appendInt(x.nonce)
            scratch.appendTimestamp(x.ts)
            out.appendArray(scratch.bytes())
        }
        PKind.INTS -> for (v in d.ints) out.appendInt(v)
        PKind.STRINGS -> for (s in d.strings) out.appendString(s)
        PKind.NESTED -> for (n in d.nested) {
            // user sub-map { id, name }
            val user = Writer().appendMap(
                listOf(
                    KEY_ID to encInt(n.uid),
                    KEY_NAME to encStr(n.name),
                )
            ).bytes()
            // scores array [s0, s1, s2]
            val scoresInner = Writer()
            scoresInner.appendInt(n.scores[0])
            scoresInner.appendInt(n.scores[1])
            scoresInner.appendInt(n.scores[2])
            val scoresArr = Writer().appendArray(scoresInner.bytes()).bytes()
            // top-level map (appendMap sorts by encoded key, so order here is free)
            out.appendMap(
                listOf(
                    KEY_ACTIVE to encBool(n.active),
                    KEY_SCORES to scoresArr,
                    KEY_USER to user,
                )
            )
        }
    }
}

private fun recordCount(kind: PKind, d: Data): Int = when (kind) {
    PKind.QUOTES -> d.quotes.size
    PKind.GEO -> d.geo.size
    PKind.TWEETS -> d.tweets.size
    PKind.TXS -> d.txs.size
    PKind.INTS -> d.ints.size
    PKind.STRINGS -> d.strings.size
    PKind.NESTED -> d.nested.size
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). The Kotlin Reader
// already unescapes each container body in a single pass (Reader.next ->
// takeFramedUnescaped), so descending into Element.Arr/MapElem/SetElem.inner
// does the realistic work without a redundant pre-scan.
// ---------------------------------------------------------------------------

private fun walk(buf: ByteArray) {
    val r = Reader(buf)
    while (true) {
        val el = r.next() ?: break
        when (el) {
            is Element.Nil, is Element.Undef -> {}
            is Element.Bool -> gSink += if (el.value) 1L else 0L
            is Element.Int -> gSink += el.value.toLong() // low 64 bits, matches u64 truncation
            is Element.Float32 -> gSink += (java.lang.Float.floatToRawIntBits(el.value).toLong() and 0xFFFFFFFFL)
            is Element.Float64 -> gSink += java.lang.Double.doubleToRawLongBits(el.value)
            is Element.Dec -> gSink += el.value.unscaledValue().abs().toString().length.toLong()
            is Element.Timestamp -> gSink += el.micros
            is Element.Uuid -> gSink += (el.bytes[0].toLong() and 0xFF)
            is Element.Str -> {
                val len = el.value.length
                gSink += len.toLong()
                if (len > 0) gSink += el.value[0].code.toLong()
            }
            is Element.Bin -> {
                val len = el.value.size
                gSink += len.toLong()
                if (len > 0) gSink += (el.value[0].toLong() and 0xFF)
            }
            is Element.Arr -> walk(el.inner)
            is Element.MapElem -> walk(el.inner)
            is Element.SetElem -> walk(el.inner)
        }
    }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

class Stats(val nsPerOp: Double, val bytes: Int, val records: Int) {
    fun mbPerSec(): Double = (bytes.toDouble() / nsPerOp) * 1000.0 // bytes/ns -> MB/s
    fun mRecPerSec(): Double = (records.toDouble() / nsPerOp) * 1000.0 // rec/ns -> Mrec/s
}

private const val TARGET_TRIAL_NS = 100_000_000L // ~100 ms
private const val N_TRIALS = 9
// Warm up for a time budget (not a fixed count) so the JIT reliably reaches steady
// state on every payload — large and small — before any trial is timed. (Note: the
// encode cost on framed-record payloads is a genuine property of this port's codec,
// not a warm-up artifact; more warm-up does not change it.)
private const val WARMUP_NS = 500_000_000L

private fun median(values: DoubleArray): Double {
    values.sort()
    return values[values.size / 2]
}

private fun buildCanonical(kind: PKind, d: Data): ByteArray {
    val out = Writer()
    encodeOnce(kind, d, out)
    return out.bytes()
}

private fun benchEncode(kind: PKind, d: Data, canonicalLen: Int): Stats {
    val runOnce = {
        val out = Writer()
        encodeOnce(kind, d, out)
        gSink += out.bytes().size.toLong()
    }

    run { val end = System.nanoTime() + WARMUP_NS; while (System.nanoTime() < end) runOnce() }

    var t0 = System.nanoTime()
    runOnce()
    val one = (System.nanoTime() - t0).coerceAtLeast(1L)
    val n = (TARGET_TRIAL_NS / one).coerceAtLeast(1L)

    val trials = DoubleArray(N_TRIALS)
    for (t in 0 until N_TRIALS) {
        t0 = System.nanoTime()
        var j = 0L
        while (j < n) { runOnce(); j++ }
        val dt = System.nanoTime() - t0
        trials[t] = dt.toDouble() / n.toDouble()
    }
    return Stats(median(trials), canonicalLen, recordCount(kind, d))
}

private fun benchDecode(kind: PKind, d: Data, bytes: ByteArray): Stats {
    val runOnce = { walk(bytes) }

    run { val end = System.nanoTime() + WARMUP_NS; while (System.nanoTime() < end) runOnce() }

    var t0 = System.nanoTime()
    runOnce()
    val one = (System.nanoTime() - t0).coerceAtLeast(1L)
    val n = (TARGET_TRIAL_NS / one).coerceAtLeast(1L)

    val trials = DoubleArray(N_TRIALS)
    for (t in 0 until N_TRIALS) {
        t0 = System.nanoTime()
        var j = 0L
        while (j < n) { runOnce(); j++ }
        val dt = System.nanoTime() - t0
        trials[t] = dt.toDouble() / n.toDouble()
    }
    return Stats(median(trials), bytes.size, recordCount(kind, d))
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

private fun hostLabel(): String {
    try {
        File("/proc/cpuinfo").readText(Charsets.UTF_8).split("\n").forEach { line ->
            if (line.startsWith("model name")) {
                val c = line.indexOf(':')
                if (c != -1) return line.substring(c + 1).trim()
            }
        }
    } catch (_: Exception) { /* fall through */ }
    return "unknown"
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

private fun sha256Hex(bytes: ByteArray): String {
    val md = MessageDigest.getInstance("SHA-256")
    val d = md.digest(bytes)
    val sb = StringBuilder(d.size * 2)
    val hex = "0123456789abcdef"
    for (b in d) {
        val v = b.toInt() and 0xFF
        sb.append(hex[v ushr 4])
        sb.append(hex[v and 0xF])
    }
    return sb.toString()
}

private fun round2(x: Double): Double = Math.round(x * 100.0) / 100.0

private class ExpectedMeta(val byteLen: Int, val sha256: String)

// Pull byte_len + sha256 per payload out of payloads.json. The manifest is a
// tiny, fixed-shape JSON object, so simple regex extraction is sufficient (and
// keeps the bench dependency-free).
private fun parseManifest(text: String): Map<String, ExpectedMeta> {
    val result = LinkedHashMap<String, ExpectedMeta>()
    val nameRe = Regex("\"name\"\\s*:\\s*\"([^\"]+)\"")
    val byteLenRe = Regex("\"byte_len\"\\s*:\\s*(\\d+)")
    val shaRe = Regex("\"sha256\"\\s*:\\s*\"([0-9a-fA-F]+)\"")
    val names = nameRe.findAll(text).toList()
    val byteLens = byteLenRe.findAll(text).toList()
    val shas = shaRe.findAll(text).toList()
    for (k in names.indices) {
        result[names[k].groupValues[1]] =
            ExpectedMeta(byteLens[k].groupValues[1].toInt(), shas[k].groupValues[1])
    }
    return result
}

fun main(args: Array<String>) {
    // Resolve the repo root: argv[0] if given, else assume CWD is the repo root
    // (the parent of bench/). Falls back to walking up from CWD to find bench/.
    val repoRoot: File = run {
        if (args.isNotEmpty() && File(args[0], "bench/payloads.json").exists()) return@run File(args[0])
        var dir = File(".").canonicalFile
        while (true) {
            if (File(dir, "bench/payloads.json").exists()) return@run dir
            val parent = dir.parentFile ?: break
            dir = parent
        }
        File(".").canonicalFile
    }
    val benchDir = File(repoRoot, "bench")
    val dataDir = File(benchDir, "data")
    val resultsDir = File(benchDir, "results")

    val manifest = parseManifest(File(benchDir, "payloads.json").readText(Charsets.UTF_8))

    val data = readData(dataDir)

    val rt = System.getProperty("java.runtime.name") ?: "JVM"
    val ver = System.getProperty("java.version") ?: "?"
    println("struple benchmark (Kotlin / $rt $ver, single-threaded)\n")

    val out = LinkedHashMap<String, Map<String, Any>>()
    var allOk = true
    var totalBytes = 0L

    for (meta in payloads) {
        val bytes = buildCanonical(meta.kind, data)
        totalBytes += bytes.size

        val exp = manifest[meta.name]
        val sha = sha256Hex(bytes)
        val shaOk = exp != null && sha == exp.sha256 && bytes.size == exp.byteLen
        if (!shaOk) {
            allOk = false
            System.err.println(
                "\nBYTE MISMATCH for ${meta.name}:\n" +
                    "  produced byte_len=${bytes.size} sha256=$sha\n" +
                    "  expected byte_len=${exp?.byteLen} sha256=${exp?.sha256}\n" +
                    "This is a contract bug — STOPPING (no throughput reported for this payload)."
            )
            out[meta.name] = linkedMapOf(
                "enc_mrec_s" to 0.0, "enc_mb_s" to 0.0,
                "dec_mrec_s" to 0.0, "dec_mb_s" to 0.0, "sha256_ok" to false
            )
            continue
        }

        val enc = benchEncode(meta.kind, data, bytes.size)
        val dec = benchDecode(meta.kind, data, bytes)

        out[meta.name] = linkedMapOf(
            "enc_mrec_s" to round2(enc.mRecPerSec()),
            "enc_mb_s" to round2(enc.mbPerSec()),
            "dec_mrec_s" to round2(dec.mRecPerSec()),
            "dec_mb_s" to round2(dec.mbPerSec()),
            "sha256_ok" to true
        )

        println(
            "  ${meta.name.padEnd(16)} ${enc.records.toString().padStart(6)} rec   " +
                "enc ${"%.2f".format(enc.mRecPerSec()).padStart(7)} Mrec/s ${"%.0f".format(enc.mbPerSec()).padStart(6)} MB/s   " +
                "dec ${"%.2f".format(dec.mRecPerSec()).padStart(7)} Mrec/s ${"%.0f".format(dec.mbPerSec()).padStart(6)} MB/s" +
                "   sha ok"
        )
    }

    val host = hostLabel()
    resultsDir.mkdirs()
    File(resultsDir, "kotlin.json").writeText(renderResultsJson(host, out))

    println(
        "\nHost: $host · Total corpus: ${"%.1f".format(totalBytes / 1024.0)} KB · " +
            "Wrote bench/results/kotlin.json"
    )
    println("(sink ${java.lang.Long.toHexString(gSink)})")

    if (!allOk) {
        System.err.println("\nOne or more payloads failed byte-identity — see above.")
        System.exit(1)
    }
}

// Hand-rolled JSON renderer matching the README results-file format (no JSON
// dependency). Field order mirrors bench/js/bench.ts's output.
private fun renderResultsJson(host: String, payloadsOut: Map<String, Map<String, Any>>): String {
    val sb = StringBuilder()
    sb.append("{\n")
    sb.append("  \"lang\": \"Kotlin\",\n")
    sb.append("  \"host\": \"").append(jsonEscape(host)).append("\",\n")
    sb.append("  \"payloads\": {\n")
    val names = payloadsOut.keys.toList()
    for ((idx, name) in names.withIndex()) {
        val p = payloadsOut[name]!!
        sb.append("    \"").append(jsonEscape(name)).append("\": {\n")
        sb.append("      \"enc_mrec_s\": ").append(numStr(p["enc_mrec_s"]!!)).append(",\n")
        sb.append("      \"enc_mb_s\": ").append(numStr(p["enc_mb_s"]!!)).append(",\n")
        sb.append("      \"dec_mrec_s\": ").append(numStr(p["dec_mrec_s"]!!)).append(",\n")
        sb.append("      \"dec_mb_s\": ").append(numStr(p["dec_mb_s"]!!)).append(",\n")
        sb.append("      \"sha256_ok\": ").append(p["sha256_ok"].toString()).append("\n")
        sb.append("    }").append(if (idx + 1 == names.size) "\n" else ",\n")
    }
    sb.append("  }\n")
    sb.append("}\n")
    return sb.toString()
}

private fun numStr(v: Any): String {
    val d = v as Double
    // Emit integers without a trailing ".0" (matches JSON.stringify of round2 output).
    return if (d == Math.floor(d) && !d.isInfinite()) d.toLong().toString() else d.toString()
}

private fun jsonEscape(s: String): String {
    val sb = StringBuilder()
    for (c in s) when (c) {
        '"' -> sb.append("\\\"")
        '\\' -> sb.append("\\\\")
        else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
    }
    return sb.toString()
}
