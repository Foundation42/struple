package struple

// JSON <-> struple conversion.
//
//	FromJson: JSON text     -> struple encoding (one element for the root value)
//	ToJson:   struple bytes  -> canonical JSON text (renders the first element)
//
// JSON type mapping:
//
//	null              <-> nil
//	true / false      <-> bool
//	integer number    <-> integer (arbitrary precision — big JSON ints are kept
//	                       losslessly, unlike a float64 round-trip)
//	fractional number <-> float64
//	string            <-> string
//	array             <-> array
//	object            <-> map (canonical: keys come back sorted)
//
// struple types with no JSON equivalent degrade on ToJson: undefined -> null,
// decimal -> number (exact literal), timestamp -> number (µs), uuid -> hyphenated
// string, bytes -> base64 string, set -> array.

import (
	"errors"
	"math/big"
	"strconv"
	"strings"
)

// JSON node kinds used by the hand-rolled parser (also exposed for tests).
type jsonKind int

const (
	jNull jsonKind = iota
	jBool
	jInt    // fits int64; uses IntVal
	jBigInt // larger; uses Str (raw decimal text, sign+digits)
	jFloat
	jStr
	jArray
	jObject
)

type jsonValue struct {
	kind    jsonKind
	boolVal bool
	intVal  int64
	floatV  float64
	str     string
	arr     []jsonValue
	obj     []jsonMember
}

type jsonMember struct {
	key string
	val jsonValue
}

// FromJson parses JSON text and returns its struple encoding.
func FromJson(text string) ([]byte, error) {
	v, err := parseJSON(text)
	if err != nil {
		return nil, err
	}
	w := NewWriter()
	encodeJSON(w, v)
	return w.Bytes(), nil
}

// ToJson renders a struple encoding's first element as canonical JSON text.
func ToJson(encoded []byte) (string, error) {
	r := NewReader(encoded)
	e, ok, err := r.Next()
	if err != nil {
		return "", err
	}
	if !ok {
		return "null", nil
	}
	var sb strings.Builder
	if err := renderJSON(&sb, e, 0); err != nil {
		return "", err
	}
	return sb.String(), nil
}

// ---------------------------------------------------------------------------
// JSON -> struple
// ---------------------------------------------------------------------------

func encodeJSON(w *Writer, v jsonValue) {
	switch v.kind {
	case jNull:
		w.AppendNil()
	case jBool:
		w.AppendBool(v.boolVal)
	case jInt:
		w.AppendInt(v.intVal)
	case jBigInt:
		negative := false
		digits := v.str
		if strings.HasPrefix(digits, "-") {
			negative = true
			digits = digits[1:]
		} else if strings.HasPrefix(digits, "+") {
			digits = digits[1:]
		}
		// number() guarantees digits is a non-empty run of [0-9] here, so SetString
		// always succeeds; check ok anyway so a would-be empty magnitude can never
		// nil-panic on .Bytes() (Item 4, sign-with-no-digits edge, defence-in-depth).
		mag, ok := new(big.Int).SetString(digits, 10)
		if !ok {
			mag = new(big.Int)
		}
		w.AppendBigInt(negative, mag.Bytes())
	case jFloat:
		w.AppendF64(v.floatV)
	case jStr:
		w.AppendString(v.str)
	case jArray:
		child := NewWriter()
		for _, item := range v.arr {
			encodeJSON(child, item)
		}
		w.AppendArray(child.Bytes())
	case jObject:
		entries := make([][2][]byte, 0, len(v.obj))
		for _, m := range v.obj {
			kw := NewWriter()
			kw.AppendString(m.key)
			vw := NewWriter()
			encodeJSON(vw, m.val)
			entries = append(entries, [2][]byte{kw.Bytes(), vw.Bytes()})
		}
		w.AppendMap(entries)
	}
}

// ---------------------------------------------------------------------------
// struple -> JSON
// ---------------------------------------------------------------------------

func renderJSON(sb *strings.Builder, e Element, depth int) error {
	// Bound recursion into nested containers so hostile deeply-nested input is
	// rejected rather than overflowing the stack (Item 5).
	if depth > maxDepth {
		return ErrNestingTooDeep
	}
	switch e.Kind {
	case KindNil, KindUndefined:
		sb.WriteString("null")
	case KindBool:
		if e.Bool {
			sb.WriteString("true")
		} else {
			sb.WriteString("false")
		}
	case KindInt, KindBigInt:
		sb.WriteString(e.Int.String())
	case KindFloat32:
		renderFloat(sb, float64(e.Float32)) // render an f32 by its exact f64 value (cross-port)
	case KindFloat64:
		renderFloat(sb, e.Float64)
	case KindDecimal:
		renderDecimal(sb, e.Decimal)
	case KindTimestamp:
		sb.WriteString(strconv.FormatInt(e.Timestamp, 10))
	case KindUUID:
		renderString(sb, renderUUID(e.UUID))
	case KindString:
		renderString(sb, string(Unescape(e.Body)))
	case KindBytes:
		renderString(sb, base64Std(Unescape(e.Body)))
	case KindArray, KindSet:
		return renderArray(sb, e.Body, depth)
	case KindMap:
		return renderMap(sb, e.Body, depth)
	default:
		return ErrInvalidType
	}
	return nil
}

// renderFloat renders a float as ECMAScript Number::toString — the shortest
// decimal that round-trips to the same f64, formatted per the ECMA-262
// fixed/exponential notation rules. This is the pinned cross-language float text
// format (Item 3). An f32 is rendered by its exact f64 value, so callers must
// promote float32 -> float64 before calling.
func renderFloat(sb *strings.Builder, f float64) {
	if !isFinite(f) {
		sb.WriteString("null") // JSON has no inf/nan (matches JSON.stringify)
		return
	}
	if f == 0 {
		sb.WriteByte('0') // +0.0 and -0.0 both render "0"
		return
	}
	// FormatFloat(.., 'e', -1, 64) yields the shortest significant digits and the
	// base-10 exponent of the most-significant digit: [-]d[.ddd]e±dd.
	s := strconv.FormatFloat(f, 'e', -1, 64)
	if s[0] == '-' {
		sb.WriteByte('-')
		s = s[1:]
	}
	epos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[epos+1:])
	// Gather the significant digits (drop the '.').
	digits := make([]byte, 0, epos)
	for i := 0; i < epos; i++ {
		if s[i] != '.' {
			digits = append(digits, s[i])
		}
	}
	writeEcmaDigits(sb, digits, exp+1)
}

// writeEcmaDigits emits shortest significant digits as ECMAScript
// Number::toString, where n is the integer-part digit count
// (10^(n-1) <= |value| < 10^n).
func writeEcmaDigits(sb *strings.Builder, digits []byte, n int) {
	k := len(digits)
	switch {
	case n >= 1 && n <= 21:
		if k <= n { // integer with trailing zeros
			sb.Write(digits)
			for z := 0; z < n-k; z++ {
				sb.WriteByte('0')
			}
		} else { // decimal point inside the digits
			sb.Write(digits[:n])
			sb.WriteByte('.')
			sb.Write(digits[n:])
		}
	case n <= 0 && n > -6: // 0.00…digits
		sb.WriteString("0.")
		for z := 0; z < -n; z++ {
			sb.WriteByte('0')
		}
		sb.Write(digits)
	default: // exponential: d[.ddd]e±(n-1)
		sb.WriteByte(digits[0])
		if k > 1 {
			sb.WriteByte('.')
			sb.Write(digits[1:])
		}
		sb.WriteByte('e')
		e := n - 1
		if e >= 0 {
			sb.WriteByte('+')
		} else {
			sb.WriteByte('-')
			e = -e
		}
		sb.WriteString(strconv.Itoa(e))
	}
}

func isFinite(f float64) bool {
	return f == f && f-f == 0 // not NaN and not Inf
}

func renderArray(sb *strings.Builder, framed []byte, depth int) error {
	content := Unescape(framed)
	r := NewReader(content)
	sb.WriteByte('[')
	first := true
	for {
		e, ok, err := r.Next()
		if err != nil {
			return err
		}
		if !ok {
			break
		}
		if !first {
			sb.WriteByte(',')
		}
		first = false
		if err := renderJSON(sb, e, depth+1); err != nil {
			return err
		}
	}
	sb.WriteByte(']')
	return nil
}

func renderMap(sb *strings.Builder, framed []byte, depth int) error {
	content := Unescape(framed)
	r := NewReader(content)
	sb.WriteByte('{')
	first := true
	for {
		k, ok, err := r.Next()
		if err != nil {
			return err
		}
		if !ok {
			break
		}
		v, ok, err := r.Next()
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("struple: malformed map")
		}
		if !first {
			sb.WriteByte(',')
		}
		first = false
		if k.Kind == KindString {
			renderString(sb, string(Unescape(k.Body)))
		} else {
			// Non-string key: render its JSON and quote the result.
			var tmp strings.Builder
			if err := renderJSON(&tmp, k, depth+1); err != nil {
				return err
			}
			renderString(sb, tmp.String())
		}
		sb.WriteByte(':')
		if err := renderJSON(sb, v, depth+1); err != nil {
			return err
		}
	}
	sb.WriteByte('}')
	return nil
}

func renderString(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for _, c := range []byte(s) {
		switch c {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		case 0x08:
			sb.WriteString("\\b")
		case 0x0C:
			sb.WriteString("\\f")
		default:
			if c < 0x20 {
				sb.WriteString("\\u")
				const hex = "0123456789abcdef"
				sb.WriteByte('0')
				sb.WriteByte('0')
				sb.WriteByte(hex[c>>4])
				sb.WriteByte(hex[c&0x0F])
			} else {
				sb.WriteByte(c)
			}
		}
	}
	sb.WriteByte('"')
}

func renderUUID(u [16]byte) string {
	const hex = "0123456789abcdef"
	var b strings.Builder
	for i, x := range u {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			b.WriteByte('-')
		}
		b.WriteByte(hex[x>>4])
		b.WriteByte(hex[x&0x0F])
	}
	return b.String()
}

// renderDecimal renders a decimal as an exact JSON number literal: plain
// notation up to a bounded zero-pad, then a scientific fallback so an i32-sized
// exponent can't emit gigabytes of zeros from a tiny input (Item 2).
func renderDecimal(sb *strings.Builder, d Decimal) {
	if d.IsZero() {
		sb.WriteByte('0')
		return
	}
	digs := d.CoefficientDigits() // 0..9 values, most-significant first
	k := int64(len(digs))
	exp10 := d.Exponent() // value = C * 10^exp10

	if d.Negative {
		sb.WriteByte('-')
	}

	// Plain notation would pad this many zeros; past the threshold, switch to
	// scientific notation.
	const maxPlainPad = 40
	var pad int64
	if exp10 >= 0 {
		pad = exp10
	} else if pp := k + exp10; pp > 0 {
		pad = 0
	} else {
		pad = -pp
	}
	if pad > maxPlainPad {
		// d1[.d2…dk]e±E, where E = exp10 + k − 1 (the power of ten of the MSD).
		sb.WriteByte('0' + digs[0])
		if len(digs) > 1 {
			sb.WriteByte('.')
			for _, dd := range digs[1:] {
				sb.WriteByte('0' + dd)
			}
		}
		sciExp := exp10 + k - 1
		sb.WriteByte('e')
		if sciExp >= 0 {
			sb.WriteByte('+')
		} else {
			sb.WriteByte('-')
		}
		sb.WriteString(strconv.FormatInt(absInt64(sciExp), 10))
		return
	}

	if exp10 >= 0 {
		for _, dd := range digs {
			sb.WriteByte('0' + dd)
		}
		for z := int64(0); z < exp10; z++ {
			sb.WriteByte('0')
		}
		return
	}
	pointPos := k + exp10 // number of integer-part digits
	if pointPos > 0 {
		pp := int(pointPos)
		for _, dd := range digs[:pp] {
			sb.WriteByte('0' + dd)
		}
		sb.WriteByte('.')
		for _, dd := range digs[pp:] {
			sb.WriteByte('0' + dd)
		}
	} else {
		sb.WriteString("0.")
		for z := pointPos; z < 0; z++ {
			sb.WriteByte('0')
		}
		for _, dd := range digs {
			sb.WriteByte('0' + dd)
		}
	}
}

func base64Std(data []byte) string {
	const t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var out strings.Builder
	for i := 0; i < len(data); i += 3 {
		b0 := uint32(data[i])
		var b1, b2 uint32
		n := 1
		if i+1 < len(data) {
			b1 = uint32(data[i+1])
			n = 2
		}
		if i+2 < len(data) {
			b2 = uint32(data[i+2])
			n = 3
		}
		v := (b0 << 16) | (b1 << 8) | b2
		out.WriteByte(t[v>>18&63])
		out.WriteByte(t[v>>12&63])
		if n > 1 {
			out.WriteByte(t[v>>6&63])
		} else {
			out.WriteByte('=')
		}
		if n > 2 {
			out.WriteByte(t[v&63])
		} else {
			out.WriteByte('=')
		}
	}
	return out.String()
}

// ---------------------------------------------------------------------------
// A small JSON parser (no dependencies)
// ---------------------------------------------------------------------------

func parseJSON(s string) (jsonValue, error) {
	p := &jsonParser{b: []byte(s)}
	v, err := p.value(0)
	if err != nil {
		return jsonValue{}, err
	}
	p.ws()
	if p.i != len(p.b) {
		return jsonValue{}, errors.New("struple: trailing data after JSON value")
	}
	return v, nil
}

type jsonParser struct {
	b []byte
	i int
}

func (p *jsonParser) peek() (byte, bool) {
	if p.i < len(p.b) {
		return p.b[p.i], true
	}
	return 0, false
}

func (p *jsonParser) ws() {
	for {
		c, ok := p.peek()
		if !ok || (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
			return
		}
		p.i++
	}
}

func (p *jsonParser) value(depth int) (jsonValue, error) {
	// Bound recursion into nested arrays/objects so hostile deeply-nested input
	// is rejected rather than overflowing the stack (Item 5).
	if depth > maxDepth {
		return jsonValue{}, ErrNestingTooDeep
	}
	p.ws()
	c, ok := p.peek()
	if !ok {
		return jsonValue{}, errors.New("struple: unexpected end of input")
	}
	switch {
	case c == 'n':
		if err := p.lit("null"); err != nil {
			return jsonValue{}, err
		}
		return jsonValue{kind: jNull}, nil
	case c == 't':
		if err := p.lit("true"); err != nil {
			return jsonValue{}, err
		}
		return jsonValue{kind: jBool, boolVal: true}, nil
	case c == 'f':
		if err := p.lit("false"); err != nil {
			return jsonValue{}, err
		}
		return jsonValue{kind: jBool, boolVal: false}, nil
	case c == '"':
		s, err := p.string()
		if err != nil {
			return jsonValue{}, err
		}
		return jsonValue{kind: jStr, str: s}, nil
	case c == '[':
		return p.array(depth)
	case c == '{':
		return p.object(depth)
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	default:
		return jsonValue{}, errors.New("struple: unexpected byte in JSON")
	}
}

func (p *jsonParser) lit(s string) error {
	if p.i+len(s) <= len(p.b) && string(p.b[p.i:p.i+len(s)]) == s {
		p.i += len(s)
		return nil
	}
	return errors.New("struple: expected literal " + s)
}

func (p *jsonParser) string() (string, error) {
	p.i++ // opening quote
	var out []byte
	for {
		c, ok := p.peek()
		if !ok {
			return "", errors.New("struple: unterminated string")
		}
		p.i++
		switch c {
		case '"':
			return string(out), nil
		case '\\':
			e, ok := p.peek()
			if !ok {
				return "", errors.New("struple: unterminated escape")
			}
			p.i++
			switch e {
			case '"':
				out = append(out, '"')
			case '\\':
				out = append(out, '\\')
			case '/':
				out = append(out, '/')
			case 'n':
				out = append(out, '\n')
			case 't':
				out = append(out, '\t')
			case 'r':
				out = append(out, '\r')
			case 'b':
				out = append(out, 0x08)
			case 'f':
				out = append(out, 0x0C)
			case 'u':
				cp, err := p.hex4()
				if err != nil {
					return "", err
				}
				switch {
				case cp >= 0xD800 && cp <= 0xDBFF:
					// High surrogate: MUST be immediately followed by a \uXXXX low
					// surrogate (0xDC00–0xDFFF). A high with no following escape, or
					// followed by a non-low code unit, is unpaired — reject rather
					// than emit U+FFFD or a bogus code point (Item 4, surrogate edge).
					if !(p.i+1 < len(p.b) && p.b[p.i] == '\\' && p.b[p.i+1] == 'u') {
						return "", errors.New("struple: unpaired high surrogate")
					}
					p.i += 2
					lo, err := p.hex4()
					if err != nil {
						return "", err
					}
					if lo < 0xDC00 || lo > 0xDFFF {
						return "", errors.New("struple: high surrogate not followed by low surrogate")
					}
					cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
				case cp >= 0xDC00 && cp <= 0xDFFF:
					// Low surrogate with no preceding high surrogate — reject.
					return "", errors.New("struple: unpaired low surrogate")
				}
				out = appendRune(out, cp)
			default:
				return "", errors.New("struple: bad escape")
			}
		default:
			out = append(out, c)
		}
	}
}

func (p *jsonParser) hex4() (uint32, error) {
	if p.i+4 > len(p.b) {
		return 0, errors.New("struple: unterminated \\u escape")
	}
	v, err := strconv.ParseUint(string(p.b[p.i:p.i+4]), 16, 32)
	if err != nil {
		return 0, errors.New("struple: bad hex")
	}
	p.i += 4
	return uint32(v), nil
}

func (p *jsonParser) number() (jsonValue, error) {
	start := p.i
	if c, ok := p.peek(); ok && c == '-' {
		p.i++
	}
	intDigits := 0
	for {
		c, ok := p.peek()
		if !ok || c < '0' || c > '9' {
			break
		}
		p.i++
		intDigits++
	}
	// JSON requires at least one integer digit; a bare sign like "-" (or the
	// "-" left when "-Infinity" is rejected) is not a number. Reject here rather
	// than fall through to an empty big-int, whose SetString("") returns nil and
	// then nil-panics on .Bytes() (Item 4, sign-with-no-digits edge).
	if intDigits == 0 {
		return jsonValue{}, errors.New("struple: number has no digits")
	}
	isFloat := false
	if c, ok := p.peek(); ok && c == '.' {
		isFloat = true
		p.i++
		for {
			c, ok := p.peek()
			if !ok || c < '0' || c > '9' {
				break
			}
			p.i++
		}
	}
	if c, ok := p.peek(); ok && (c == 'e' || c == 'E') {
		isFloat = true
		p.i++
		if c, ok := p.peek(); ok && (c == '+' || c == '-') {
			p.i++
		}
		for {
			c, ok := p.peek()
			if !ok || c < '0' || c > '9' {
				break
			}
			p.i++
		}
	}
	tok := string(p.b[start:p.i])
	if isFloat {
		f, err := strconv.ParseFloat(tok, 64)
		// ParseFloat flags an out-of-range magnitude (e.g. 1e999 -> ±Inf) via err;
		// the explicit isFinite guard makes the "no infinities" rule (Item 4,
		// float-out-of-range edge) hold regardless of the strconv error contract.
		if err != nil || !isFinite(f) {
			return jsonValue{}, errors.New("struple: float out of range")
		}
		return jsonValue{kind: jFloat, floatV: f}, nil
	}
	// Fall back to arbitrary precision when the value exceeds int64.
	if n, err := strconv.ParseInt(tok, 10, 64); err == nil {
		return jsonValue{kind: jInt, intVal: n}, nil
	}
	return jsonValue{kind: jBigInt, str: tok}, nil
}

func (p *jsonParser) array(depth int) (jsonValue, error) {
	p.i++ // [
	var items []jsonValue
	p.ws()
	if c, ok := p.peek(); ok && c == ']' {
		p.i++
		return jsonValue{kind: jArray, arr: items}, nil
	}
	for {
		v, err := p.value(depth + 1)
		if err != nil {
			return jsonValue{}, err
		}
		items = append(items, v)
		p.ws()
		c, ok := p.peek()
		if !ok {
			return jsonValue{}, errors.New("struple: expected , or ]")
		}
		if c == ',' {
			p.i++
			continue
		}
		if c == ']' {
			p.i++
			break
		}
		return jsonValue{}, errors.New("struple: expected , or ]")
	}
	return jsonValue{kind: jArray, arr: items}, nil
}

func (p *jsonParser) object(depth int) (jsonValue, error) {
	p.i++ // {
	var members []jsonMember
	seen := make(map[string]struct{})
	p.ws()
	if c, ok := p.peek(); ok && c == '}' {
		p.i++
		return jsonValue{kind: jObject, obj: members}, nil
	}
	for {
		p.ws()
		if c, ok := p.peek(); !ok || c != '"' {
			return jsonValue{}, errors.New("struple: expected object key")
		}
		key, err := p.string()
		if err != nil {
			return jsonValue{}, err
		}
		// A struple map is canonical and cannot hold two entries for one key, so a
		// repeated key is not representable — reject rather than silently keep one
		// (Item 4, duplicate-object-key edge).
		if _, dup := seen[key]; dup {
			return jsonValue{}, errors.New("struple: duplicate object key")
		}
		seen[key] = struct{}{}
		p.ws()
		if c, ok := p.peek(); !ok || c != ':' {
			return jsonValue{}, errors.New("struple: expected :")
		}
		p.i++
		val, err := p.value(depth + 1)
		if err != nil {
			return jsonValue{}, err
		}
		members = append(members, jsonMember{key: key, val: val})
		p.ws()
		c, ok := p.peek()
		if !ok {
			return jsonValue{}, errors.New("struple: expected , or }")
		}
		if c == ',' {
			p.i++
			continue
		}
		if c == '}' {
			p.i++
			break
		}
		return jsonValue{}, errors.New("struple: expected , or }")
	}
	return jsonValue{kind: jObject, obj: members}, nil
}

// appendRune appends the UTF-8 encoding of a code point.
func appendRune(dst []byte, cp uint32) []byte {
	switch {
	case cp < 0x80:
		return append(dst, byte(cp))
	case cp < 0x800:
		return append(dst, byte(0xC0|cp>>6), byte(0x80|cp&0x3F))
	case cp < 0x10000:
		return append(dst, byte(0xE0|cp>>12), byte(0x80|(cp>>6)&0x3F), byte(0x80|cp&0x3F))
	default:
		return append(dst, byte(0xF0|cp>>18), byte(0x80|(cp>>12)&0x3F), byte(0x80|(cp>>6)&0x3F), byte(0x80|cp&0x3F))
	}
}
