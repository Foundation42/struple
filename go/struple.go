// Package struple is a streaming, lexicographically-ordered tuple packing
// format. A struple value is a stream of self-delimiting, typed elements packed
// into a byte buffer such that the raw encoded bytes are directly
// memcmp-comparable:
//
//	bytes.Compare(Pack(a), Pack(b)) == the semantic order of a and b
//
// Drop two packed tuples into any byte-ordered store and they sort correctly
// with no custom comparator. This is a pure-stdlib Go port of the Zig reference
// implementation, byte-identical across all language ports and driven by the
// shared conformance corpus.
//
// Every element starts with a one-byte type code, assigned so that a byte-wise
// compare of the type byte alone gives the cross-type order:
//
//	nil < undefined < false < true
//	    < negative ints < zero < positive ints
//	    < float32 < float64 < decimal < timestamp < uuid
//	    < string < bytes < array < map < set
package struple

import (
	"errors"
	"math/big"
	"sort"
)

// Type codes. The numeric values are load-bearing: their order is the
// cross-type sort order. Gaps are reserved for the future tower.
const (
	tcTerminator byte = 0x00 // framing sentinel, never an element

	tcNil   byte = 0x01 // null (Python None / JS null)
	tcUndef byte = 0x02 // JS undefined

	tcBoolFalse byte = 0x05
	tcBoolTrue  byte = 0x06

	tcIntNegBig byte = 0x0F // arbitrary-precision negative (beyond i128)
	tcIntNegMin byte = 0x10 // widest fixed negative (16-byte magnitude)
	tcIntNegMax byte = 0x1F // 1-byte fixed negative
	tcIntZero   byte = 0x20
	tcIntPosMin byte = 0x21 // 1-byte fixed positive
	tcIntPosMax byte = 0x30 // widest fixed positive (16-byte magnitude)
	tcIntPosBig byte = 0x31 // arbitrary-precision positive (beyond i128)

	tcFloat32 byte = 0x34
	tcFloat64 byte = 0x35

	tcDecimal byte = 0x38 // arbitrary-precision base-10 number

	tcTimestamp byte = 0x40

	tcUUID byte = 0x44 // 16-byte fixed payload (no framing)

	tcString byte = 0x48
	tcBytes  byte = 0x49

	tcArray byte = 0x50
	tcMap   byte = 0x52
	tcSet   byte = 0x54
)

// escapeByte is written after a literal 0x00 inside variable-length payloads.
const escapeByte byte = 0xFF

// Decimal sign markers, isolating the three sign groups so a byte compare keeps
// negative < zero < positive. For negatives the rest of the payload is
// bit-complemented, so a larger magnitude sorts earlier.
const (
	decSignNeg  byte = 0x01
	decSignZero byte = 0x02
	decSignPos  byte = 0x03
)

// Errors surfaced by the decoder and the decimal-string parser.
var (
	ErrTruncated      = errors.New("struple: truncated input")
	ErrInvalidType    = errors.New("struple: invalid type code")
	ErrInvalidDecimal = errors.New("struple: invalid decimal")
	ErrNestingTooDeep = errors.New("struple: nesting too deep")
)

// maxDepth is the maximum container/JSON nesting depth accepted by the recursive
// walks (JSON parse, JSON render, semantic compare). Bounds stack use so hostile
// deeply-nested input is rejected instead of overflowing the stack. Shared across
// all 12 ports; no real value nests anywhere near this deep.
const maxDepth = 256

// Decimal adjusted-exponent bounds (Item 2). The adjusted exponent (= the power
// of ten of the most-significant digit) is capped to the signed 32-bit range so
// it round-trips through decode, the decimal-string parser can't overflow while
// accumulating it, and downstream exponent math — Exponent() = AdjExp − digitCount,
// toJson padding, semantic scaling — can never blow up. This is ~2× any real
// decimal Emax; a larger value is malformed.
const (
	decMaxAdjExp int64 = 2147483647  // math.MaxInt32
	decMinAdjExp int64 = -2147483648 // math.MinInt32
)

// Kind identifies the type of a decoded Element.
type Kind int

const (
	KindNil Kind = iota
	KindUndefined
	KindBool
	KindInt
	KindBigInt
	KindFloat32
	KindFloat64
	KindDecimal
	KindTimestamp
	KindUUID
	KindString
	KindBytes
	KindArray
	KindMap
	KindSet
)

// Element is a decoded element. For string/bytes/array/map/set the Body slice
// points into the source buffer and is the framed payload (literal 0x00 still
// appears as 0x00 0xFF); when it contains no 0x00 it is already the literal
// content. Use Unescape, then a child Reader for containers.
type Element struct {
	Kind Kind

	Bool      bool     // KindBool
	Int       *big.Int // KindInt / KindBigInt (the exact integer value)
	Float32   float32  // KindFloat32
	Float64   float64  // KindFloat64
	Decimal   Decimal  // KindDecimal
	Timestamp int64    // KindTimestamp (microseconds since the Unix epoch, UTC)
	UUID      [16]byte // KindUUID
	Body      []byte   // KindString/KindBytes/KindArray/KindMap/KindSet (framed)
}

// Decimal is a decoded decimal value: (-1)^Negative * coefficient * 10^exponent,
// with the coefficient's significant digits carried base-100 packed (two digits
// per byte). AdjExp is the adjusted exponent (the power of ten of the
// most-significant digit). The zero value has an empty coefficient.
type Decimal struct {
	Negative bool
	AdjExp   int64
	// CoeffStored holds the base-100 packed digit bytes as stored: each pair is
	// value+1 (1..100), bit-complemented when Negative. Empty for canonical zero.
	CoeffStored []byte
}

// IsZero reports whether the decimal is the canonical zero.
func (d Decimal) IsZero() bool { return len(d.CoeffStored) == 0 }

// DigitCount returns the number of significant decimal digits in the coefficient.
func (d Decimal) DigitCount() int {
	if len(d.CoeffStored) == 0 {
		return 0
	}
	last := d.CoeffStored[len(d.CoeffStored)-1]
	if d.Negative {
		last = ^last
	}
	pair := last - 1
	// An odd digit count pads the final pair's low digit with a (canonical) zero.
	n := len(d.CoeffStored) * 2
	if pair%10 == 0 {
		n--
	}
	return n
}

// Exponent returns the power of ten applied to the integer coefficient, i.e.
// value = ±coefficient * 10^Exponent.
func (d Decimal) Exponent() int64 {
	return d.AdjExp - int64(d.DigitCount())
}

// CoefficientDigits unpacks the coefficient's decimal digits (each 0..9,
// most-significant first).
func (d Decimal) CoefficientDigits() []byte {
	out := make([]byte, 0, len(d.CoeffStored)*2)
	for idx, raw := range d.CoeffStored {
		if d.Negative {
			raw = ^raw
		}
		pair := raw - 1
		out = append(out, pair/10)
		lo := pair % 10
		isLast := idx+1 == len(d.CoeffStored)
		if !(isLast && lo == 0) { // skip only the synthetic trailing pad
			out = append(out, lo)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Writer — builds an encoded tuple
// ---------------------------------------------------------------------------

// Writer accumulates encoded elements into a memcmp-comparable byte buffer.
type Writer struct {
	buf []byte
}

// NewWriter returns an empty Writer.
func NewWriter() *Writer { return &Writer{} }

// Reset clears the buffer, retaining capacity.
func (w *Writer) Reset() { w.buf = w.buf[:0] }

// Bytes returns the encoded bytes (valid until the next mutating call).
func (w *Writer) Bytes() []byte { return w.buf }

// AppendNil appends a nil element.
func (w *Writer) AppendNil() { w.buf = append(w.buf, tcNil) }

// AppendUndefined appends an undefined element.
func (w *Writer) AppendUndefined() { w.buf = append(w.buf, tcUndef) }

// AppendBool appends a boolean element.
func (w *Writer) AppendBool(v bool) {
	if v {
		w.buf = append(w.buf, tcBoolTrue)
	} else {
		w.buf = append(w.buf, tcBoolFalse)
	}
}

// AppendInt appends a signed integer element. Fast path: build the big-endian
// magnitude on the stack and reuse the fixed/big-int router — no per-call big.Int
// allocation (which dominated integer-heavy encodes). Byte-identical output.
func (w *Writer) AppendInt(v int64) {
	if v == 0 {
		w.buf = append(w.buf, tcIntZero)
		return
	}
	neg := v < 0
	mag := uint64(v)
	if neg {
		mag = -mag // two's-complement magnitude (correct even for math.MinInt64)
	}
	a := [8]byte{byte(mag >> 56), byte(mag >> 48), byte(mag >> 40), byte(mag >> 32),
		byte(mag >> 24), byte(mag >> 16), byte(mag >> 8), byte(mag)}
	w.AppendBigInt(neg, a[:])
}

// AppendUint appends an unsigned integer element (same stack-magnitude fast path).
func (w *Writer) AppendUint(v uint64) {
	if v == 0 {
		w.buf = append(w.buf, tcIntZero)
		return
	}
	a := [8]byte{byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32),
		byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}
	w.AppendBigInt(false, a[:])
}

// AppendBigIntValue appends an arbitrary-precision integer. Values inside the
// i128 range use the fixed-width codes; values beyond it use the big-int codes.
func (w *Writer) AppendBigIntValue(v *big.Int) {
	if v.Sign() == 0 {
		w.buf = append(w.buf, tcIntZero)
		return
	}
	w.AppendBigInt(v.Sign() < 0, v.Bytes())
}

// AppendBigInt appends an integer given its sign and big-endian magnitude bytes
// (leading zeros are trimmed). Routes through the fixed path when the value fits
// the i128 range, else the big-int codes.
func (w *Writer) AppendBigInt(negative bool, magnitudeBE []byte) {
	mag := trimLeadingZeros(magnitudeBE)
	if len(mag) == 0 {
		w.buf = append(w.buf, tcIntZero)
		return
	}
	if fitsFixed(negative, mag) {
		if negative {
			w.encodeNegative(mag)
		} else {
			w.encodePositive(mag)
		}
		return
	}
	if negative {
		w.buf = append(w.buf, tcIntNegBig)
	} else {
		w.buf = append(w.buf, tcIntPosBig)
	}
	w.writeBigIntFields(mag, negative)
}

// AppendF32 appends a 32-bit float element.
func (w *Writer) AppendF32(v float32) {
	bits := orderableF32Bits(v)
	w.buf = append(w.buf, tcFloat32,
		byte(bits>>24), byte(bits>>16), byte(bits>>8), byte(bits))
}

// AppendF64 appends a 64-bit float element.
func (w *Writer) AppendF64(v float64) {
	bits := orderableF64Bits(v)
	w.buf = append(w.buf, tcFloat64,
		byte(bits>>56), byte(bits>>48), byte(bits>>40), byte(bits>>32),
		byte(bits>>24), byte(bits>>16), byte(bits>>8), byte(bits))
}

// AppendDecimal appends an arbitrary-precision decimal
// (-1)^negative * C * 10^exp, where digits are the coefficient C's decimal
// digits (each 0..9, most-significant first). Canonicalized on the way in:
// leading/trailing zeros are stripped and any all-zero coefficient collapses to
// the single zero form.
func (w *Writer) AppendDecimal(negative bool, digits []byte, exp int) error {
	lead := 0
	for lead < len(digits) && digits[lead] == 0 {
		lead++
	}
	sig := digits[lead:]

	w.buf = append(w.buf, tcDecimal)
	if len(sig) == 0 { // canonical zero — one form regardless of scale
		w.buf = append(w.buf, decSignZero)
		return nil
	}

	// Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
	adjExp := int64(len(sig)) + int64(exp)
	// Bound the adjusted exponent to i32 (Item 2) so it round-trips through
	// decode's cap and downstream exponent math never overflows. A larger value
	// is rejected here rather than encoded.
	if adjExp > decMaxAdjExp || adjExp < decMinAdjExp {
		return ErrInvalidDecimal
	}
	end := len(sig)
	for end > 0 && sig[end-1] == 0 {
		end--
	}
	store := sig[:end]

	// Order-bearing tail: [E as a struple int][base-100 digits][terminator].
	// Built directly into w.buf (no per-call scratch slice); for negatives the
	// appended tail is bit-complemented in place afterwards.
	if negative {
		w.buf = append(w.buf, decSignNeg)
	} else {
		w.buf = append(w.buf, decSignPos)
	}
	tailStart := len(w.buf)
	w.buf = appendFixedInt(w.buf, big.NewInt(adjExp))
	for i := 0; i < len(store); i += 2 {
		hi := int(store[i])
		lo := 0
		if i+1 < len(store) {
			lo = int(store[i+1])
		}
		w.buf = append(w.buf, byte(hi*10+lo+1)) // pair 0..99 -> byte 1..100
	}
	w.buf = append(w.buf, tcTerminator)
	if negative {
		for i := tailStart; i < len(w.buf); i++ {
			w.buf[i] = ^w.buf[i]
		}
	}
	return nil
}

// AppendDecimalString appends a decimal parsed from text:
// [+/-] digits [. digits] [ (e|E) [+/-] digits ].
func (w *Writer) AppendDecimalString(s string) error {
	i := 0
	negative := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		negative = s[i] == '-'
		i++
	}
	var digits []byte
	var exp int64 // i64 so the parse can't overflow before the i32 bound check
	seenPoint := false
	any := false
	for ; i < len(s); i++ {
		c := s[i]
		if c == '.' {
			if seenPoint {
				return ErrInvalidDecimal
			}
			seenPoint = true
			continue
		}
		if c == 'e' || c == 'E' {
			break
		}
		if c < '0' || c > '9' {
			return ErrInvalidDecimal
		}
		digits = append(digits, c-'0')
		if seenPoint {
			exp--
		}
		any = true
	}
	if !any {
		return ErrInvalidDecimal
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		var esign int64 = 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			if s[i] == '-' {
				esign = -1
			}
			i++
		}
		var ev int64
		edig := false
		for ; i < len(s); i++ {
			if s[i] < '0' || s[i] > '9' {
				return ErrInvalidDecimal
			}
			ev = ev*10 + int64(s[i]-'0')
			if ev > decMaxAdjExp { // far beyond any real exponent
				return ErrInvalidDecimal
			}
			edig = true
		}
		if !edig {
			return ErrInvalidDecimal
		}
		exp += esign * ev
	}
	// Bound the exponent magnitude to i32; AppendDecimal additionally bounds the
	// adjusted exponent (significant-digit count + exp).
	if exp > decMaxAdjExp || exp < decMinAdjExp {
		return ErrInvalidDecimal
	}
	return w.AppendDecimal(negative, digits, int(exp))
}

// AppendTimestamp appends a timestamp: microseconds since the Unix epoch, UTC.
func (w *Writer) AppendTimestamp(micros int64) {
	// Flip the sign bit so two's-complement order matches unsigned byte order.
	u := uint64(micros) ^ (uint64(1) << 63)
	w.buf = append(w.buf, tcTimestamp,
		byte(u>>56), byte(u>>48), byte(u>>40), byte(u>>32),
		byte(u>>24), byte(u>>16), byte(u>>8), byte(u))
}

// AppendUUID appends a 128-bit UUID, stored as its 16 raw bytes.
func (w *Writer) AppendUUID(v [16]byte) {
	w.buf = append(w.buf, tcUUID)
	w.buf = append(w.buf, v[:]...)
}

// AppendString appends a UTF-8 string element.
func (w *Writer) AppendString(v string) { w.writeFramed(tcString, []byte(v)) }

// AppendBytes appends a binary element.
func (w *Writer) AppendBytes(v []byte) { w.writeFramed(tcBytes, v) }

// AppendArray appends a nested array. child is the encoded element stream of
// another tuple (e.g. another Writer's Bytes()).
func (w *Writer) AppendArray(child []byte) { w.writeFramed(tcArray, child) }

// AppendMap appends a map. entries is a list of [key, value] encodings; they are
// sorted by key into canonical order. (Duplicate keys are the caller's
// responsibility.)
func (w *Writer) AppendMap(entries [][2][]byte) {
	idx := make([]int, len(entries))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		return less(entries[idx[a]][0], entries[idx[b]][0])
	})
	w.buf = append(w.buf, tcMap)
	for _, i := range idx {
		w.writeEscaped(entries[i][0])
		w.writeEscaped(entries[i][1])
	}
	w.buf = append(w.buf, tcTerminator)
}

// AppendSet appends a set. elements (each an element encoding) are sorted and
// de-duplicated into canonical order.
func (w *Writer) AppendSet(elements [][]byte) {
	idx := make([]int, len(elements))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		return less(elements[idx[a]], elements[idx[b]])
	})
	w.buf = append(w.buf, tcSet)
	var prev []byte
	havePrev := false
	for _, i := range idx {
		e := elements[i]
		if havePrev && bytesEqual(prev, e) {
			continue
		}
		w.writeEscaped(e)
		prev = e
		havePrev = true
	}
	w.buf = append(w.buf, tcTerminator)
}

func (w *Writer) encodePositive(mag []byte) {
	w.buf = append(w.buf, tcIntZero+byte(len(mag)))
	w.buf = append(w.buf, mag...)
}

func (w *Writer) encodeNegative(mag []byte) {
	// Excess form: store 2^(8n) - magnitude, where n is the byte width chosen so
	// that (magnitude-1) fits. The low n bytes of the two's-complement negation
	// give exactly that.
	posVal := new(big.Int).Sub(new(big.Int).SetBytes(mag), big.NewInt(1))
	n := len(posVal.Bytes())
	if n == 0 {
		n = 1
	}
	w.buf = append(w.buf, tcIntZero-byte(n))
	excess := excessForm(mag, n)
	w.buf = append(w.buf, excess...)
}

func (w *Writer) writeBigIntFields(mag []byte, complement bool) {
	n := len(mag)
	nBytes := bigEndianBytes(n)
	m := len(nBytes)
	if complement {
		w.buf = append(w.buf, ^byte(m))
		for _, b := range nBytes {
			w.buf = append(w.buf, ^b)
		}
		for _, b := range mag {
			w.buf = append(w.buf, ^b)
		}
	} else {
		w.buf = append(w.buf, byte(m))
		w.buf = append(w.buf, nBytes...)
		w.buf = append(w.buf, mag...)
	}
}

func (w *Writer) writeEscaped(content []byte) {
	// Bulk-copy the runs between literal 0x00 bytes, inserting the escape byte at
	// each 0x00 — far cheaper than appending one byte at a time when escapes are
	// rare (the common case for text/UTF-8 payloads).
	start := 0
	for i := 0; i < len(content); i++ {
		if content[i] == 0x00 {
			w.buf = append(w.buf, content[start:i+1]...)
			w.buf = append(w.buf, escapeByte)
			start = i + 1
		}
	}
	w.buf = append(w.buf, content[start:]...)
}

func (w *Writer) writeFramed(typeCode byte, content []byte) {
	w.buf = append(w.buf, typeCode)
	w.writeEscaped(content)
	w.buf = append(w.buf, tcTerminator)
}

// ---------------------------------------------------------------------------
// Reader — streams elements back out
// ---------------------------------------------------------------------------

// Reader streams decoded elements out of an encoded buffer.
type Reader struct {
	buf []byte
	pos int
}

// NewReader returns a Reader over buf.
func NewReader(buf []byte) *Reader { return &Reader{buf: buf} }

// Done reports whether the reader has consumed the whole buffer.
func (r *Reader) Done() bool { return r.pos >= len(r.buf) }

// Next decodes and returns the next element. ok is false at end of stream.
func (r *Reader) Next() (e Element, ok bool, err error) {
	if r.pos >= len(r.buf) {
		return Element{}, false, nil
	}
	tc := r.buf[r.pos]
	r.pos++

	switch {
	case tc == tcNil:
		return Element{Kind: KindNil}, true, nil
	case tc == tcUndef:
		return Element{Kind: KindUndefined}, true, nil
	case tc == tcBoolFalse:
		return Element{Kind: KindBool, Bool: false}, true, nil
	case tc == tcBoolTrue:
		return Element{Kind: KindBool, Bool: true}, true, nil
	case tc == tcIntZero:
		return Element{Kind: KindInt, Int: big.NewInt(0)}, true, nil
	case (tc >= 0x10 && tc <= 0x1F) || (tc >= 0x21 && tc <= 0x30):
		positive := tc > tcIntZero
		var n int
		if positive {
			n = int(tc - tcIntZero)
		} else {
			n = int(tcIntZero - tc)
		}
		payload, err := r.take(n)
		if err != nil {
			return Element{}, false, err
		}
		// A canonical encoder uses the big-int codes for 16-byte values outside
		// the i128 range, so such a fixed payload is malformed.
		if n == 16 && ((positive && payload[0] >= 0x80) || (!positive && payload[0] < 0x80)) {
			return Element{}, false, ErrInvalidType
		}
		return Element{Kind: KindInt, Int: decodeIntPayload(positive, payload)}, true, nil
	case tc == tcIntNegBig || tc == tcIntPosBig:
		negative := tc == tcIntNegBig
		mb, err := r.take(1)
		if err != nil {
			return Element{}, false, err
		}
		m := int(decodeByte(mb[0], negative))
		// Length-of-length is capped at 8 bytes: no real magnitude needs a length
		// that doesn't fit in a u64, and without this bound m (0..255) lets the
		// shift below run past the width of n and address the whole space. take(n)
		// then rejects any n beyond the buffer (or one that wrapped negative)
		// cleanly, so it is the real backstop.
		if m > 8 {
			return Element{}, false, ErrInvalidType
		}
		nbytes, err := r.take(m)
		if err != nil {
			return Element{}, false, err
		}
		n := 0
		for _, b := range nbytes {
			n = (n << 8) | int(decodeByte(b, negative))
		}
		mag, err := r.take(n)
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindBigInt, Int: bigIntFromStored(negative, mag)}, true, nil
	case tc == tcFloat32:
		p, err := r.take(4)
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindFloat32, Float32: decodeF32(p)}, true, nil
	case tc == tcFloat64:
		p, err := r.take(8)
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindFloat64, Float64: decodeF64(p)}, true, nil
	case tc == tcDecimal:
		d, err := r.takeDecimal()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindDecimal, Decimal: d}, true, nil
	case tc == tcTimestamp:
		p, err := r.take(8)
		if err != nil {
			return Element{}, false, err
		}
		var raw uint64
		for _, b := range p {
			raw = (raw << 8) | uint64(b)
		}
		return Element{Kind: KindTimestamp, Timestamp: int64(raw ^ (uint64(1) << 63))}, true, nil
	case tc == tcUUID:
		p, err := r.take(16)
		if err != nil {
			return Element{}, false, err
		}
		var u [16]byte
		copy(u[:], p)
		return Element{Kind: KindUUID, UUID: u}, true, nil
	case tc == tcString:
		body, err := r.takeFramed()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindString, Body: body}, true, nil
	case tc == tcBytes:
		body, err := r.takeFramed()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindBytes, Body: body}, true, nil
	case tc == tcArray:
		body, err := r.takeFramed()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindArray, Body: body}, true, nil
	case tc == tcMap:
		body, err := r.takeFramed()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindMap, Body: body}, true, nil
	case tc == tcSet:
		body, err := r.takeFramed()
		if err != nil {
			return Element{}, false, err
		}
		return Element{Kind: KindSet, Body: body}, true, nil
	default:
		return Element{}, false, ErrInvalidType
	}
}

// PeekType returns the type code of the next element without consuming it. The
// second result is false at end of stream.
func (r *Reader) PeekType() (byte, bool) {
	if r.pos < len(r.buf) {
		return r.buf[r.pos], true
	}
	return 0, false
}

// Rest returns the remaining unread bytes (a valid struple stream).
func (r *Reader) Rest() []byte { return r.buf[r.pos:] }

// NextView returns the next element's raw bytes (a zero-copy view, itself a
// valid one-element struple buffer), advancing the cursor. ok is false at end of
// stream.
func (r *Reader) NextView() (view []byte, ok bool, err error) {
	start := r.pos
	_, ok, err = r.Next()
	if err != nil || !ok {
		return nil, ok, err
	}
	return r.buf[start:r.pos], true, nil
}

// Skip advances past the next element; ok is false at end of stream.
func (r *Reader) Skip() (ok bool, err error) {
	_, ok, err = r.NextView()
	return ok, err
}

func (r *Reader) takeDecimal() (Decimal, error) {
	sb, err := r.take(1)
	if err != nil {
		return Decimal{}, err
	}
	sign := sb[0]
	if sign == decSignZero {
		return Decimal{Negative: false, AdjExp: 0, CoeffStored: r.buf[r.pos:r.pos]}, nil
	}
	if sign != decSignNeg && sign != decSignPos {
		return Decimal{}, ErrInvalidType
	}
	negative := sign == decSignNeg
	adjExp, err := r.readDecExponent(negative)
	if err != nil {
		return Decimal{}, err
	}
	// Digit bytes are 1..100 (positive) or their complement (negative), and never
	// collide with the terminator (0x00, or 0xFF when complemented).
	term := byte(0x00)
	if negative {
		term = 0xFF
	}
	start := r.pos
	i := r.pos
	for i < len(r.buf) && r.buf[i] != term {
		i++
	}
	if i >= len(r.buf) {
		return Decimal{}, ErrTruncated
	}
	if i == start {
		return Decimal{}, ErrInvalidType // a nonzero decimal must carry digits
	}
	r.pos = i + 1 // consume the terminator
	return Decimal{Negative: negative, AdjExp: adjExp, CoeffStored: r.buf[start:i]}, nil
}

func (r *Reader) readDecExponent(complement bool) (int64, error) {
	tb0, err := r.take(1)
	if err != nil {
		return 0, err
	}
	tb := decodeByte(tb0[0], complement)
	if tb == tcIntZero {
		return 0, nil
	}
	if (tb >= tcIntNegMin && tb <= tcIntNegMax) || (tb >= tcIntPosMin && tb <= tcIntPosMax) {
		positive := tb > tcIntZero
		var n int
		if positive {
			n = int(tb - tcIntZero)
		} else {
			n = int(tcIntZero - tb)
		}
		raw, err := r.take(n)
		if err != nil {
			return 0, err
		}
		tmp := make([]byte, n)
		for k, b := range raw {
			tmp[k] = decodeByte(b, complement)
		}
		if n == 16 && ((positive && tmp[0] >= 0x80) || (!positive && tmp[0] < 0x80)) {
			return 0, ErrInvalidType
		}
		v := decodeIntPayload(positive, tmp)
		// Bound the adjusted exponent to i32 (Item 2): keeps Decimal.Exponent()
		// (= AdjExp − digitCount) from underflowing i64 and downstream exponent
		// math from overflowing. A larger stored exponent is malformed.
		if !v.IsInt64() {
			return 0, ErrInvalidType
		}
		iv := v.Int64()
		if iv > decMaxAdjExp || iv < decMinAdjExp {
			return 0, ErrInvalidType
		}
		return iv, nil
	}
	return 0, ErrInvalidType
}

func (r *Reader) take(n int) ([]byte, error) {
	// Guard written as `n > remaining` (never `pos + n > len`): the addition would
	// overflow int for an attacker-supplied length before it could be caught, and
	// an assembled length can even wrap negative (int is 64-bit here). `pos <= len`
	// is a Reader invariant, so `len - pos` never underflows; the `n < 0` arm
	// rejects a wrapped length before it can slice with high < low.
	if n < 0 || n > len(r.buf)-r.pos {
		return nil, ErrTruncated
	}
	s := r.buf[r.pos : r.pos+n]
	r.pos += n
	return s, nil
}

func (r *Reader) takeFramed() ([]byte, error) {
	start := r.pos
	i := r.pos
	for i < len(r.buf) {
		if r.buf[i] == 0x00 {
			if i+1 < len(r.buf) && r.buf[i+1] == escapeByte {
				i += 2 // escaped literal 0x00
				continue
			}
			r.pos = i + 1 // consume terminator
			return r.buf[start:i], nil
		}
		i++
	}
	return nil, ErrTruncated
}

// ---------------------------------------------------------------------------
// Ordering and transcode
// ---------------------------------------------------------------------------

// Compare returns the raw memcmp order of two encoded streams: -1, 0, or +1.
// This is the lexicographic byte order, which is the defining property of the
// format. For value-based ordering across number representations use
// SemanticOrder.
func Compare(a, b []byte) int { return bytesCompare(a, b) }

// Transcode decodes every element of an encoded buffer and re-encodes it,
// yielding canonical bytes. For canonical input it is the identity.
func Transcode(encoded []byte) ([]byte, error) {
	r := NewReader(encoded)
	w := NewWriter()
	for {
		e, ok, err := r.Next()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
		if err := reencode(w, e); err != nil {
			return nil, err
		}
	}
	return w.Bytes(), nil
}

func reencode(w *Writer, e Element) error {
	switch e.Kind {
	case KindNil:
		w.AppendNil()
	case KindUndefined:
		w.AppendUndefined()
	case KindBool:
		w.AppendBool(e.Bool)
	case KindInt, KindBigInt:
		w.AppendBigIntValue(e.Int)
	case KindFloat32:
		w.AppendF32(e.Float32)
	case KindFloat64:
		w.AppendF64(e.Float64)
	case KindDecimal:
		return reencodeDecimal(w, e.Decimal)
	case KindTimestamp:
		w.AppendTimestamp(e.Timestamp)
	case KindUUID:
		w.AppendUUID(e.UUID)
	case KindString:
		w.AppendString(string(Unescape(e.Body)))
	case KindBytes:
		w.AppendBytes(Unescape(e.Body))
	case KindArray, KindSet, KindMap:
		inner := Unescape(e.Body)
		sub := NewWriter()
		r := NewReader(inner)
		for {
			ie, ok, err := r.Next()
			if err != nil {
				return err
			}
			if !ok {
				break
			}
			if err := reencode(sub, ie); err != nil {
				return err
			}
		}
		// The inner stream is already canonical; re-frame it directly so map/set
		// ordering is preserved exactly.
		w.writeFramed(containerTypeCode(e.Kind), sub.Bytes())
	default:
		return ErrInvalidType
	}
	return nil
}

func containerTypeCode(k Kind) byte {
	switch k {
	case KindArray:
		return tcArray
	case KindMap:
		return tcMap
	default:
		return tcSet
	}
}

func reencodeDecimal(w *Writer, d Decimal) error {
	if d.IsZero() {
		return w.AppendDecimal(false, nil, 0)
	}
	return w.AppendDecimal(d.Negative, d.CoefficientDigits(), int(d.Exponent()))
}

// ---------------------------------------------------------------------------
// Escaping helpers for variable-length payloads
// ---------------------------------------------------------------------------

// Unescape converts a framed payload (0x00 0xFF -> 0x00) into its literal inner
// bytes. The result is a fresh slice.
func Unescape(framed []byte) []byte {
	out := make([]byte, 0, len(framed))
	for i := 0; i < len(framed); i++ {
		out = append(out, framed[i])
		if framed[i] == 0x00 {
			i++ // skip the escape byte
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Integer encode/decode helpers
// ---------------------------------------------------------------------------

var (
	i128Min = func() *big.Int {
		v := new(big.Int).Lsh(big.NewInt(1), 127)
		return v.Neg(v)
	}()
	i128Max = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 127), big.NewInt(1))
)

func appendFixedInt(dst []byte, v *big.Int) []byte {
	w := &Writer{buf: dst}
	if v.Sign() == 0 {
		w.buf = append(w.buf, tcIntZero)
		return w.buf
	}
	mag := v.Bytes()
	if v.Sign() < 0 {
		w.encodeNegative(mag)
	} else {
		w.encodePositive(mag)
	}
	return w.buf
}

func decodeIntPayload(positive bool, payload []byte) *big.Int {
	raw := new(big.Int).SetBytes(payload)
	if positive {
		return raw
	}
	// Negative: value = raw - 2^(8*len).
	span := new(big.Int).Lsh(big.NewInt(1), uint(len(payload))*8)
	return raw.Sub(raw, span)
}

// fitsFixed reports whether sign + trimmed big-endian magnitude fits the i128
// range [-2^127, 2^127-1].
func fitsFixed(negative bool, mag []byte) bool {
	if len(mag) < 16 {
		return true
	}
	if len(mag) > 16 {
		return false
	}
	if mag[0] < 0x80 {
		return true // |value| < 2^127
	}
	if !negative {
		return false // positive >= 2^127 -> big-int
	}
	if mag[0] != 0x80 {
		return false // magnitude > 2^127 -> big-int
	}
	for _, b := range mag[1:] {
		if b != 0 {
			return false
		}
	}
	return true // exactly -2^127
}

// excessForm returns the low n bytes of 2^(8n) - magnitude (big-endian).
func excessForm(mag []byte, n int) []byte {
	span := new(big.Int).Lsh(big.NewInt(1), uint(n)*8)
	v := span.Sub(span, new(big.Int).SetBytes(mag))
	vb := v.Bytes()
	out := make([]byte, n)
	copy(out[n-len(vb):], vb)
	return out
}

// bigIntFromStored reconstructs the integer value from stored big-int magnitude
// bytes (complemented when negative).
func bigIntFromStored(negative bool, magStored []byte) *big.Int {
	mag := make([]byte, len(magStored))
	for i, b := range magStored {
		if negative {
			mag[i] = ^b
		} else {
			mag[i] = b
		}
	}
	v := new(big.Int).SetBytes(mag)
	if negative {
		v.Neg(v)
	}
	return v
}

func bigEndianBytes(n int) []byte {
	if n == 0 {
		return []byte{0}
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte(n)}, b...)
		n >>= 8
	}
	return b
}

func trimLeadingZeros(b []byte) []byte {
	s := 0
	for s < len(b) && b[s] == 0 {
		s++
	}
	return b[s:]
}

func decodeByte(b byte, complemented bool) byte {
	if complemented {
		return ^b
	}
	return b
}

// ---------------------------------------------------------------------------
// Float encode/decode (IEEE-754 total ordering)
// ---------------------------------------------------------------------------

func decodeF32(p []byte) float32 {
	var bits uint32
	for _, b := range p {
		bits = (bits << 8) | uint32(b)
	}
	if bits&0x80000000 != 0 {
		bits ^= 0x80000000
	} else {
		bits = ^bits
	}
	return float32FromBits(bits)
}

func decodeF64(p []byte) float64 {
	var bits uint64
	for _, b := range p {
		bits = (bits << 8) | uint64(b)
	}
	if bits&0x8000000000000000 != 0 {
		bits ^= 0x8000000000000000
	} else {
		bits = ^bits
	}
	return float64FromBits(bits)
}

// ---------------------------------------------------------------------------
// Small byte helpers (avoid importing bytes for trivial ops)
// ---------------------------------------------------------------------------

func less(a, b []byte) bool { return bytesCompare(a, b) < 0 }

func bytesEqual(a, b []byte) bool { return bytesCompare(a, b) == 0 }

func bytesCompare(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	default:
		return 0
	}
}
