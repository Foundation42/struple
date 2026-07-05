package struple

// Semantic (value-based) ordering over encoded struple streams.
//
// Compare gives the raw memcmp order: the type byte dominates, so an integer and
// a float never interleave by magnitude. SemanticOrder instead compares by
// value — int, big-int, float32, float64 and decimal all compare by their exact
// mathematical value, with no precision loss even where a double can't represent
// the number.
//
// Cross-type order (when the two values aren't both numbers):
//
//	nil < undefined < bool < number < timestamp < uuid < string < bytes
//	    < array < map < set
//
// NaN sorts as the greatest number (above +inf); -0.0 == 0.0 == int 0.
// Containers recurse element-wise, with a shorter value sorting before a longer
// one that extends it.

import (
	"math"
	"math/big"
)

// SemanticOrder compares two encoded streams element-by-element by semantic
// value, returning -1, 0, or +1.
func SemanticOrder(a, b []byte) (int, error) {
	return semanticOrderDepth(a, b, 0)
}

func semanticOrderDepth(a, b []byte, depth int) (int, error) {
	// Bound recursion into nested containers so hostile deeply-nested input is
	// rejected rather than overflowing the stack (Item 5).
	if depth > maxDepth {
		return 0, ErrNestingTooDeep
	}
	ra := NewReader(a)
	rb := NewReader(b)
	for {
		ea, oka, err := ra.Next()
		if err != nil {
			return 0, err
		}
		eb, okb, err := rb.Next()
		if err != nil {
			return 0, err
		}
		if !oka && !okb {
			return 0, nil
		}
		if !oka {
			return -1, nil // a is a prefix of b
		}
		if !okb {
			return 1, nil
		}
		c, err := compareElements(ea, eb, depth)
		if err != nil {
			return 0, err
		}
		if c != 0 {
			return c, nil
		}
	}
}

// SemanticEqual reports whether two encoded streams compare equal by value.
func SemanticEqual(a, b []byte) (bool, error) {
	c, err := SemanticOrder(a, b)
	return c == 0, err
}

func classRank(k Kind) int {
	switch k {
	case KindNil:
		return 0
	case KindUndefined:
		return 1
	case KindBool:
		return 2
	case KindInt, KindBigInt, KindFloat32, KindFloat64, KindDecimal:
		return 3 // unified "number" class
	case KindTimestamp:
		return 4
	case KindUUID:
		return 5
	case KindString:
		return 6
	case KindBytes:
		return 7
	case KindArray:
		return 8
	case KindMap:
		return 9
	default: // KindSet
		return 10
	}
}

func compareElements(a, b Element, depth int) (int, error) {
	ra, rb := classRank(a.Kind), classRank(b.Kind)
	if ra != rb {
		return cmpInt(ra, rb), nil
	}
	switch a.Kind {
	case KindNil, KindUndefined:
		return 0, nil
	case KindBool:
		return cmpInt(boolToInt(a.Bool), boolToInt(b.Bool)), nil
	case KindInt, KindBigInt, KindFloat32, KindFloat64, KindDecimal:
		return compareNumbers(a, b), nil
	case KindTimestamp:
		return cmpInt64(a.Timestamp, b.Timestamp), nil
	case KindUUID:
		return bytesCompare(a.UUID[:], b.UUID[:]), nil
	case KindString, KindBytes:
		// content order == framed-byte order (the wire format is built so a
		// compare of the framed slice already gives content order).
		return bytesCompare(a.Body, b.Body), nil
	case KindArray, KindSet, KindMap:
		return semanticOrderContainer(a.Body, b.Body, depth)
	default:
		return 0, ErrInvalidType
	}
}

func semanticOrderContainer(fa, fb []byte, depth int) (int, error) {
	return semanticOrderDepth(Unescape(fa), Unescape(fb), depth+1)
}

// ---------------------------------------------------------------------------
// Numbers — every finite number maps exactly to a big.Rat
// ---------------------------------------------------------------------------

// numClass ranks within the number class: -inf(0) < finite(1) < +inf(2) < NaN(3).
func numClass(e Element) int {
	var f float64
	switch e.Kind {
	case KindInt, KindBigInt, KindDecimal:
		return 1 // integers and decimals are always finite
	case KindFloat32:
		f = float64(e.Float32)
	case KindFloat64:
		f = e.Float64
	}
	switch {
	case math.IsNaN(f):
		return 3
	case math.IsInf(f, 1):
		return 2
	case math.IsInf(f, -1):
		return 0
	default:
		return 1
	}
}

func compareNumbers(a, b Element) int {
	ca, cb := numClass(a), numClass(b)
	if ca != cb {
		return cmpInt(ca, cb)
	}
	if ca != 1 {
		return 0 // both -inf, both +inf, or both NaN
	}
	// When a decimal is involved, decide by base-10 order of magnitude first: a
	// huge (i32-bounded) exponent must never drive an exact big.Rat that
	// materializes 10^exp (Item 2 DoS). The non-decimal number classes never
	// build such a power, so they keep the exact-rational path.
	if a.Kind == KindDecimal || b.Kind == KindDecimal {
		return compareWithDecimal(a, b)
	}
	return numToRat(a).Cmp(numToRat(b))
}

// numToRat converts a finite number element to its exact rational value.
func numToRat(e Element) *big.Rat {
	switch e.Kind {
	case KindInt, KindBigInt:
		return new(big.Rat).SetInt(e.Int)
	case KindFloat32:
		r := new(big.Rat)
		r.SetFloat64(float64(e.Float32)) // finite -> exact
		return r
	case KindFloat64:
		r := new(big.Rat)
		r.SetFloat64(e.Float64)
		return r
	case KindDecimal:
		return decimalToRat(e.Decimal)
	default:
		return new(big.Rat)
	}
}

// decimalToRat converts a decimal (C * 10^exp) to an exact rational.
func decimalToRat(d Decimal) *big.Rat {
	if d.IsZero() {
		return new(big.Rat)
	}
	digits := d.CoefficientDigits()
	coeff := new(big.Int)
	ten := big.NewInt(10)
	for _, dch := range digits {
		coeff.Mul(coeff, ten)
		coeff.Add(coeff, big.NewInt(int64(dch)))
	}
	if d.Negative {
		coeff.Neg(coeff)
	}
	exp := d.Exponent()
	r := new(big.Rat).SetInt(coeff)
	pow := new(big.Int).Exp(ten, big.NewInt(absInt64(exp)), nil)
	if exp >= 0 {
		r.Mul(r, new(big.Rat).SetInt(pow))
	} else {
		r.Quo(r, new(big.Rat).SetInt(pow))
	}
	return r
}

// ---------------------------------------------------------------------------
// Base-10 order-of-magnitude comparison (Item 2 DoS short-circuit)
//
// A decimal carries an i32-sized exponent, so an exact big.Rat that materializes
// 10^exp — or that aligns two vastly different scales — would let a tiny input
// (e.g. "1e2000000000") drive billions of digits of work. Instead: reduce each
// operand to a base-10 magnitude (sign · mag · 10^exp10), bound its order of
// magnitude cheaply from the byte length of mag, and decide by that when the
// operands are far apart. Only when the bounds overlap (so the exponents are
// close) is the exact comparison performed — and then it scales by the *bounded*
// exponent difference, never by the raw exponent. Mirrors src/semantic.zig.
// ---------------------------------------------------------------------------

// b10 is an exact base-10 value sign · mag · 10^exp10 (mag big-endian; empty mag
// means zero).
type b10 struct {
	sign  int
	mag   []byte
	exp10 int64
}

// isExactKind reports whether e is an exact (non-float) number: int/bigint/decimal.
func isExactKind(e Element) bool {
	return e.Kind == KindInt || e.Kind == KindBigInt || e.Kind == KindDecimal
}

// numToB10 reduces an int / big-int / decimal to its exact base-10 value.
func numToB10(e Element) b10 {
	switch e.Kind {
	case KindInt, KindBigInt:
		s := e.Int.Sign()
		if s == 0 {
			return b10{sign: 0}
		}
		return b10{sign: s, mag: new(big.Int).Abs(e.Int).Bytes(), exp10: 0}
	case KindDecimal:
		d := e.Decimal
		if d.IsZero() {
			return b10{sign: 0}
		}
		sign := 1
		if d.Negative {
			sign = -1
		}
		// Coefficient magnitude (bounded by the significant-digit count, never by
		// the exponent).
		coeff := new(big.Int)
		ten := big.NewInt(10)
		for _, dch := range d.CoefficientDigits() {
			coeff.Mul(coeff, ten)
			coeff.Add(coeff, big.NewInt(int64(dch)))
		}
		return b10{sign: sign, mag: coeff.Bytes(), exp10: d.Exponent()}
	}
	return b10{}
}

// b10OomBounds bounds the base-10 order of magnitude of a nonzero mag · 10^exp10:
// returns lo, hi with |value| ∈ [10^lo, 10^hi). Uses byte-length bounds on the
// base-256 magnitude (256^(n-1) ≥ 10^(2(n-1)), 256^n < 10^(3n)).
func b10OomBounds(v b10) (lo, hi int64) {
	n := int64(len(trimLeadingZeros(v.mag))) // ≥ 1 for a nonzero value
	return v.exp10 + 2*n - 2, v.exp10 + 3*n
}

// compareWithDecimal compares two finite numbers when at least one is a decimal,
// via the base-10 order-of-magnitude path.
func compareWithDecimal(a, b Element) int {
	if isExactKind(a) && isExactKind(b) {
		va := numToB10(a)
		vb := numToB10(b)
		if va.sign != vb.sign {
			return cmpInt(va.sign, vb.sign)
		}
		if va.sign == 0 {
			return 0
		}
		c := compareB10Mag(va, vb)
		if va.sign < 0 {
			return -c
		}
		return c
	}
	// Exactly one side is a finite float.
	if isExactKind(a) {
		return compareB10Float(numToB10(a), floatVal(b))
	}
	return -compareB10Float(numToB10(b), floatVal(a))
}

// compareB10Mag compares two same-sign, nonzero base-10 magnitudes exactly.
func compareB10Mag(a, b b10) int {
	aLo, aHi := b10OomBounds(a)
	bLo, bHi := b10OomBounds(b)
	if aHi <= bLo {
		return -1
	}
	if bHi <= aLo {
		return 1
	}
	// Overlap: |a.exp10 − b.exp10| is bounded by the digit counts, so scaling by
	// the difference (never the raw exponent) is cheap.
	e := a.exp10
	if b.exp10 < e {
		e = b.exp10
	}
	sa := scaleMagPow10(a.mag, a.exp10-e)
	sb := scaleMagPow10(b.mag, b.exp10-e)
	return sa.Cmp(sb)
}

// compareB10Float compares a nonzero-capable base-10 value to a finite float.
func compareB10Float(v b10, f float64) int {
	sf := signRankF(f)
	if v.sign != sf {
		return cmpInt(v.sign, sf)
	}
	if v.sign == 0 {
		return 0 // both zero
	}
	// Any finite nonzero f64 has |f| ∈ (10^-324, 10^309). If the exact value's
	// order of magnitude is clear of that window, decide without scaling — this is
	// what stops a huge decimal exponent from driving a 2^31-iteration scale.
	lo, hi := b10OomBounds(v)
	var c int
	switch {
	case lo >= 310:
		c = 1
	case hi <= -325:
		c = -1
	default:
		c = compareB10MagToFloat(v, f)
	}
	if v.sign < 0 {
		return -c
	}
	return c
}

// compareB10MagToFloat compares |v| = mag · 10^exp10 to |f|, exactly. Reached only
// when the order-of-magnitude bounds overlap the float window, so exp10 is bounded
// and materializing 10^|exp10| is bounded work.
func compareB10MagToFloat(v b10, f float64) int {
	coeff := new(big.Int).SetBytes(v.mag) // nonnegative magnitude
	r := new(big.Rat).SetInt(coeff)
	pow := new(big.Int).Exp(big.NewInt(10), big.NewInt(absInt64(v.exp10)), nil)
	if v.exp10 >= 0 {
		r.Mul(r, new(big.Rat).SetInt(pow))
	} else {
		r.Quo(r, new(big.Rat).SetInt(pow))
	}
	fr := new(big.Rat).SetFloat64(math.Abs(f)) // |f|, exact
	return r.Cmp(fr)
}

// scaleMagPow10 returns SetBytes(mag) · 10^p as a big.Int (p ≥ 0).
func scaleMagPow10(mag []byte, p int64) *big.Int {
	v := new(big.Int).SetBytes(mag)
	if p > 0 {
		v.Mul(v, new(big.Int).Exp(big.NewInt(10), big.NewInt(p), nil))
	}
	return v
}

// floatVal returns a float element's value as a float64.
func floatVal(e Element) float64 {
	switch e.Kind {
	case KindFloat32:
		return float64(e.Float32)
	case KindFloat64:
		return e.Float64
	}
	return 0
}

// signRankF ranks a float's sign: 1 (>0), -1 (<0), 0 (±0).
func signRankF(f float64) int {
	switch {
	case f > 0:
		return 1
	case f < 0:
		return -1
	default:
		return 0
	}
}

// ---------------------------------------------------------------------------
// Small scalar helpers
// ---------------------------------------------------------------------------

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func cmpInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func cmpInt64(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func absInt64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
