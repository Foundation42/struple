package struple

import (
	"encoding/hex"
	"math/big"
	"testing"
)

// packOne encodes a single value into a fresh buffer.
func packString(s string) []byte {
	w := NewWriter()
	w.AppendString(s)
	return append([]byte(nil), w.Bytes()...)
}

func packInt(n int64) []byte {
	w := NewWriter()
	w.AppendInt(n)
	return append([]byte(nil), w.Bytes()...)
}

// intOf decodes a single-element buffer holding an integer.
func intOf(t *testing.T, encoded []byte) int64 {
	t.Helper()
	r := NewReader(encoded)
	e, ok, err := r.Next()
	if err != nil || !ok {
		t.Fatalf("intOf: decode failed: %v", err)
	}
	if e.Kind != KindInt && e.Kind != KindBigInt {
		t.Fatalf("intOf: not an int (kind %d)", e.Kind)
	}
	return e.Int.Int64()
}

func TestIndexedMap(t *testing.T) {
	// eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts.
	keys := []string{"h", "c", "a", "g", "d", "f", "b", "e"}
	entries := make([][2][]byte, len(keys))
	for i, k := range keys {
		entries[i] = [2][]byte{packString(k), packInt(int64(i + 1))}
	}
	w := NewWriter()
	w.AppendMap(entries)

	mv := NewView(w.Bytes())
	inner, ok, err := mv.ContainedItems()
	if err != nil || !ok {
		t.Fatalf("ContainedItems: %v ok=%v", err, ok)
	}
	im, err := NewIndexedMap(inner)
	if err != nil {
		t.Fatalf("NewIndexedMap: %v", err)
	}

	if im.Count() != 8 {
		t.Fatalf("count = %d, want 8", im.Count())
	}

	// At walks canonical (sorted) order: a,b,c,...,h.
	for i, ch := range "abcdefgh" {
		e, ok := im.At(i)
		if !ok {
			t.Fatalf("At(%d) missing", i)
		}
		kr := NewReader(e.Key)
		ke, _, _ := kr.Next()
		if got := string(Unescape(ke.Body)); got != string(ch) {
			t.Errorf("At(%d) key = %q, want %q", i, got, string(ch))
		}
	}
	if _, ok := im.At(8); ok {
		t.Errorf("At(8) should be out of range")
	}

	// Get binary-searches; agrees with the linear MapView.Get on every key.
	m := NewMapView(inner)
	for _, ch := range "abcdefgh" {
		key := packString(string(ch))
		want, ok, err := m.Get(key)
		if err != nil || !ok {
			t.Fatalf("MapView.Get(%q): ok=%v err=%v", string(ch), ok, err)
		}
		got, ok := im.Get(key)
		if !ok || hex.EncodeToString(got) != hex.EncodeToString(want) {
			t.Errorf("IndexedMap.Get(%q) disagrees with MapView", string(ch))
		}
	}

	// "e" was inserted 8th (value 8) but sits at sorted position 4.
	if idx, ok := im.Find(packString("e")); !ok || idx != 4 {
		t.Errorf("Find(e) = %d ok=%v, want 4", idx, ok)
	}
	if v, ok := im.Get(packString("e")); !ok || intOf(t, v) != 8 {
		t.Errorf("Get(e) value = %d, want 8", intOf(t, v))
	}

	// Misses: before, between, and after the key range.
	if _, ok := im.Get(packString("A")); ok {
		t.Errorf("Get(A) should miss (below a)")
	}
	if _, ok := im.Get(packString("cc")); ok {
		t.Errorf("Get(cc) should miss (between c and d)")
	}
	if _, ok := im.Get(packString("z")); ok {
		t.Errorf("Get(z) should miss (above h)")
	}
	if idx, ok := im.Find(packString("a")); !ok || idx != 0 {
		t.Errorf("Find(a) = %d, want 0", idx)
	}
	if idx, ok := im.Find(packString("h")); !ok || idx != 7 {
		t.Errorf("Find(h) = %d, want 7", idx)
	}

	// Iterator yields the same canonical order.
	it := im.Iterator()
	n := 0
	for {
		_, ok := it.Next()
		if !ok {
			break
		}
		n++
	}
	if n != 8 {
		t.Errorf("iterator yielded %d entries, want 8", n)
	}
}

func TestViewStreamOps(t *testing.T) {
	w := NewWriter()
	w.AppendString("users")
	w.AppendInt(12345)
	w.AppendString("alice")
	w.AppendBool(true)
	v := NewView(w.Bytes())

	if n, _ := v.Count(); n != 4 {
		t.Errorf("Count = %d, want 4", n)
	}
	if !v.IsString() {
		t.Errorf("head should be a string")
	}
	at2, ok, _ := v.At(2)
	if !ok || !NewView(at2).IsString() {
		t.Errorf("At(2) should be a string")
	}
	head, ok, _ := v.Head()
	if !ok || ToJsonMust(t, head) != `"users"` {
		t.Errorf("Head mismatch")
	}
	tail, _ := v.Tail()
	if n, _ := NewView(tail).Count(); n != 3 {
		t.Errorf("Tail count = %d, want 3", n)
	}
	take2, _ := v.Take(2)
	if n, _ := NewView(take2).Count(); n != 2 {
		t.Errorf("Take(2) count = %d, want 2", n)
	}
	rest, _ := v.NthRest(2)
	if n, _ := NewView(rest).Count(); n != 2 {
		t.Errorf("NthRest(2) count = %d, want 2", n)
	}
}

func ToJsonMust(t *testing.T, b []byte) string {
	t.Helper()
	s, err := ToJson(b)
	if err != nil {
		t.Fatalf("ToJson: %v", err)
	}
	return s
}

// ---------------------------------------------------------------------------
// Golden / round-trip tests
// ---------------------------------------------------------------------------

func TestGoldenDecimal(t *testing.T) {
	cases := []struct {
		in  string
		hex string
	}{
		{"12.345", "380321020d233300"},
		{"-12.345", "3801defdf2dcccff"},
		{"100", "380321030b00"},
		{"0.001", "38031ffe0b00"},
		{"12.300", "380321020d1f00"}, // canonicalizes to 12.3
		{"0", "3802"},
		{"1e-9", "38031ff80b00"},
	}
	for _, c := range cases {
		w := NewWriter()
		if err := w.AppendDecimalString(c.in); err != nil {
			t.Fatalf("AppendDecimalString(%q): %v", c.in, err)
		}
		if got := hex.EncodeToString(w.Bytes()); got != c.hex {
			t.Errorf("decimal %q: got %s want %s", c.in, got, c.hex)
		}
	}
}

func TestGoldenUUID(t *testing.T) {
	var zero [16]byte
	w := NewWriter()
	w.AppendUUID(zero)
	want := "44" + "00000000000000000000000000000000"
	if got := hex.EncodeToString(w.Bytes()); got != want {
		t.Errorf("zero uuid: got %s want %s", got, want)
	}
	// Round-trip via ToJson (hyphenated form, one-way).
	js, _ := ToJson(w.Bytes())
	if js != `"00000000-0000-0000-0000-000000000000"` {
		t.Errorf("uuid json = %s", js)
	}
}

func TestGoldenWideInt(t *testing.T) {
	cases := []struct {
		in  string
		hex string
	}{
		{"12345", "223039"},
		{"18446744073709551616", "29010000000000000000"},                                      // 2^64
		{"170141183460469231731687303715884105728", "31011080000000000000000000000000000000"}, // 2^127
		{"-170141183460469231731687303715884105728", "1080000000000000000000000000000000"},    // -2^127
	}
	for _, c := range cases {
		got, err := FromJson(c.in)
		if err != nil {
			t.Fatalf("FromJson(%q): %v", c.in, err)
		}
		if h := hex.EncodeToString(got); h != c.hex {
			t.Errorf("int %q: got %s want %s", c.in, h, c.hex)
		}
		// round-trip back
		back, _ := ToJson(got)
		if back != c.in {
			t.Errorf("int %q round-trip = %s", c.in, back)
		}
	}
}

func TestRoundTripBigIntValue(t *testing.T) {
	// 2^200 + 1 as a big-int value, packed and decoded exactly.
	v := new(big.Int).Lsh(big.NewInt(1), 200)
	v.Add(v, big.NewInt(1))
	w := NewWriter()
	w.AppendBigIntValue(v)
	r := NewReader(w.Bytes())
	e, ok, err := r.Next()
	if err != nil || !ok {
		t.Fatalf("decode: %v", err)
	}
	if e.Int.Cmp(v) != 0 {
		t.Errorf("round-trip big int: got %s want %s", e.Int, v)
	}
}

func TestAppendString(t *testing.T) {
	w := NewWriter()
	w.AppendString("app")
	if got := hex.EncodeToString(w.Bytes()); got != "4861707000" {
		t.Errorf(`"app" = %s, want 4861707000`, got)
	}
}
