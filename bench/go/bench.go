// struple reference benchmark (Go).
//
// Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
// stream from prepared in-memory records) and decode (walk the whole stream,
// descending and un-escaping every container body and touching every scalar)
// throughput for the seven shared workloads — four realistic streaming shapes
// (stock quotes, geospatial points, tweets, blockchain transactions) plus three
// structural micro-benchmarks (an integer stream, a string stream, a nested
// document).
//
// The native records are parsed from bench/data/<name>.json once (setup,
// untimed) via encoding/json; the encoder then rebuilds the bytes with the same
// appendX sequence the Zig reference uses. Byte-identity is verified against
// bench/payloads.json (sha256) before any throughput figure is reported.
//
// Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
// count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
// package-level checksum sink consumes every result so the compiler can't elide
// the work. Steady-state buffers retain capacity. Single-threaded.
//
// Zero dependencies beyond the standard library. Build is optimized by default.
//
// Run from anywhere (paths are resolved relative to this source file):
//
//	cd bench/go && go run .
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	struple "github.com/Foundation42/struple/go"
)

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the compiler must
// actually perform the work. A uint64 accumulator (wrapping) mirrors the Zig
// `g_sink: u64` exactly.
// ---------------------------------------------------------------------------
var gSink uint64

func sink(v uint64) { gSink += v }

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

// dec is a price as an exact decimal: coefficient digits (MSD-first, each 0–9)
// times 10^exp.
type dec struct {
	digits []byte
	exp    int
}

type quote struct {
	symbol string
	bid    dec
	ask    dec
	last   float64
	volume int64
	ts     int64 // µs since epoch
}

type geo struct {
	lat       float64
	lon       float64
	elevation float64
	name      string
	ts        int64
}

type tweet struct {
	id        uint64 // u64 (exceeds 2^53; parsed exactly)
	user      string
	text      string
	createdAt int64
	likes     int64
	retweets  int64
}

type tx struct {
	height int64
	txHash []byte // 32 bytes
	from   []byte // 20 bytes
	to     []byte // 20 bytes
	// value is the wei value's big-endian magnitude reduced to an exact integer;
	// AppendBigIntValue routes magnitudes within i128 through the fixed slots and
	// magnitudes beyond i128 through the big-int codes, byte-for-byte identical to
	// the Zig appendI128 / appendBigInt split.
	value *big.Int
	gas   int64
	nonce int64
	ts    int64
}

type nested struct {
	uid    int64
	name   string
	active bool
	scores [3]int64
}

type pKind int

const (
	kindQuotes pKind = iota
	kindGeo
	kindTweets
	kindTxs
	kindInts
	kindStrings
	kindNested
)

type data struct {
	quotes  []quote
	geo     []geo
	tweets  []tweet
	txs     []tx
	ints    []int64
	strings []string
	nested  []nested
}

type payloadMeta struct {
	kind     pKind
	name     string
	category string
}

var payloads = []payloadMeta{
	{kindQuotes, "stock_quotes", "streaming"},
	{kindGeo, "geo_points", "streaming"},
	{kindTweets, "tweets", "streaming"},
	{kindTxs, "blockchain_txs", "streaming"},
	{kindInts, "int_stream", "structural"},
	{kindStrings, "string_stream", "structural"},
	{kindNested, "nested_doc", "structural"},
}

// ---------------------------------------------------------------------------
// Parsing helpers — the shared data fields are all typed strings (so any JSON
// library reads them identically across languages). See bench/README.md.
// ---------------------------------------------------------------------------

// 16 hex digits of the IEEE-754 bits (big-endian) → float64.
func f64FromHex(h string) float64 {
	bits, err := strconv.ParseUint(h, 16, 64)
	if err != nil {
		panic("bad f64 hex " + h + ": " + err.Error())
	}
	return math.Float64frombits(bits)
}

// digit string "12345" → [1,2,3,4,5]
func digitsFromStr(s string) []byte {
	out := make([]byte, len(s))
	for i := 0; i < len(s); i++ {
		out[i] = s[i] - '0'
	}
	return out
}

// hex string (even length) → bytes
func bytesFromHex(h string) []byte {
	b, err := hex.DecodeString(h)
	if err != nil {
		panic("bad hex " + h + ": " + err.Error())
	}
	return b
}

// big-endian hex magnitude → *big.Int (both the `big` and `fix` blockchain paths
// reduce to this; AppendBigIntValue picks the fixed vs big-int codes by
// magnitude).
func bigFromHex(h string) *big.Int {
	v := new(big.Int)
	if h == "" {
		return v
	}
	if _, ok := v.SetString(h, 16); !ok {
		panic("bad big hex " + h)
	}
	return v
}

func mustI64(s string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("bad int " + s + ": " + err.Error())
	}
	return v
}

func mustU64(s string) uint64 {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		panic("bad uint " + s + ": " + err.Error())
	}
	return v
}

func readData(dataDir string) data {
	load := func(name string, out interface{}) {
		raw, err := os.ReadFile(filepath.Join(dataDir, name+".json"))
		if err != nil {
			panic(err)
		}
		if err := json.Unmarshal(raw, out); err != nil {
			panic("parse " + name + ": " + err.Error())
		}
	}

	var quotesRaw [][]string
	load("stock_quotes", &quotesRaw)
	quotes := make([]quote, len(quotesRaw))
	for i, r := range quotesRaw {
		quotes[i] = quote{
			symbol: r[0],
			bid:    dec{digits: digitsFromStr(r[1]), exp: int(mustI64(r[2]))},
			ask:    dec{digits: digitsFromStr(r[3]), exp: int(mustI64(r[4]))},
			last:   f64FromHex(r[5]),
			volume: mustI64(r[6]),
			ts:     mustI64(r[7]),
		}
	}

	var geoRaw [][]string
	load("geo_points", &geoRaw)
	geos := make([]geo, len(geoRaw))
	for i, r := range geoRaw {
		geos[i] = geo{
			lat:       f64FromHex(r[0]),
			lon:       f64FromHex(r[1]),
			elevation: f64FromHex(r[2]),
			name:      r[3],
			ts:        mustI64(r[4]),
		}
	}

	var tweetsRaw [][]string
	load("tweets", &tweetsRaw)
	tweets := make([]tweet, len(tweetsRaw))
	for i, r := range tweetsRaw {
		tweets[i] = tweet{
			id:        mustU64(r[0]),
			user:      r[1],
			text:      r[2],
			createdAt: mustI64(r[3]),
			likes:     mustI64(r[4]),
			retweets:  mustI64(r[5]),
		}
	}

	var txsRaw [][]string
	load("blockchain_txs", &txsRaw)
	txs := make([]tx, len(txsRaw))
	for i, r := range txsRaw {
		// r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both collapse
		// to a *big.Int for AppendBigIntValue.
		txs[i] = tx{
			height: mustI64(r[0]),
			txHash: bytesFromHex(r[1]),
			from:   bytesFromHex(r[2]),
			to:     bytesFromHex(r[3]),
			value:  bigFromHex(r[5]),
			gas:    mustI64(r[6]),
			nonce:  mustI64(r[7]),
			ts:     mustI64(r[8]),
		}
	}

	var intsRaw []string
	load("int_stream", &intsRaw)
	ints := make([]int64, len(intsRaw))
	for i, s := range intsRaw {
		ints[i] = mustI64(s)
	}

	var strs []string
	load("string_stream", &strs)

	var nestedRaw [][]string
	load("nested_doc", &nestedRaw)
	nesteds := make([]nested, len(nestedRaw))
	for i, r := range nestedRaw {
		nesteds[i] = nested{
			active: r[0] == "1",
			uid:    mustI64(r[1]),
			name:   r[2],
			scores: [3]int64{mustI64(r[3]), mustI64(r[4]), mustI64(r[5])},
		}
	}

	return data{
		quotes:  quotes,
		geo:     geos,
		tweets:  tweets,
		txs:     txs,
		ints:    ints,
		strings: strs,
		nested:  nesteds,
	}
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is reset by the caller each iteration;
// a single reused `scratch` Writer frames one record at a time (Reset truncates
// its backing slice, retaining capacity at steady state). Mirrors encodeOnce in
// bench/zig/bench.zig.
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work).
var (
	keyActive = encodeString("active")
	keyScores = encodeString("scores")
	keyUser   = encodeString("user")
	keyID     = encodeString("id")
	keyName   = encodeString("name")
)

func encodeString(s string) []byte {
	w := struple.NewWriter()
	w.AppendString(s)
	return append([]byte(nil), w.Bytes()...)
}
func encodeInt(v int64) []byte {
	w := struple.NewWriter()
	w.AppendInt(v)
	return append([]byte(nil), w.Bytes()...)
}
func encodeBool(v bool) []byte {
	w := struple.NewWriter()
	w.AppendBool(v)
	return append([]byte(nil), w.Bytes()...)
}

func encodeOnce(kind pKind, d *data, out, scratch *struple.Writer) {
	switch kind {
	case kindQuotes:
		for i := range d.quotes {
			q := &d.quotes[i]
			scratch.Reset()
			scratch.AppendString(q.symbol)
			scratch.AppendDecimal(false, q.bid.digits, q.bid.exp)
			scratch.AppendDecimal(false, q.ask.digits, q.ask.exp)
			scratch.AppendF64(q.last)
			scratch.AppendInt(q.volume)
			scratch.AppendTimestamp(q.ts)
			out.AppendArray(scratch.Bytes())
		}
	case kindGeo:
		for i := range d.geo {
			g := &d.geo[i]
			scratch.Reset()
			scratch.AppendF64(g.lat)
			scratch.AppendF64(g.lon)
			scratch.AppendF64(g.elevation)
			scratch.AppendString(g.name)
			scratch.AppendTimestamp(g.ts)
			out.AppendArray(scratch.Bytes())
		}
	case kindTweets:
		for i := range d.tweets {
			t := &d.tweets[i]
			scratch.Reset()
			scratch.AppendUint(t.id) // u64 id
			scratch.AppendString(t.user)
			scratch.AppendString(t.text)
			scratch.AppendTimestamp(t.createdAt)
			scratch.AppendInt(t.likes)
			scratch.AppendInt(t.retweets)
			out.AppendArray(scratch.Bytes())
		}
	case kindTxs:
		for i := range d.txs {
			x := &d.txs[i]
			scratch.Reset()
			scratch.AppendInt(x.height)
			scratch.AppendBytes(x.txHash)
			scratch.AppendBytes(x.from)
			scratch.AppendBytes(x.to)
			scratch.AppendBigIntValue(x.value) // big-int or i128 fixed path, by magnitude
			scratch.AppendInt(x.gas)
			scratch.AppendInt(x.nonce)
			scratch.AppendTimestamp(x.ts)
			out.AppendArray(scratch.Bytes())
		}
	case kindInts:
		for _, v := range d.ints {
			out.AppendInt(v)
		}
	case kindStrings:
		for _, s := range d.strings {
			out.AppendString(s)
		}
	case kindNested:
		for i := range d.nested {
			n := &d.nested[i]
			// user sub-map { id, name }
			user := struple.NewWriter()
			user.AppendMap([][2][]byte{
				{keyID, encodeInt(n.uid)},
				{keyName, encodeString(n.name)},
			})
			// scores array [s0, s1, s2]
			scoresInner := struple.NewWriter()
			scoresInner.AppendInt(n.scores[0])
			scoresInner.AppendInt(n.scores[1])
			scoresInner.AppendInt(n.scores[2])
			scoresArr := struple.NewWriter()
			scoresArr.AppendArray(scoresInner.Bytes())
			// top-level map (AppendMap sorts by encoded key, so order here is free)
			out.AppendMap([][2][]byte{
				{keyActive, encodeBool(n.active)},
				{keyScores, append([]byte(nil), scoresArr.Bytes()...)},
				{keyUser, append([]byte(nil), user.Bytes()...)},
			})
		}
	}
}

func recordCount(kind pKind, d *data) int {
	switch kind {
	case kindQuotes:
		return len(d.quotes)
	case kindGeo:
		return len(d.geo)
	case kindTweets:
		return len(d.tweets)
	case kindTxs:
		return len(d.txs)
	case kindInts:
		return len(d.ints)
	case kindStrings:
		return len(d.strings)
	case kindNested:
		return len(d.nested)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). Escape-free bodies
// sub-read zero-copy; otherwise unescape in a single pass into a reused scratch
// buffer, mirroring the Zig walk.
// ---------------------------------------------------------------------------

// hasEscapes reports whether a framed container body contains an escaped 0x00
// (a 0x00 0xFF pair). Such a body must be un-escaped before sub-reading.
func hasEscapes(framed []byte) bool {
	for i := 0; i < len(framed); i++ {
		if framed[i] == 0x00 {
			return true
		}
	}
	return false
}

// unescapeInto un-escapes a framed body (0x00 0xFF -> 0x00) into dst (reused),
// returning the populated prefix. The unescaped length is always <= len(framed).
func unescapeInto(framed, dst []byte) []byte {
	out := dst[:0]
	for i := 0; i < len(framed); i++ {
		out = append(out, framed[i])
		if framed[i] == 0x00 {
			i++ // skip the escape byte
		}
	}
	return out
}

// walkState carries a per-depth reusable unescape scratch buffer so the decode
// walk does no per-container allocation when bodies need un-escaping.
type walkState struct {
	scratch [][]byte // one buffer per recursion depth
}

func (ws *walkState) walk(depth int, buf []byte) {
	r := struple.NewReader(buf)
	for {
		e, ok, err := r.Next()
		if err != nil {
			panic(err)
		}
		if !ok {
			break
		}
		switch e.Kind {
		case struple.KindNil, struple.KindUndefined:
		case struple.KindBool:
			if e.Bool {
				sink(1)
			}
		case struple.KindInt:
			sink(uint64(e.Int.Int64()))
		case struple.KindBigInt:
			sink(uint64(len(e.Int.Bytes())))
		case struple.KindFloat32:
			sink(uint64(math.Float32bits(e.Float32)))
		case struple.KindFloat64:
			sink(math.Float64bits(e.Float64))
		case struple.KindDecimal:
			sink(uint64(len(e.Decimal.CoeffStored)) + uint64(e.Decimal.AdjExp))
		case struple.KindTimestamp:
			sink(uint64(e.Timestamp))
		case struple.KindUUID:
			sink(uint64(e.UUID[0]))
		case struple.KindString, struple.KindBytes:
			sink(uint64(len(e.Body)))
			if len(e.Body) > 0 {
				sink(uint64(e.Body[0]))
			}
		case struple.KindArray, struple.KindMap, struple.KindSet:
			if hasEscapes(e.Body) {
				for len(ws.scratch) <= depth {
					ws.scratch = append(ws.scratch, nil)
				}
				ws.scratch[depth] = unescapeInto(e.Body, growCap(ws.scratch[depth], len(e.Body)))
				ws.walk(depth+1, ws.scratch[depth])
			} else {
				ws.walk(depth+1, e.Body)
			}
		}
	}
}

// growCap returns a slice with at least n capacity, reusing buf when possible.
func growCap(buf []byte, n int) []byte {
	if cap(buf) >= n {
		return buf
	}
	return make([]byte, 0, n)
}

func walk(ws *walkState, buf []byte) { ws.walk(0, buf) }

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

type stats struct {
	nsPerOp float64
	bytes   int
	records int
}

func mbPerSec(s stats) float64 { return (float64(s.bytes) / s.nsPerOp) * 1000.0 } // bytes/ns → MB/s
func mRecPerSec(s stats) float64 {
	return (float64(s.records) / s.nsPerOp) * 1000.0 // rec/ns → Mrec/s
}

const (
	targetTrialNs = 100 * 1000 * 1000 // ~100 ms
	nTrials       = 9
	nWarmup       = 5
)

func median(values []float64) float64 {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	return sorted[len(sorted)/2]
}

func buildCanonical(kind pKind, d *data) []byte {
	out := struple.NewWriter()
	scratch := struple.NewWriter()
	encodeOnce(kind, d, out, scratch)
	return append([]byte(nil), out.Bytes()...)
}

func benchEncode(kind pKind, d *data, canonicalLen int) stats {
	out := struple.NewWriter()
	scratch := struple.NewWriter()
	runOnce := func() {
		out.Reset()
		encodeOnce(kind, d, out, scratch)
		sink(uint64(len(out.Bytes())))
	}

	for i := 0; i < nWarmup; i++ {
		runOnce()
	}

	t0 := time.Now()
	runOnce()
	one := time.Since(t0).Nanoseconds()
	if one <= 0 {
		one = 1
	}
	n := int(targetTrialNs / one)
	if n < 1 {
		n = 1
	}

	trials := make([]float64, nTrials)
	for t := 0; t < nTrials; t++ {
		start := time.Now()
		for j := 0; j < n; j++ {
			runOnce()
		}
		dt := time.Since(start).Nanoseconds()
		trials[t] = float64(dt) / float64(n)
	}
	return stats{nsPerOp: median(trials), bytes: canonicalLen, records: recordCount(kind, d)}
}

func benchDecode(kind pKind, d *data, bytes []byte) stats {
	ws := &walkState{}
	runOnce := func() { walk(ws, bytes) }

	for i := 0; i < nWarmup; i++ {
		runOnce()
	}

	t0 := time.Now()
	runOnce()
	one := time.Since(t0).Nanoseconds()
	if one <= 0 {
		one = 1
	}
	n := int(targetTrialNs / one)
	if n < 1 {
		n = 1
	}

	trials := make([]float64, nTrials)
	for t := 0; t < nTrials; t++ {
		start := time.Now()
		for j := 0; j < n; j++ {
			runOnce()
		}
		dt := time.Since(start).Nanoseconds()
		trials[t] = float64(dt) / float64(n)
	}
	return stats{nsPerOp: median(trials), bytes: len(bytes), records: recordCount(kind, d)}
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

func hostLabel() string {
	text, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return "unknown"
	}
	for _, line := range strings.Split(string(text), "\n") {
		if strings.HasPrefix(line, "model name") {
			if c := strings.IndexByte(line, ':'); c != -1 {
				return strings.TrimSpace(line[c+1:])
			}
		}
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

type payloadResult struct {
	EncMrecS float64 `json:"enc_mrec_s"`
	EncMbS   float64 `json:"enc_mb_s"`
	DecMrecS float64 `json:"dec_mrec_s"`
	DecMbS   float64 `json:"dec_mb_s"`
	Sha256OK bool    `json:"sha256_ok"`
}

type resultsFile struct {
	Lang     string                   `json:"lang"`
	Host     string                   `json:"host"`
	Payloads map[string]payloadResult `json:"payloads"`
}

type manifestEntry struct {
	Name    string `json:"name"`
	ByteLen int    `json:"byte_len"`
	Sha256  string `json:"sha256"`
}

type manifest struct {
	Payloads []manifestEntry `json:"payloads"`
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func round2(x float64) float64 { return math.Round(x*100) / 100 }

func main() {
	// Resolve paths relative to this source file (runnable from anywhere), like
	// the JS port.
	_, thisFile, _, _ := runtime.Caller(0)
	here := filepath.Dir(thisFile)
	benchDir := filepath.Dir(here)
	dataDir := filepath.Join(benchDir, "data")
	resultsDir := filepath.Join(benchDir, "results")

	rawManifest, err := os.ReadFile(filepath.Join(benchDir, "payloads.json"))
	if err != nil {
		panic(err)
	}
	var m manifest
	if err := json.Unmarshal(rawManifest, &m); err != nil {
		panic(err)
	}
	expected := make(map[string]manifestEntry, len(m.Payloads))
	for _, p := range m.Payloads {
		expected[p.Name] = p
	}

	d := readData(dataDir)

	fmt.Printf("struple benchmark (Go %s, single-threaded)\n\n", runtime.Version())

	out := make(map[string]payloadResult, len(payloads))
	allOK := true
	totalBytes := 0

	for _, meta := range payloads {
		bytes := buildCanonical(meta.kind, &d)
		totalBytes += len(bytes)

		// Verify byte-identity against the manifest BEFORE measuring.
		exp, haveExp := expected[meta.name]
		sha := sha256Hex(bytes)
		shaOK := haveExp && sha == exp.Sha256 && len(bytes) == exp.ByteLen
		if !shaOK {
			allOK = false
			fmt.Fprintf(os.Stderr,
				"\nBYTE MISMATCH for %s:\n"+
					"  produced byte_len=%d sha256=%s\n"+
					"  expected byte_len=%d sha256=%s\n"+
					"This is a contract bug — STOPPING (no throughput reported for this payload).\n",
				meta.name, len(bytes), sha, exp.ByteLen, exp.Sha256)
			out[meta.name] = payloadResult{Sha256OK: false}
			continue
		}

		enc := benchEncode(meta.kind, &d, len(bytes))
		dec := benchDecode(meta.kind, &d, bytes)

		out[meta.name] = payloadResult{
			EncMrecS: round2(mRecPerSec(enc)),
			EncMbS:   round2(mbPerSec(enc)),
			DecMrecS: round2(mRecPerSec(dec)),
			DecMbS:   round2(mbPerSec(dec)),
			Sha256OK: true,
		}

		fmt.Printf("  %-16s %6d rec   enc %7.2f Mrec/s %6.0f MB/s   dec %7.2f Mrec/s %6.0f MB/s   sha ok\n",
			meta.name, enc.records,
			mRecPerSec(enc), mbPerSec(enc), mRecPerSec(dec), mbPerSec(dec))
	}

	host := hostLabel()
	result := resultsFile{Lang: "Go", Host: host, Payloads: out}

	if err := os.MkdirAll(resultsDir, 0o755); err != nil {
		panic(err)
	}
	enc, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(resultsDir, "go.json"), append(enc, '\n'), 0o644); err != nil {
		panic(err)
	}

	fmt.Printf("\nHost: %s · Total corpus: %.1f KB · Wrote bench/results/go.json\n",
		host, float64(totalBytes)/1024.0)
	fmt.Printf("(sink %x)\n", gSink)

	if !allOK {
		fmt.Fprintln(os.Stderr, "\nOne or more payloads failed byte-identity — see above.")
		os.Exit(1)
	}
}
