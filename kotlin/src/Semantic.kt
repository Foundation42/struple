/*
 * Semantic (value-based) ordering over encoded struple streams. Mirrors
 * src/semantic.zig and py/struple/_core.py.
 *
 * order(a, b) gives the raw memcmp order (the type byte dominates, so an integer
 * and a float never interleave by magnitude). semanticOrder instead compares by
 * VALUE — int, big-int, float32, float64 and decimal all compare by their exact
 * mathematical value, so int 5 == float 5.0, int 2^53+1 > float 2^53, decimal
 * 0.1 < float 0.1, with no precision loss.
 *
 * Cross-type order (when the two values aren't both numbers):
 *   nil < undefined < bool < number < timestamp < uuid < string < bytes
 *       < array < map < set
 * NaN sorts greatest; -0.0 == 0.0 == int 0; containers recurse element-wise.
 *
 * Exactness strategy (the JVM equivalent of Python's Fraction): a finite double's
 * true value is BigDecimal(double); int/big-int and decimal are already exact as
 * BigDecimal. BigDecimal.compareTo is then an exact rational comparison.
 */
package struple

import java.math.BigDecimal

/** Compare two encoded streams element-by-element by semantic value: -1 / 0 / 1. */
fun semanticOrder(a: ByteArray, b: ByteArray): Int = semanticOrderDepth(a, b, 0)

private fun semanticOrderDepth(a: ByteArray, b: ByteArray, depth: Int): Int {
    // Bound recursion into nested containers so hostile deeply-nested input is
    // rejected rather than overflowing the stack (mirrors semanticOrderDepth in
    // semantic.zig).
    if (depth > MAX_DEPTH) throw StrupleException("struple/semantic: nesting too deep")
    val ra = Reader(a)
    val rb = Reader(b)
    while (true) {
        val ea = ra.next()
        val eb = rb.next()
        if (ea == null && eb == null) return 0
        if (ea == null) return -1 // a is a prefix of b
        if (eb == null) return 1
        val c = compareElements(ea, eb, depth)
        if (c != 0) return c
    }
}

/** Semantic equality — semanticOrder(...) == 0. */
fun semanticEqual(a: ByteArray, b: ByteArray): Boolean = semanticOrder(a, b) == 0

private fun classRank(e: Element): Int = when (e) {
    is Element.Nil -> 0
    is Element.Undef -> 1
    is Element.Bool -> 2
    is Element.Int, is Element.Float32, is Element.Float64, is Element.Dec -> 3 // unified number class
    is Element.Timestamp -> 4
    is Element.Uuid -> 5
    is Element.Str -> 6
    is Element.Bin -> 7
    is Element.Arr -> 8
    is Element.MapElem -> 9
    is Element.SetElem -> 10
}

private fun sign(x: Int): Int = if (x < 0) -1 else if (x > 0) 1 else 0

private fun compareElements(a: Element, b: Element, depth: Int): Int {
    val ra = classRank(a)
    val rb = classRank(b)
    if (ra != rb) return sign(ra - rb)
    return when (a) {
        is Element.Nil, is Element.Undef -> 0
        is Element.Bool -> sign((if (a.value) 1 else 0) - (if ((b as Element.Bool).value) 1 else 0))
        is Element.Int, is Element.Float32, is Element.Float64, is Element.Dec -> compareNumbers(a, b)
        is Element.Timestamp -> a.micros.compareTo((b as Element.Timestamp).micros)
        is Element.Uuid -> order(a.bytes, (b as Element.Uuid).bytes)
        // string/bytes content order == UTF-8 / raw byte order.
        is Element.Str -> order(a.value.toByteArray(Charsets.UTF_8), (b as Element.Str).value.toByteArray(Charsets.UTF_8))
        is Element.Bin -> order(a.value, (b as Element.Bin).value)
        is Element.Arr -> semanticOrderDepth(a.inner, (b as Element.Arr).inner, depth + 1)
        is Element.SetElem -> semanticOrderDepth(a.inner, (b as Element.SetElem).inner, depth + 1)
        is Element.MapElem -> semanticOrderDepth(a.inner, (b as Element.MapElem).inner, depth + 1)
    }
}

// Rank within the number class: -inf < finite < +inf < NaN. Ints and decimals
// are always finite.
private fun numClass(e: Element): Int = when (e) {
    is Element.Int, is Element.Dec -> 1
    is Element.Float32 -> floatRank(e.value.toDouble())
    is Element.Float64 -> floatRank(e.value)
    else -> throw IllegalStateException()
}

private fun floatRank(v: Double): Int = when {
    v.isNaN() -> 3
    v == Double.POSITIVE_INFINITY -> 2
    v == Double.NEGATIVE_INFINITY -> 0
    else -> 1
}

private fun isExact(e: Element): Boolean = e is Element.Int || e is Element.Dec

private fun floatOf(e: Element): Double = when (e) {
    is Element.Float32 -> e.value.toDouble()
    is Element.Float64 -> e.value
    else -> throw IllegalStateException()
}

private fun compareNumbers(a: Element, b: Element): Int {
    val ca = numClass(a)
    val cb = numClass(b)
    if (ca != cb) return sign(ca - cb)
    if (ca != 1) return 0 // both -inf, both +inf, or both NaN
    // Both finite. If both are plain floats, compare NUMERICALLY as doubles so signed
    // zero collapses: -0.0 == 0.0 (Item 7). The `<`/`>` operators use IEEE 754
    // semantics (unlike compareTo / Double.compare, whose total order splits ±0.0);
    // NaN can't reach here (filtered by numClass above), so this stays a total order.
    if (!isExact(a) && !isExact(b)) {
        val fa = floatOf(a)
        val fb = floatOf(b)
        return if (fa < fb) -1 else if (fa > fb) 1 else 0
    }
    // At least one exact operand. Compare via exact BigDecimals, but short-circuit
    // on base-10 order of magnitude FIRST so a decimal with a ~2e9 exponent never
    // drives BigDecimal.compareTo to align scales / materialize billions of digits
    // (Item 2 DoS). The exact path only runs when the ooms are close, so it is cheap.
    if (isExact(a) && isExact(b)) return compareExact(toExact(a), toExact(b))
    return if (isExact(a)) compareExactToFloat(toExact(a), floatOf(b))
    else -compareExactToFloat(toExact(b), floatOf(a))
}

/** Base-10 order-of-magnitude bounds of a nonzero exact BigDecimal `v`: returns
 *  `[lo, hi)` with `|v| ∈ [10^lo, 10^hi)`, where `lo` is the adjusted exponent
 *  (place value of the most-significant digit) and `hi = lo + 1`. Cheap — reads only
 *  precision()/scale(), never materializing `10^exp`. Mirrors b10OomBounds in
 *  src/semantic.zig (base-10 form). */
private class Oom(val lo: Long, val hi: Long)

private fun oomOf(v: BigDecimal): Oom {
    // value = unscaled · 10^(-scale); the p-digit unscaled sits in [10^(p-1), 10^p),
    // so |v| ∈ [10^(p-1-scale), 10^(p-scale)).
    val lo = v.precision().toLong() - 1L - v.scale().toLong()
    return Oom(lo, lo + 1L)
}

/** Compare two exact (int/big-int/decimal) values by value, short-circuiting on
 *  magnitude when their orders of magnitude are disjoint. */
private fun compareExact(a: BigDecimal, b: BigDecimal): Int {
    val sa = a.signum()
    val sb = b.signum()
    if (sa != sb) return sign(sa - sb)
    if (sa == 0) return 0 // both zero
    val oa = oomOf(a)
    val ob = oomOf(b)
    // Disjoint ooms decide by magnitude (sign flips the direction for negatives).
    if (oa.hi <= ob.lo) return -sa // |a| < |b|
    if (ob.hi <= oa.lo) return sa  // |a| > |b|
    return a.compareTo(b)          // ooms overlap → adjusted exponents equal → exact
}

/** Compare an exact value `v` to a finite double `f`, short-circuiting when `v`'s
 *  order of magnitude clears the finite-f64 window `|f| ∈ (10^-324, 10^309)`. */
private fun compareExactToFloat(v: BigDecimal, f: Double): Int {
    val sv = v.signum()
    val sf = if (f == 0.0) 0 else if (f < 0.0) -1 else 1 // f == 0.0 covers ±0.0
    if (sv != sf) return sign(sv - sf)
    if (sv == 0) return 0 // both zero
    val o = oomOf(v)
    if (o.lo >= 310) return sv    // |v| ≥ 10^310 > any finite double
    if (o.hi <= -325) return -sv  // |v| < 10^-325 < smallest positive double
    return v.compareTo(BigDecimal(f)) // within the float window → exact (bounded)
}

/** A finite number element -> its EXACT value as a BigDecimal. */
private fun toExact(e: Element): BigDecimal = when (e) {
    is Element.Int -> BigDecimal(e.value)
    is Element.Dec -> e.value
    is Element.Float32 -> BigDecimal(e.value.toDouble()) // exact binary value of the double
    is Element.Float64 -> BigDecimal(e.value)            // exact binary value
    else -> throw IllegalStateException()
}
