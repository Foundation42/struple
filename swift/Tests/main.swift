// Conformance + behavioral test runner for the Swift struple port.
//
// Compiled together with the Struple sources by swiftc, so it can call internal
// API directly. Runs in two phases:
//
//   1. Conformance over ../conformance/vectors.json + semantic_vectors.json (the
//      language-neutral oracle). Every vector must reproduce in both directions:
//        json  -> fromJson(json) == bytes  and  toJson(bytes) == json
//        build -> encode(build(op)) == bytes  and  transcode(bytes) == bytes
//        sem   -> semanticOrder(a, b) == order
//      The build interpreter mirrors the Zig gen_vectors `buildInto`.
//   2. Navigation / IndexedMap / golden round-trip checks (mirrors src/tests.zig).
//
// CWD must be swift/ so ../conformance resolves. Prints a summary; exit(1) on any
// failure. Foundation is used ONLY to read the corpus files — the precision-
// sensitive values there are quoted strings, so JSONSerialization is safe.

import Foundation

var passed = 0
var failed = 0

func check(_ ok: Bool, _ label: @autoclosure () -> String) {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("  FAIL: \(label())")
    }
}

func toHex(_ b: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(b.count * 2)
    for x in b {
        out.append(digits[Int(x >> 4)])
        out.append(digits[Int(x & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

func fromHex(_ s: String) -> [UInt8] {
    let chars = Array(s.utf8)
    var out = [UInt8]()
    out.reserveCapacity(chars.count / 2)
    func nib(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return 0
        }
    }
    var i = 0
    while i + 1 < chars.count {
        out.append((nib(chars[i]) << 4) | nib(chars[i + 1]))
        i += 2
    }
    return out
}

func loadCorpus(_ name: String) -> [[String: Any]] {
    let path = "../conformance/" + name
    guard let data = FileManager.default.contents(atPath: path) else {
        print("FATAL: cannot read \(path)")
        exit(2)
    }
    guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        print("FATAL: cannot parse \(path)")
        exit(2)
    }
    return arr
}

// MARK: - Build-op interpreter (mirrors src/gen_vectors.zig buildInto)

func buildInto(_ w: inout Writer, _ op: [String: Any]) throws {
    guard let (key, val) = op.first else { fatalError("op must be a one-key object") }
    switch key {
    case "nil": w.appendNil()
    case "undef": w.appendUndefined()
    case "bool": w.appendBool((val as? Bool) ?? false)
    case "int": w.appendInt(Int64(val as! String)!)
    case "float64": w.appendF64(opFloat(val))
    case "float32": w.appendF32(Float(opFloat(val)))
    case "decimal": try w.appendDecimalString(val as! String)
    case "timestamp": w.appendTimestamp(Int64(val as! String)!)
    case "uuid":
        let raw = fromHex(val as! String)
        precondition(raw.count == 16, "uuid must be 16 bytes")
        w.appendUuid(raw)
    case "string": w.appendString(val as! String)
    case "bytes": w.appendBytes(fromHex(val as! String))
    case "array":
        var child = Writer()
        for item in val as! [[String: Any]] { try buildInto(&child, item) }
        w.appendArray(child.bytes)
    case "set":
        var elems: [[UInt8]] = []
        for item in val as! [[String: Any]] {
            var ep = Writer()
            try buildInto(&ep, item)
            elems.append(ep.bytes)
        }
        w.appendSet(elems)
    case "map":
        var entries: [([UInt8], [UInt8])] = []
        for pair in val as! [[[String: Any]]] {
            var kp = Writer()
            try buildInto(&kp, pair[0])
            var vp = Writer()
            try buildInto(&vp, pair[1])
            entries.append((kp.bytes, vp.bytes))
        }
        w.appendMap(entries)
    default:
        fatalError("unknown op \(key)")
    }
}

func opFloat(_ v: Any) -> Double {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    return 0
}

func buildOne(_ op: [String: Any]) throws -> [UInt8] {
    var w = Writer()
    try buildInto(&w, op)
    return w.bytes
}

// MARK: - Phase 1: conformance

func runConformance() {
    let vectors = loadCorpus("vectors.json")
    check(!vectors.isEmpty, "corpus is non-empty")

    var jsonEnc = 0
    var jsonDec = 0
    var buildEnc = 0
    var buildTrans = 0

    for v in vectors {
        let wantBytes = v["bytes"] as! String
        if let json = v["json"] as? String {
            // fromJson(json) == bytes
            do {
                let got = try fromJson(json)
                check(toHex(got) == wantBytes, "fromJson \(json) -> \(toHex(got)) want \(wantBytes)")
                if toHex(got) == wantBytes { jsonEnc += 1 }
            } catch {
                check(false, "fromJson \(json) threw \(error)")
            }
            // toJson(bytes) == json
            do {
                let got = try toJson(fromHex(wantBytes))
                check(got == json, "toJson \(wantBytes) -> \(got) want \(json)")
                if got == json { jsonDec += 1 }
            } catch {
                check(false, "toJson \(wantBytes) threw \(error)")
            }
        } else if let op = v["build"] as? [String: Any] {
            // encode(build(op)) == bytes
            do {
                let got = try buildOne(op)
                check(toHex(got) == wantBytes, "build \(op) -> \(toHex(got)) want \(wantBytes)")
                if toHex(got) == wantBytes { buildEnc += 1 }
            } catch {
                check(false, "build \(op) threw \(error)")
            }
            // transcode(bytes) == bytes
            do {
                let got = try transcode(fromHex(wantBytes))
                check(toHex(got) == wantBytes, "transcode \(wantBytes) -> \(toHex(got))")
                if toHex(got) == wantBytes { buildTrans += 1 }
            } catch {
                check(false, "transcode \(wantBytes) threw \(error)")
            }
        } else {
            check(false, "vector has neither json nor build: \(v)")
        }
    }
    print(
        "  vectors: json encode \(jsonEnc), json decode \(jsonDec), build encode \(buildEnc), transcode \(buildTrans)"
    )

    let sem = loadCorpus("semantic_vectors.json")
    var semOk = 0
    for pr in sem {
        let a = fromHex(pr["a"] as! String)
        let b = fromHex(pr["b"] as! String)
        let want = (pr["order"] as! NSNumber).intValue
        do {
            let got = try semanticOrder(a, b)
            check(
                got == want,
                "semantic \(pr["a"] as! String) <=> \(pr["b"] as! String): got \(got) want \(want)")
            if got == want { semOk += 1 }
        } catch {
            check(false, "semanticOrder threw \(error)")
        }
    }
    print("  semantic pairs: \(semOk)/\(sem.count)")
}

// MARK: - Phase 2: navigation / IndexedMap / golden

func packString(_ s: String) -> [UInt8] {
    var w = Writer()
    w.appendString(s)
    return w.bytes
}

func packInt(_ n: Int64) -> [UInt8] {
    var w = Writer()
    w.appendInt(n)
    return w.bytes
}

func intOf(_ encoded: ArraySlice<UInt8>) -> Int128 {
    var r = Reader(encoded)
    guard let e = try? r.next() else { return 0 }
    switch e {
    case .int(let v): return v
    case .bigInt(let bi):
        // small helper: only used for values that fit
        var v: Int128 = 0
        for b in bi.magnitude { v = (v << 8) | Int128(b) }
        return bi.negative ? -v : v
    default: return 0
    }
}

func runNavigation() {
    // ---- IndexedMap: eight entries "a".."h" -> 1..8, fed out of order ----
    let keys = ["h", "c", "a", "g", "d", "f", "b", "e"]
    var entries: [([UInt8], [UInt8])] = []
    for (i, k) in keys.enumerated() {
        entries.append((packString(k), packInt(Int64(i + 1))))
    }
    var w = Writer()
    w.appendMap(entries)

    let mv = View(w.bytes)
    guard let inner2 = try? mv.containedItems() else {
        check(false, "containedItems returned nil")
        return
    }
    guard let im = try? IndexedMap(inner2) else {
        check(false, "IndexedMap init failed")
        return
    }

    check(im.count == 8, "IndexedMap count == 8 (got \(im.count))")

    // At walks canonical (sorted) order: a,b,c,...,h.
    for (i, ch) in "abcdefgh".enumerated() {
        guard let e = im.at(i) else {
            check(false, "At(\(i)) missing")
            continue
        }
        var kr = Reader(e.key)
        if case .string(let body)? = try? kr.next() {
            let got = String(decoding: unescape(body), as: UTF8.self)
            check(got == String(ch), "At(\(i)) key == \(ch) (got \(got))")
        } else {
            check(false, "At(\(i)) key not a string")
        }
    }
    check(im.at(8) == nil, "At(8) out of range")

    // Get binary-searches; agrees with linear MapView.Get on every key.
    let m = MapView(inner2)
    for ch in "abcdefgh" {
        let key = packString(String(ch))
        guard let want2 = try? m.get(key) else {
            check(false, "MapView.get(\(ch)) missing")
            continue
        }
        guard let got = im.get(key) else {
            check(false, "IndexedMap.get(\(ch)) missing")
            continue
        }
        check(Array(got) == Array(want2), "IndexedMap.get(\(ch)) == MapView.get")
    }

    // "e" was inserted 8th (value 8) but sits at sorted position 4.
    check(im.find(packString("e")) == 4, "find(e) == 4")
    if let v = im.get(packString("e")) {
        check(intOf(v) == 8, "get(e) value == 8 (got \(intOf(v)))")
    } else {
        check(false, "get(e) missing")
    }

    // Misses: before, between, and after the key range.
    check(im.get(packString("A")) == nil, "get(A) misses (below a)")
    check(im.get(packString("cc")) == nil, "get(cc) misses (between c and d)")
    check(im.get(packString("z")) == nil, "get(z) misses (above h)")
    check(im.find(packString("a")) == 0, "find(a) == 0")
    check(im.find(packString("h")) == 7, "find(h) == 7")

    // Iterator yields the same canonical order.
    var it = im.makeIterator()
    var n = 0
    while it.next() != nil { n += 1 }
    check(n == 8, "iterator yielded \(n), want 8")

    // ---- View stream ops ----
    var w2 = Writer()
    w2.appendString("users")
    w2.appendInt(12345)
    w2.appendString("alice")
    w2.appendBool(true)
    let v = View(w2.bytes)
    check((try? v.count()) == 4, "View count == 4")
    check(v.isString, "View head is string")
    if let at2v = try? v.at(2) {
        check(View(at2v).isString, "At(2) is a string")
    } else {
        check(false, "At(2) failed")
    }
    if let headv = try? v.head() {
        check((try? toJson(Array(headv))) == "\"users\"", "head is \"users\"")
    } else {
        check(false, "head failed")
    }
    if let tail = try? v.tail() {
        check((try? View(tail).count()) == 3, "tail count == 3")
    }
    if let take2 = try? v.take(2) {
        check((try? View(take2).count()) == 2, "take(2) count == 2")
    }
    if let rest = try? v.nthRest(2) {
        check((try? View(rest).count()) == 2, "nthRest(2) count == 2")
    }
}

// MARK: - Phase 3: golden / round-trip

func runGolden() {
    // Decimal goldens.
    let decCases: [(String, String)] = [
        ("12.345", "380321020d233300"),
        ("-12.345", "3801defdf2dcccff"),
        ("100", "380321030b00"),
        ("0.001", "38031ffe0b00"),
        ("12.300", "380321020d1f00"),  // canonicalizes to 12.3
        ("0", "3802"),
        ("1e-9", "38031ff80b00"),
    ]
    for (inp, hex) in decCases {
        var w = Writer()
        try! w.appendDecimalString(inp)
        check(toHex(w.bytes) == hex, "decimal \(inp) -> \(toHex(w.bytes)) want \(hex)")
    }

    // UUID golden + hyphenated JSON.
    var uw = Writer()
    uw.appendUuid([UInt8](repeating: 0, count: 16))
    check(
        toHex(uw.bytes) == "44" + String(repeating: "0", count: 32),
        "zero uuid bytes")
    check(
        (try? toJson(uw.bytes)) == "\"00000000-0000-0000-0000-000000000000\"",
        "zero uuid json")

    // Wide-int goldens (both directions).
    let intCases: [(String, String)] = [
        ("12345", "223039"),
        ("18446744073709551616", "29010000000000000000"),  // 2^64
        ("170141183460469231731687303715884105728", "31011080000000000000000000000000000000"),  // 2^127
        ("-170141183460469231731687303715884105728", "1080000000000000000000000000000000"),  // -2^127
    ]
    for (inp, hex) in intCases {
        if let got = try? fromJson(inp) {
            check(toHex(got) == hex, "int \(inp) -> \(toHex(got)) want \(hex)")
            check((try? toJson(got)) == inp, "int \(inp) round-trip")
        } else {
            check(false, "fromJson(\(inp)) failed")
        }
    }

    // Round-trip a big-int value (2^200 + 1) exactly.
    var bigMag = [UInt8](repeating: 0, count: 26)
    bigMag[0] = 1  // 2^200
    bigMag[25] = 1  // + 1
    var bw = Writer()
    bw.appendBigInt(negative: false, magnitude: bigMag)
    var br = Reader(bw.bytes)
    if case .bigInt(let bi)? = try? br.next() {
        check(bi.magnitude == bigMag, "big-int 2^200+1 round-trip magnitude")
    } else {
        check(false, "big-int decode failed")
    }

    // "app" sanity.
    var aw = Writer()
    aw.appendString("app")
    check(toHex(aw.bytes) == "4861707000", "\"app\" -> 4861707000")
}

// MARK: - main

print("struple Swift conformance + behavior tests")
print("Phase 1: conformance corpus")
runConformance()
print("Phase 2: navigation / IndexedMap")
runNavigation()
print("Phase 3: golden / round-trip")
runGolden()

print("")
print("passed \(passed), failed \(failed)")
if failed > 0 {
    print("RESULT: FAIL")
    exit(1)
}
print("RESULT: PASS")
exit(0)
