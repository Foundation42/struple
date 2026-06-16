// struple reference benchmark (Swift).
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
// untimed); the encoder then rebuilds the bytes with the same appendX sequence
// the Zig reference uses. Byte-identity is verified against bench/payloads.json
// (sha256) before any throughput figure is reported.
//
// Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
// count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
// global checksum sink consumes every result so the optimizer can't elide the
// work. Steady-state buffers retain capacity. Single-threaded.
//
// Foundation is used ONLY to read the corpus files and compute the host label;
// timing uses DispatchTime (monotonic, nanosecond). sha256 is hand-rolled (no
// new dependency). The codec sources are compiled in alongside this file.
//
// Compile + run (mirrors swift/run-tests.sh's toolchain env):
//
//   SWIFTC="${SWIFTC:-$HOME/swift/usr/bin/swiftc}"
//   SWIFT_USR="$(dirname "$(dirname "$SWIFTC")")"
//   export LD_LIBRARY_PATH="$SWIFT_USR/lib/swift/linux:$HOME/swift-shims:$LD_LIBRARY_PATH"
//   export PATH="$SWIFT_USR/bin:$PATH"
//   "$SWIFTC" -O bench/swift/bench.swift swift/Sources/Struple/Struple.swift \
//             -o bench/swift/build/struple-bench
//   ./bench/swift/build/struple-bench    # run from the repo root

import Foundation
import Dispatch

// ---------------------------------------------------------------------------
// Repo-root-relative paths. The binary is run from the repo root, but resolve
// against an explicit BENCH_DIR override or fall back to the well-known layout.
// ---------------------------------------------------------------------------
let benchDir: String = {
    if let env = ProcessInfo.processInfo.environment["BENCH_DIR"] { return env }
    return FileManager.default.currentDirectoryPath + "/bench"
}()
let dataDir = benchDir + "/data"
let resultsDir = benchDir + "/results"

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the optimizer must
// actually perform the work. A wrapping u64 accumulator mirrors the Zig
// `g_sink: u64` exactly.
// ---------------------------------------------------------------------------
var gSink: UInt64 = 0
@inline(__always) func sink(_ v: UInt64) { gSink = gSink &+ v }

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

struct Dec {
    var digits: [UInt8]  // coefficient digits, MSD-first, each 0–9
    var exp: Int32
}
struct Quote {
    var symbol: String
    var bid: Dec
    var ask: Dec
    var last: Double  // f64
    var volume: Int64
    var ts: Int64  // µs since epoch
}
struct Geo {
    var lat: Double
    var lon: Double
    var elevation: Double
    var name: String
    var ts: Int64
}
struct Tweet {
    var id: UInt64  // u64
    var user: String
    var text: String
    var createdAt: Int64
    var likes: Int64
    var retweets: Int64
}
struct Tx {
    var height: Int64
    var txHash: [UInt8]  // 32 bytes
    var from: [UInt8]  // 20 bytes
    var to: [UInt8]  // 20 bytes
    // Big-endian magnitude of the wei value. ≤15 bytes routes through the i128
    // fixed path; ≥17 bytes routes through the big-int path. appendBigInt picks
    // automatically by magnitude, so both kinds use the same call (positive).
    var valueBE: [UInt8]
    var gas: Int64
    var nonce: Int64
    var ts: Int64
}
struct Nested {
    var uid: Int64
    var name: String
    var active: Bool
    var scores: (Int64, Int64, Int64)
}

enum PKind { case quotes, geo, tweets, txs, ints, strings, nested }

struct PayloadMeta {
    let kind: PKind
    let name: String
    let category: String
}

let payloads: [PayloadMeta] = [
    PayloadMeta(kind: .quotes, name: "stock_quotes", category: "streaming"),
    PayloadMeta(kind: .geo, name: "geo_points", category: "streaming"),
    PayloadMeta(kind: .tweets, name: "tweets", category: "streaming"),
    PayloadMeta(kind: .txs, name: "blockchain_txs", category: "streaming"),
    PayloadMeta(kind: .ints, name: "int_stream", category: "structural"),
    PayloadMeta(kind: .strings, name: "string_stream", category: "structural"),
    PayloadMeta(kind: .nested, name: "nested_doc", category: "structural"),
]

struct Data {
    var quotes: [Quote] = []
    var geo: [Geo] = []
    var tweets: [Tweet] = []
    var txs: [Tx] = []
    var ints: [Int64] = []
    var strings: [String] = []
    var nested: [Nested] = []
}

// ---------------------------------------------------------------------------
// Parsing helpers — the shared data fields are all typed strings (so any JSON
// library reads them identically across languages). See bench/README.md.
// ---------------------------------------------------------------------------

// 16 hex digits of the IEEE-754 bits (big-endian) → Double.
@inline(__always) func f64FromHex(_ hex: String) -> Double {
    Double(bitPattern: u64FromHex(hex))
}

@inline(__always) func u64FromHex(_ hex: String) -> UInt64 {
    var v: UInt64 = 0
    for c in hex.utf8 { v = (v << 4) | UInt64(hexNibble(c)) }
    return v
}

@inline(__always) func hexNibble(_ c: UInt8) -> UInt8 {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return 0
    }
}

// digit string "12345" → [1,2,3,4,5]
func digitsFromStr(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(s.utf8.count)
    for c in s.utf8 { out.append(c - 48) }
    return out
}

// hex string (even length) → bytes
func bytesFromHex(_ hex: String) -> [UInt8] {
    let chars = Array(hex.utf8)
    var out = [UInt8]()
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i + 1 < chars.count {
        out.append((hexNibble(chars[i]) << 4) | hexNibble(chars[i + 1]))
        i += 2
    }
    return out
}

// big-endian hex magnitude → trimmed big-endian byte array. Both the `big` and
// `fix` blockchain paths reduce to this: appendBigInt(negative:false,
// magnitude:) routes magnitudes within i128 through the fixed slots and beyond
// i128 through the big-int codes — byte-for-byte identical to the Zig
// appendI128 / appendBigInt split.
func bytesFromHexMagnitude(_ hex: String) -> [UInt8] {
    hex.isEmpty ? [] : bytesFromHex(hex)
}

// ---------------------------------------------------------------------------
// JSON parsing. The corpus values are all quoted ASCII strings, so a tiny
// string-array tokenizer is exact and far faster than JSONSerialization on the
// larger payloads. Returns rows of string tokens. Handles top-level array of
// strings (flat) and array of arrays (rows) uniformly: each inner array is a
// row; a flat array is treated as one element per row.
// ---------------------------------------------------------------------------

func loadBytes(_ name: String) -> [UInt8] {
    let path = dataDir + "/" + name + ".json"
    guard let d = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("FATAL: cannot read \(path)\n".data(using: .utf8)!)
        exit(2)
    }
    return [UInt8](d)
}

// Parse a JSON array-of-strings into native String values (used for the flat
// string_stream and int_stream payloads, and as the element parser for rows).
struct JsonScanner {
    let b: [UInt8]
    var i: Int = 0
    init(_ b: [UInt8]) { self.b = b }

    mutating func skipWS() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
    }

    mutating func expect(_ ch: UInt8) {
        skipWS()
        precondition(i < b.count && b[i] == ch, "expected \(Character(UnicodeScalar(ch))) at \(i)")
        i += 1
    }

    mutating func peek() -> UInt8? {
        skipWS()
        return i < b.count ? b[i] : nil
    }

    // Parse a JSON string literal (after a leading '"') into a Swift String,
    // decoding the escapes the emitter uses (\" \\ \uXXXX).
    mutating func parseString() -> String {
        precondition(b[i] == UInt8(ascii: "\""), "string must start with quote")
        i += 1
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c == UInt8(ascii: "\\") {
                i += 1
                let e = b[i]
                switch e {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 1
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 1
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 1
                case UInt8(ascii: "n"): out.append(0x0A); i += 1
                case UInt8(ascii: "t"): out.append(0x09); i += 1
                case UInt8(ascii: "r"): out.append(0x0D); i += 1
                case UInt8(ascii: "b"): out.append(0x08); i += 1
                case UInt8(ascii: "f"): out.append(0x0C); i += 1
                case UInt8(ascii: "u"):
                    i += 1
                    var cp: UInt32 = 0
                    for _ in 0..<4 { cp = (cp << 4) | UInt32(hexNibble(b[i])); i += 1 }
                    appendUTF8(&out, UnicodeScalar(cp) ?? UnicodeScalar(0xFFFD)!)
                default: out.append(e); i += 1
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    func appendUTF8(_ out: inout [UInt8], _ scalar: UnicodeScalar) {
        for byte in String(scalar).utf8 { out.append(byte) }
    }
}

// Flat array of strings → [String].
func parseStringArray(_ bytes: [UInt8]) -> [String] {
    var s = JsonScanner(bytes)
    s.expect(UInt8(ascii: "["))
    var out = [String]()
    if s.peek() == UInt8(ascii: "]") { s.i += 1; return out }
    while true {
        s.skipWS()
        out.append(s.parseString())
        guard let c = s.peek() else { break }
        if c == UInt8(ascii: ",") { s.i += 1; continue }
        if c == UInt8(ascii: "]") { s.i += 1; break }
        break
    }
    return out
}

// Array of arrays of strings → [[String]].
func parseRows(_ bytes: [UInt8]) -> [[String]] {
    var s = JsonScanner(bytes)
    s.expect(UInt8(ascii: "["))
    var rows = [[String]]()
    if s.peek() == UInt8(ascii: "]") { s.i += 1; return rows }
    while true {
        s.expect(UInt8(ascii: "["))
        var row = [String]()
        if s.peek() == UInt8(ascii: "]") {
            s.i += 1
        } else {
            while true {
                s.skipWS()
                row.append(s.parseString())
                guard let c = s.peek() else { break }
                if c == UInt8(ascii: ",") { s.i += 1; continue }
                if c == UInt8(ascii: "]") { s.i += 1; break }
                break
            }
        }
        rows.append(row)
        guard let c = s.peek() else { break }
        if c == UInt8(ascii: ",") { s.i += 1; continue }
        if c == UInt8(ascii: "]") { s.i += 1; break }
        break
    }
    return rows
}

func readData() -> Data {
    var d = Data()

    let quotesRaw = parseRows(loadBytes("stock_quotes"))
    d.quotes = quotesRaw.map { r in
        Quote(
            symbol: r[0],
            bid: Dec(digits: digitsFromStr(r[1]), exp: Int32(r[2])!),
            ask: Dec(digits: digitsFromStr(r[3]), exp: Int32(r[4])!),
            last: f64FromHex(r[5]),
            volume: Int64(r[6])!,
            ts: Int64(r[7])!)
    }

    let geoRaw = parseRows(loadBytes("geo_points"))
    d.geo = geoRaw.map { r in
        Geo(
            lat: f64FromHex(r[0]),
            lon: f64FromHex(r[1]),
            elevation: f64FromHex(r[2]),
            name: r[3],
            ts: Int64(r[4])!)
    }

    let tweetsRaw = parseRows(loadBytes("tweets"))
    d.tweets = tweetsRaw.map { r in
        Tweet(
            id: UInt64(r[0])!,  // u64 — exceeds Int64; parse exactly via UInt64
            user: r[1],
            text: r[2],
            createdAt: Int64(r[3])!,
            likes: Int64(r[4])!,
            retweets: Int64(r[5])!)
    }

    let txsRaw = parseRows(loadBytes("blockchain_txs"))
    d.txs = txsRaw.map { r in
        Tx(
            height: Int64(r[0])!,
            txHash: bytesFromHex(r[1]),
            from: bytesFromHex(r[2]),
            to: bytesFromHex(r[3]),
            // r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both
            // collapse to a big-endian byte array for appendBigInt.
            valueBE: bytesFromHexMagnitude(r[5]),
            gas: Int64(r[6])!,
            nonce: Int64(r[7])!,
            ts: Int64(r[8])!)
    }

    let intsRaw = parseStringArray(loadBytes("int_stream"))
    d.ints = intsRaw.map { Int64($0)! }

    d.strings = parseStringArray(loadBytes("string_stream"))

    let nestedRaw = parseRows(loadBytes("nested_doc"))
    d.nested = nestedRaw.map { r in
        Nested(
            uid: Int64(r[1])!,
            name: r[2],
            active: r[0] == "1",
            scores: (Int64(r[3])!, Int64(r[4])!, Int64(r[5])!))
    }

    return d
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is reset by the caller each iteration;
// a single reused `scratch` Writer frames one record at a time (reset() truncates
// the backing array, retaining capacity at steady state). Mirrors encodeOnce in
// bench/zig/bench.zig.
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work).
func encodeString(_ s: String) -> [UInt8] {
    var w = Writer()
    w.appendString(s)
    return w.bytes
}
func encodeInt(_ v: Int64) -> [UInt8] {
    var w = Writer()
    w.appendInt(v)
    return w.bytes
}
func encodeBool(_ v: Bool) -> [UInt8] {
    var w = Writer()
    w.appendBool(v)
    return w.bytes
}

let KEY_ACTIVE = encodeString("active")
let KEY_SCORES = encodeString("scores")
let KEY_USER = encodeString("user")
let KEY_ID = encodeString("id")
let KEY_NAME = encodeString("name")

func encodeOnce(_ kind: PKind, _ d: Data, _ out: inout Writer, _ scratch: inout Writer) {
    switch kind {
    case .quotes:
        for q in d.quotes {
            scratch.reset()
            scratch.appendString(q.symbol)
            scratch.appendDecimal(negative: false, digits: q.bid.digits, exp: q.bid.exp)
            scratch.appendDecimal(negative: false, digits: q.ask.digits, exp: q.ask.exp)
            scratch.appendF64(q.last)
            scratch.appendInt(q.volume)
            scratch.appendTimestamp(q.ts)
            out.appendArray(scratch.bytes)
        }
    case .geo:
        for g in d.geo {
            scratch.reset()
            scratch.appendF64(g.lat)
            scratch.appendF64(g.lon)
            scratch.appendF64(g.elevation)
            scratch.appendString(g.name)
            scratch.appendTimestamp(g.ts)
            out.appendArray(scratch.bytes)
        }
    case .tweets:
        for t in d.tweets {
            scratch.reset()
            scratch.appendUInt(t.id)  // u64 id
            scratch.appendString(t.user)
            scratch.appendString(t.text)
            scratch.appendTimestamp(t.createdAt)
            scratch.appendInt(t.likes)
            scratch.appendInt(t.retweets)
            out.appendArray(scratch.bytes)
        }
    case .txs:
        for x in d.txs {
            scratch.reset()
            scratch.appendInt(x.height)
            scratch.appendBytes(x.txHash)
            scratch.appendBytes(x.from)
            scratch.appendBytes(x.to)
            scratch.appendBigInt(negative: false, magnitude: x.valueBE)  // big-int or i128 fixed path, by magnitude
            scratch.appendInt(x.gas)
            scratch.appendInt(x.nonce)
            scratch.appendTimestamp(x.ts)
            out.appendArray(scratch.bytes)
        }
    case .ints:
        for v in d.ints { out.appendInt(v) }
    case .strings:
        for s in d.strings { out.appendString(s) }
    case .nested:
        for n in d.nested {
            // user sub-map { id, name }
            var userW = Writer()
            userW.appendMap([
                (KEY_ID, encodeInt(n.uid)),
                (KEY_NAME, encodeString(n.name)),
            ])
            let user = userW.bytes
            // scores array [s0, s1, s2]
            var scoresInner = Writer()
            scoresInner.appendInt(n.scores.0)
            scoresInner.appendInt(n.scores.1)
            scoresInner.appendInt(n.scores.2)
            var scoresArrW = Writer()
            scoresArrW.appendArray(scoresInner.bytes)
            let scoresArr = scoresArrW.bytes
            // top-level map (appendMap sorts by encoded key, so order here is free)
            out.appendMap([
                (KEY_ACTIVE, encodeBool(n.active)),
                (KEY_SCORES, scoresArr),
                (KEY_USER, user),
            ])
        }
    }
}

func recordCount(_ kind: PKind, _ d: Data) -> Int {
    switch kind {
    case .quotes: return d.quotes.count
    case .geo: return d.geo.count
    case .tweets: return d.tweets.count
    case .txs: return d.txs.count
    case .ints: return d.ints.count
    case .strings: return d.strings.count
    case .nested: return d.nested.count
    }
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). A per-depth scratch
// buffer pool means escape-bearing bodies un-escape in a single pass into a
// reused buffer (no per-container allocation); escape-free bodies recurse on a
// reused copy of the slice (the codec's Reader needs an array). Mirrors the Zig
// `walk` and the Go walkState.
// ---------------------------------------------------------------------------

final class WalkState {
    // One reusable buffer per recursion depth.
    var scratch: [[UInt8]] = []

    func walk(_ depth: Int, _ buf: [UInt8]) {
        var r = Reader(buf)
        while let e = try! r.next() {
            switch e {
            case .nil_, .undef:
                break
            case .boolean(let b):
                sink(b ? 1 : 0)
            case .int(let v):
                sink(UInt64(bitPattern: Int64(truncatingIfNeeded: v)))
            case .bigInt(let bi):
                sink(UInt64(bi.magStored.count))
            case .float32(let f):
                sink(UInt64(f.bitPattern))
            case .float64(let f):
                sink(f.bitPattern)
            case .decimal(let dc):
                sink(UInt64(dc.coeffStored.count) &+ UInt64(bitPattern: dc.adjExp))
            case .timestamp(let ts):
                sink(UInt64(bitPattern: ts))
            case .uuid(let u):
                sink(UInt64(u[0]))
            case .string(let s), .bytes(let s):
                sink(UInt64(s.count))
                if !s.isEmpty { sink(UInt64(s[s.startIndex])) }
            case .array(let framed), .map(let framed), .set(let framed):
                if hasEscapes(framed) {
                    while scratch.count <= depth { scratch.append([]) }
                    scratch[depth] = unescape(framed)
                    walk(depth + 1, scratch[depth])
                } else {
                    while scratch.count <= depth { scratch.append([]) }
                    scratch[depth] = Array(framed)
                    walk(depth + 1, scratch[depth])
                }
            }
        }
    }
}

func walk(_ ws: WalkState, _ buf: [UInt8]) { ws.walk(0, buf) }

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

struct Stats {
    var nsPerOp: Double
    var bytes: Int
    var records: Int
}

func mbPerSec(_ s: Stats) -> Double { (Double(s.bytes) / s.nsPerOp) * 1000.0 }  // bytes/ns → MB/s
func mRecPerSec(_ s: Stats) -> Double { (Double(s.records) / s.nsPerOp) * 1000.0 }  // rec/ns → Mrec/s

let TARGET_TRIAL_NS: UInt64 = 100_000_000  // ~100 ms
let N_TRIALS = 9
let N_WARMUP = 5

@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func buildCanonical(_ kind: PKind, _ d: Data) -> [UInt8] {
    var out = Writer()
    var scratch = Writer()
    encodeOnce(kind, d, &out, &scratch)
    return out.bytes
}

func benchEncode(_ kind: PKind, _ d: Data, _ canonicalLen: Int) -> Stats {
    var out = Writer()
    var scratch = Writer()
    func runOnce() {
        out.reset()
        encodeOnce(kind, d, &out, &scratch)
        sink(UInt64(out.bytes.count))
    }

    for _ in 0..<N_WARMUP { runOnce() }

    var t0 = nowNs()
    runOnce()
    let one = max(nowNs() &- t0, 1)
    let iters = max(1, Int(TARGET_TRIAL_NS / one))

    var trials = [Double](repeating: 0, count: N_TRIALS)
    for t in 0..<N_TRIALS {
        t0 = nowNs()
        for _ in 0..<iters { runOnce() }
        let dt = nowNs() &- t0
        trials[t] = Double(dt) / Double(iters)
    }
    return Stats(nsPerOp: median(trials), bytes: canonicalLen, records: recordCount(kind, d))
}

func benchDecode(_ kind: PKind, _ d: Data, _ bytes: [UInt8]) -> Stats {
    let ws = WalkState()
    func runOnce() { walk(ws, bytes) }

    for _ in 0..<N_WARMUP { runOnce() }

    var t0 = nowNs()
    runOnce()
    let one = max(nowNs() &- t0, 1)
    let iters = max(1, Int(TARGET_TRIAL_NS / one))

    var trials = [Double](repeating: 0, count: N_TRIALS)
    for t in 0..<N_TRIALS {
        t0 = nowNs()
        for _ in 0..<iters { runOnce() }
        let dt = nowNs() &- t0
        trials[t] = Double(dt) / Double(iters)
    }
    return Stats(nsPerOp: median(trials), bytes: bytes.count, records: recordCount(kind, d))
}

// ---------------------------------------------------------------------------
// SHA-256 (self-contained — no new dependency).
// ---------------------------------------------------------------------------

func sha256Hex(_ msg: [UInt8]) -> String {
    let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
    var h: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c,
        0x1f83_d9ab, 0x5be0_cd19,
    ]

    var data = msg
    let bitLen = UInt64(msg.count) * 8
    data.append(0x80)
    while data.count % 64 != 56 { data.append(0) }
    for i in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((bitLen >> UInt64(i)) & 0xFF))
    }

    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    var w = [UInt32](repeating: 0, count: 64)
    var off = 0
    while off < data.count {
        for i in 0..<16 {
            let j = off + i * 4
            w[i] =
                (UInt32(data[j]) << 24) | (UInt32(data[j + 1]) << 16)
                | (UInt32(data[j + 2]) << 8) | UInt32(data[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var dd = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ maj
            hh = g
            g = f
            f = e
            e = dd &+ t1
            dd = c
            c = b
            b = a
            a = t1 &+ t2
        }
        h[0] = h[0] &+ a
        h[1] = h[1] &+ b
        h[2] = h[2] &+ c
        h[3] = h[3] &+ dd
        h[4] = h[4] &+ e
        h[5] = h[5] &+ f
        h[6] = h[6] &+ g
        h[7] = h[7] &+ hh
        off += 64
    }

    var out = ""
    for v in h { out += String(format: "%08x", v) }
    return out
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

func hostLabel() -> String {
    if let d = FileManager.default.contents(atPath: "/proc/cpuinfo"),
        let text = String(data: d, encoding: .utf8)
    {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("model name") {
                if let c = line.firstIndex(of: ":") {
                    return String(line[line.index(after: c)...]).trimmingCharacters(
                        in: .whitespaces)
                }
            }
        }
    }
    return "unknown"
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func padLeft(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
func fmt(_ x: Double, _ d: Int) -> String { String(format: "%.\(d)f", x) }

struct Manifest: Decodable {
    struct P: Decodable {
        let name: String
        let byte_len: Int
        let sha256: String
    }
    let payloads: [P]
}

func main() {
    guard let manifestData = FileManager.default.contents(atPath: benchDir + "/payloads.json"),
        let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
    else {
        FileHandle.standardError.write("FATAL: cannot read payloads.json\n".data(using: .utf8)!)
        exit(2)
    }
    var expected = [String: Manifest.P]()
    for p in manifest.payloads { expected[p.name] = p }

    let data = readData()

    print("struple benchmark (Swift, single-threaded)\n")

    var out = [String: [String: Any]]()
    var allOk = true
    var totalBytes = 0

    for meta in payloads {
        let bytes = buildCanonical(meta.kind, data)
        totalBytes += bytes.count

        // Verify byte-identity against the manifest BEFORE measuring.
        let exp = expected[meta.name]
        let sha = sha256Hex(bytes)
        let shaOk = exp != nil && sha == exp!.sha256 && bytes.count == exp!.byte_len
        if !shaOk {
            allOk = false
            FileHandle.standardError.write(
                ("\nBYTE MISMATCH for \(meta.name):\n"
                    + "  produced byte_len=\(bytes.count) sha256=\(sha)\n"
                    + "  expected byte_len=\(exp?.byte_len ?? -1) sha256=\(exp?.sha256 ?? "?")\n"
                    + "This is a contract bug — STOPPING (no throughput reported for this payload).\n")
                    .data(using: .utf8)!)
            out[meta.name] = [
                "enc_mrec_s": 0.0, "enc_mb_s": 0.0, "dec_mrec_s": 0.0, "dec_mb_s": 0.0,
                "sha256_ok": false,
            ]
            continue
        }

        let enc = benchEncode(meta.kind, data, bytes.count)
        let dec = benchDecode(meta.kind, data, bytes)

        out[meta.name] = [
            "enc_mrec_s": round2(mRecPerSec(enc)),
            "enc_mb_s": round2(mbPerSec(enc)),
            "dec_mrec_s": round2(mRecPerSec(dec)),
            "dec_mb_s": round2(mbPerSec(dec)),
            "sha256_ok": true,
        ]

        print(
            "  \(pad(meta.name, 16)) \(padLeft(String(enc.records), 6)) rec   "
                + "enc \(padLeft(fmt(mRecPerSec(enc), 2), 7)) Mrec/s \(padLeft(fmt(mbPerSec(enc), 0), 6)) MB/s   "
                + "dec \(padLeft(fmt(mRecPerSec(dec), 2), 7)) Mrec/s \(padLeft(fmt(mbPerSec(dec), 0), 6)) MB/s"
                + "   sha ok")
    }

    let host = hostLabel()

    // Emit the results JSON in the README format. Build it by hand to keep the
    // numeric formatting (round2) intact and the key order stable per payload.
    try? FileManager.default.createDirectory(
        atPath: resultsDir, withIntermediateDirectories: true)
    var json = "{\n  \"lang\": \"Swift\",\n  \"host\": \(jsonEscape(host)),\n  \"payloads\": {\n"
    for (idx, meta) in payloads.enumerated() {
        let p = out[meta.name]!
        let ok = (p["sha256_ok"] as! Bool) ? "true" : "false"
        json += "    \(jsonEscape(meta.name)): {\n"
        json += "      \"enc_mrec_s\": \(num(p["enc_mrec_s"]!)),\n"
        json += "      \"enc_mb_s\": \(num(p["enc_mb_s"]!)),\n"
        json += "      \"dec_mrec_s\": \(num(p["dec_mrec_s"]!)),\n"
        json += "      \"dec_mb_s\": \(num(p["dec_mb_s"]!)),\n"
        json += "      \"sha256_ok\": \(ok)\n"
        json += "    }" + (idx + 1 == payloads.count ? "\n" : ",\n")
    }
    json += "  }\n}\n"
    try? json.write(toFile: resultsDir + "/swift.json", atomically: true, encoding: .utf8)

    print(
        "\nHost: \(host) · Total corpus: \(fmt(Double(totalBytes) / 1024.0, 1)) KB · "
            + "Wrote bench/results/swift.json")
    print("(sink \(String(gSink, radix: 16)))")

    if !allOk {
        FileHandle.standardError.write(
            "\nOne or more payloads failed byte-identity — see above.\n".data(using: .utf8)!)
        exit(1)
    }
}

func jsonEscape(_ s: String) -> String {
    var out = "\""
    for c in s {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default: out.append(c)
        }
    }
    out += "\""
    return out
}

func num(_ v: Any) -> String {
    if let d = v as? Double {
        // Match the README sample (one decimal where integral, else two). Use a
        // compact form: drop a trailing ".0" only if it's an exact integer.
        if d == d.rounded() && abs(d) < 1e15 {
            return String(format: "%.1f", d)
        }
        return String(format: "%g", d)
    }
    return "\(v)"
}

main()
