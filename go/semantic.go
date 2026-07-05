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
