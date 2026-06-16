package struple

import "math"

func float32FromBits(b uint32) float32 { return math.Float32frombits(b) }
func float64FromBits(b uint64) float64 { return math.Float64frombits(b) }

// orderableF32Bits applies the IEEE-754 total-ordering transform: flip the sign
// bit for positives, flip all bits for negatives. -0.0 squashes to +0.0; NaN
// canonicalizes and sorts above +inf.
func orderableF32Bits(v float32) uint32 {
	var bits uint32
	if math.IsNaN(float64(v)) {
		bits = 0x7fc00000
	} else {
		if v == 0 {
			v = 0 // squash -0.0
		}
		bits = math.Float32bits(v)
	}
	if bits&0x80000000 != 0 {
		return ^bits
	}
	return bits ^ 0x80000000
}

func orderableF64Bits(v float64) uint64 {
	var bits uint64
	if math.IsNaN(v) {
		bits = 0x7ff8000000000000
	} else {
		if v == 0 {
			v = 0
		}
		bits = math.Float64bits(v)
	}
	if bits&0x8000000000000000 != 0 {
		return ^bits
	}
	return bits ^ 0x8000000000000000
}
