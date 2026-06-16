/*
 * Behavioral tests — navigation / IndexedMap (mirroring src/tests.zig
 * "navigate: indexed map …" and the MapView test) plus a few golden / round-trip
 * decimal / uuid / int checks. Prints a summary and exits nonzero on failure.
 */

import struple.*
import java.math.BigDecimal
import java.math.BigInteger

private var pass = 0
private var fail = 0

private fun check(name: String, ok: Boolean, detail: String = "") {
    if (ok) pass++ else { fail++; System.err.println("  FAIL: $name${if (detail.isEmpty()) "" else "  ($detail)"}") }
}

private fun hex(b: ByteArray): String {
    val sb = StringBuilder(b.size * 2)
    for (x in b) sb.append("%02x".format(x.toInt() and 0xFF))
    return sb.toString()
}

private fun packOne(value: Any?): ByteArray = encode(value)

fun main() {
    goldenChecks()
    roundTripChecks()
    mapViewTest()
    indexedMapTest()
    cursorTest()

    println("struple behavioral: passed=$pass failed=$fail")
    if (fail != 0) {
        System.err.println("BEHAVIORAL TESTS FAILED")
        kotlin.system.exitProcess(1)
    }
    println("ALL BEHAVIORAL CHECKS PASSED")
}

// ---------------------------------------------------------------------------
// Golden vectors — pin exact wire bytes (the sanity bytes from the brief).
// ---------------------------------------------------------------------------

private fun goldenChecks() {
    check("golden nil", hex(encode(null)) == "01")
    check("golden false", hex(encode(false)) == "05")
    check("golden true", hex(encode(true)) == "06")
    check("golden 0", hex(encode(0L)) == "20")
    check("golden int 12345", hex(encode(12345L)) == "223039")
    check("golden -1", hex(encode(-1L)) == "1fff")
    check("golden \"app\"", hex(encode("app")) == "4861707000")
    check("golden \"apple\"", hex(encode("apple")) == "486170706c6500")
    // decimal 12.345 -> 380321020d233300
    check("golden decimal 12.345", hex(Writer().appendDecimalString("12.345").bytes()) == "380321020d233300")
    check("golden decimal via BigDecimal", hex(encode(BigDecimal("12.345"))) == "380321020d233300")
    check("golden decimal zero", hex(Writer().appendDecimalString("0").bytes()) == "3802")
    // uuid
    val uuidBytes = "550e8400e29b41d4a716446655440000"
    val raw = ByteArray(16) { uuidBytes.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    check("golden uuid", hex(Writer().appendUuid(raw).bytes()) == "44$uuidBytes")
    val u = java.util.UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
    check("golden uuid native", hex(encode(u)) == "44$uuidBytes")
    // wide int 2^64 (9-byte fixed positive)
    check("golden 2^64", hex(encode(BigInteger.TWO.pow(64))) == "29010000000000000000")
    // big-int positive 2^127 (first big-int)
    check("golden 2^127", hex(encode(BigInteger.TWO.pow(127))) == "31011080000000000000000000000000000000")
}

// ---------------------------------------------------------------------------
// Round-trip: decode(encode(x)) == x for representative values.
// ---------------------------------------------------------------------------

private fun roundTripChecks() {
    // int round-trip across widths and the i128/big-int boundary
    val ints = listOf(
        BigInteger.ZERO, BigInteger.ONE, BigInteger.valueOf(-1), BigInteger.valueOf(12345),
        BigInteger.valueOf(Long.MAX_VALUE), BigInteger.valueOf(Long.MIN_VALUE),
        BigInteger.TWO.pow(64), BigInteger.TWO.pow(127).subtract(BigInteger.ONE),
        BigInteger.TWO.pow(127), BigInteger.TWO.pow(127).negate(),
        BigInteger.TWO.pow(127).negate().subtract(BigInteger.ONE),
        BigInteger.TWO.pow(200), BigInteger.TWO.pow(200).negate()
    )
    for (v in ints) {
        val e = Reader(encode(v)).next() as Element.Int
        check("int round-trip $v", e.value == v, "got ${e.value}")
    }

    // decimal round-trip (canonical equality)
    val decs = listOf("12.345", "-12.345", "100", "0.001", "12.300", "-0.5", "1e-9", "0",
        "123456789012345678901234567890.123456789")
    for (s in decs) {
        val enc = Writer().appendDecimalString(s).bytes()
        val d = Reader(enc).next() as Element.Dec
        // Re-encode the decoded BigDecimal; must reproduce the same canonical bytes.
        check("decimal round-trip $s", hex(encode(d.value)) == hex(enc), "got ${hex(encode(d.value))} want ${hex(enc)}")
    }

    // float round-trip (exact bits)
    val f64s = listOf(1.5, -3.14159, 0.5, 0.1, 1.0e308, -0.0, Double.NaN, Double.POSITIVE_INFINITY)
    for (v in f64s) {
        val e = Reader(encode(v)).next() as Element.Float64
        val ok = if (v.isNaN()) e.value.isNaN() else (e.value == v || (v == 0.0 && e.value == 0.0))
        check("f64 round-trip $v", ok, "got ${e.value}")
    }
    val f32 = 1.5f
    val e32 = Reader(Writer().appendFloat32(f32).bytes()).next() as Element.Float32
    check("f32 round-trip", e32.value == f32)

    // timestamp
    for (t in listOf(0L, 1_000_000L, -1_000_000L, Long.MAX_VALUE, Long.MIN_VALUE)) {
        val e = Reader(Writer().appendTimestamp(t).bytes()).next() as Element.Timestamp
        check("timestamp round-trip $t", e.micros == t, "got ${e.micros}")
    }

    // uuid
    val raw = ByteArray(16) { it.toByte() }
    val eu = Reader(Writer().appendUuid(raw).bytes()).next() as Element.Uuid
    check("uuid round-trip", eu.bytes.contentEquals(raw))

    // string / bytes with embedded NUL escaping
    val bin = byteArrayOf(0, 0xFF.toByte(), 1)
    val eb = Reader(Writer().appendBytes(bin).bytes()).next() as Element.Bin
    check("bytes round-trip with NUL", eb.value.contentEquals(bin))
    val es = Reader(encode("tab\tnewline\n")).next() as Element.Str
    check("string round-trip with escapes", es.value == "tab\tnewline\n")
}

// ---------------------------------------------------------------------------
// MapView — mirrors src/tests.zig "navigate: map …".
// ---------------------------------------------------------------------------

private fun mapViewTest() {
    val ka = packOne("a"); val kb = packOne("b"); val kc = packOne("c"); val kz = packOne("z")
    val v1 = packOne(1L); val v2 = packOne(2L); val v3 = packOne(3L)

    // fed out of order -> canonical
    val mapBytes = Writer().appendMap(listOf(Pair(kc, v3), Pair(ka, v1), Pair(kb, v2))).bytes()
    val mv = view(mapBytes)
    check("map: isMap", mv.isMap())
    val inner = mv.containedItems()!!
    val m = MapView(inner)
    check("map: count", m.count() == 3, "got ${m.count()}")

    check("map: get hit", m.get(kb)!!.contentEquals(v2))
    check("map: get miss past end", m.get(kz) == null)
    check("map: get miss middle", m.get(packOne("aa")) == null)

    val entries = m.entries()
    check("map: iterator order a", entries[0].key.contentEquals(ka))
    check("map: iterator order b", entries[1].key.contentEquals(kb))
    check("map: iterator order c", entries[2].key.contentEquals(kc))
    check("map: iterator size", entries.size == 3)

    // containerBody slices the framed body out of the original buffer
    val body = mv.containerBody()!!
    check("map: containerBody nonempty", body.isNotEmpty())
}

// ---------------------------------------------------------------------------
// IndexedMap — mirrors src/tests.zig "navigate: indexed map …".
// ---------------------------------------------------------------------------

private fun indexedMapTest() {
    // eight entries "a".."h" -> 1..8, fed out of order
    val keys = listOf("h", "c", "a", "g", "d", "f", "b", "e")
    val entries = keys.mapIndexed { i, k -> Pair(packOne(k), packOne((i + 1).toLong())) }
    val mapBytes = Writer().appendMap(entries).bytes()

    val mv = view(mapBytes)
    val inner = mv.containedItems()!!
    val im = IndexedMap(inner)

    check("indexed: count", im.count() == 8, "got ${im.count()}")

    // at() walks canonical (sorted) order a..h
    for ((i, ch) in "abcdefgh".withIndex()) {
        val e = im.at(i)!!
        val k = Reader(e.key).next() as Element.Str
        check("indexed: at($i)==$ch", k.value == ch.toString(), "got ${k.value}")
    }
    check("indexed: at(8) null", im.at(8) == null)

    // get() binary search agrees with linear MapView.get
    val m = MapView(inner)
    for (ch in "abcdefgh") {
        val key = packOne(ch.toString())
        check("indexed: get($ch) parity", im.get(key)!!.contentEquals(m.get(key)!!))
    }
    // "e" was inserted 8th (value 8) but sits at sorted position 4
    check("indexed: find(e)==4", im.find(packOne("e")) == 4, "got ${im.find(packOne("e"))}")
    val ev = Reader(im.get(packOne("e"))!!).next() as Element.Int
    check("indexed: value(e)==8", ev.value == BigInteger.valueOf(8))

    // misses below / between / above
    check("indexed: miss A (below)", im.get(packOne("A")) == null)
    check("indexed: miss cc (between)", im.get(packOne("cc")) == null)
    check("indexed: miss z (above)", im.get(packOne("z")) == null)
    check("indexed: find(a)==0", im.find(packOne("a")) == 0)
    check("indexed: find(h)==7", im.find(packOne("h")) == 7)

    var n = 0
    val it = im.iterator()
    while (it.hasNext()) { it.next(); n++ }
    check("indexed: iterator count", n == 8, "got $n")
}

// ---------------------------------------------------------------------------
// Reader cursor: peekType / nextView / skip / rest, plus View stream ops.
// ---------------------------------------------------------------------------

private fun cursorTest() {
    val tuple = pack("users", 12345L, "alice", true)
    val v = view(tuple)
    check("view: count", v.count() == 4, "got ${v.count()}")
    check("view: headType string", v.headType() == Tc.STRING)
    check("view: isString", v.isString())

    val at1 = v.at(1)!!
    val e1 = Reader(at1).next() as Element.Int
    check("view: at(1)==12345", e1.value == BigInteger.valueOf(12345))

    // take(2) == first two elements; nthRest(2) drops them
    val firstTwo = v.take(2)
    val rest2 = v.nthRest(2)
    check("view: take(2)+nthRest(2)==whole", (firstTwo + rest2).contentEquals(tuple))

    // tail drops the first element
    val tail = v.tail()
    check("view: tail count", view(tail).count() == 3)

    // Reader cursor
    val r = Reader(tuple)
    check("cursor: peekType", r.peekType() == Tc.STRING)
    val nv = r.nextView()!!
    check("cursor: nextView is first elem", nv.contentEquals(v.at(0)!!))
    check("cursor: skip", r.skip()) // skip 12345
    check("cursor: peekType after skip", r.peekType() == Tc.STRING) // "alice"
    val rest = r.rest()
    check("cursor: rest count", view(rest).count() == 2)
}
