//! Generates conformance/vectors.json — the language-neutral cross-language
//! contract. Two entry shapes:
//!
//!   { "json":  "<canonical JSON text>", "bytes": "<hex>" }   -- JSON round-trip
//!   { "build": <op>,                    "bytes": "<hex>" }   -- typed value
//!
//! JSON entries:  fromJson(json) == bytes  and  toJson(bytes) == json.
//! Build entries: encode(build(op)) == bytes  and  transcode(bytes) == bytes.
//!   A build entry may also carry an optional one-way  "to_json": "<text>"  giving
//!   the expected toJson(bytes) rendering (used for decimals, whose text can't be a
//!   round-trip "json" field — fromJson of it would produce a float). Runners that
//!   support it check toJson(bytes) == to_json; older runners ignore the field.
//! where `build` interprets a tiny op language (covering the types JSON cannot
//! express: undefined, float32, timestamp, bytes, set, non-string map keys, and
//! compositions of them). An op is a one-key object; integers and timestamps are
//! decimal strings, bytes are hex.
//!
//! Run `zig build vectors`.

const std = @import("std");
const struple = @import("struple");

/// Canonical JSON inputs (floats are non-integer so their text keeps a decimal point).
const json_inputs = [_][]const u8{
    "null",                "true",                             "false",
    "0",                   "1",                                "-1",
    "255",                 "256",                              "-256",
    "12345",               "-42",                              "9223372036854775807",
    "-9223372036854775808", "100000000000000000000000000000",
    "-99999999999999999999999999999999",                      "1.5",
    "-3.14159",            "0.5",
    // Float text-format stressors (Item 3 — ECMAScript Number::toString edges).
    // Non-integer values so struple keeps them as float64 (integer JSON -> int).
    // (5e-324, the smallest subnormal, is intentionally excluded: native shortest
    // formatters disagree on its *digits* — ECMAScript "5e-324" vs Java "4.9e-324" —
    // and pinning it would force a full Ryū reimplementation per port. Notation
    // edges below have unambiguous shortest digits.)
    "1e-7",                "1e-6",                             "1.7976931348623157e308",
    "\"\"",
    "\"app\"",             "\"apple\"",                        "\"hello world\"",
    "\"tab\\tnewline\\n\"", "[]",                              "[1,2,3]",
    "[null,true,\"x\",[1,2]]", "{}",                           "{\"a\":1,\"b\":2}",
    "{\"active\":true,\"id\":12345,\"name\":\"alice\",\"score\":87.5,\"tags\":[\"x\",\"y\"]}",
    // wide integers: the i128 fixed slots and the i128/big-int boundary (both signs)
    "18446744073709551616", // 2^64 (9-byte fixed positive)
    "170141183460469231731687303715884105727", // 2^127 - 1 (i128 max, widest fixed)
    "170141183460469231731687303715884105728", // 2^127 (first big-int positive)
    "-170141183460469231731687303715884105728", // -2^127 (i128 min, widest fixed)
    "-170141183460469231731687303715884105729", // -2^127 - 1 (first big-int negative)
    "[1,18446744073709551616,-18446744073709551616]", // wide ints inside an array
    // Integer band boundaries (Item 9 §3.5) — fill the empty fixed-slot bands.
    "65535",               "65536",                            "65537",
    "-257",                "16777215",                         "16777216",
    "4294967296",          "1099511627776",                    "281474976710656",
    "72057594037927936",   "9223372036854775808",              "18446744073709551615",
    "1606938044258990275541962092341162602522202993782792835301376", // 2^200 (big-int)
    // Non-ASCII (2/3/4-byte UTF-8) + an embedded NUL (Item 9 §3.4).
    "\"café\"",       "\"日本\"",                 "\"😀\"",
    "\"a\\u0000b\"", // embedded NUL: exercises the 0x00 escape through the string path
    // Deeper nesting + map-in-map (Item 9 §3.6).
    "[[[1,2],[3]],[]]",    "{\"a\":{\"b\":{\"c\":1}}}",
};

/// Op descriptors for the non-JSON types. Each is valid JSON, embedded verbatim.
const build_ops = [_][]const u8{
    "{\"undef\":null}",
    "{\"float32\":1.5}",
    // Integer-valued floats must be explicit float64 ops (integer JSON encodes as
    // an int), plus a non-exact f32 — all pin the ECMAScript float text (Item 3).
    "{\"float64\":1e16}",
    "{\"float64\":1e21}",
    "{\"float64\":1e20}",
    "{\"float32\":0.1}",
    "{\"timestamp\":\"0\"}",
    "{\"timestamp\":\"1000000\"}",
    "{\"timestamp\":\"-1000000\"}",
    "{\"bytes\":\"\"}",
    "{\"bytes\":\"00ff01\"}",
    "{\"set\":[{\"int\":\"3\"},{\"int\":\"1\"},{\"int\":\"2\"}]}",
    "{\"set\":[{\"string\":\"b\"},{\"string\":\"a\"},{\"string\":\"a\"}]}",
    "{\"map\":[[{\"int\":\"1\"},{\"string\":\"one\"}],[{\"int\":\"2\"},{\"string\":\"two\"}]]}",
    "{\"map\":[[{\"string\":\"data\"},{\"bytes\":\"00ff\"}]]}",
    "{\"array\":[{\"timestamp\":\"1000000\"},{\"bytes\":\"01\"},{\"undef\":null}]}",
    "{\"uuid\":\"550e8400e29b41d4a716446655440000\"}",
    "{\"uuid\":\"ffffffffffffffffffffffffffffffff\"}",
    "{\"array\":[{\"uuid\":\"00112233445566778899aabbccddeeff\"},{\"string\":\"x\"}]}",
    // decimals: canonicalization (trailing/leading zeros), both signs, scale extremes
    "{\"decimal\":\"0\"}",
    "{\"decimal\":\"12.345\"}",
    "{\"decimal\":\"-12.345\"}",
    "{\"decimal\":\"100\"}",
    "{\"decimal\":\"0.001\"}",
    "{\"decimal\":\"12.300\"}", // canonicalizes to 12.3
    "{\"decimal\":\"-0.5\"}",
    "{\"decimal\":\"123456789012345678901234567890.123456789\"}", // wide coefficient
    "{\"decimal\":\"1e-9\"}",
    // large exponents (Item 2): plain up to the pad threshold, scientific beyond.
    "{\"decimal\":\"1e40\"}", // plain: pad == threshold
    "{\"decimal\":\"1e41\"}", // scientific: pad just over the threshold
    "{\"decimal\":\"1e300\"}",
    "{\"decimal\":\"-1e300\"}",
    "{\"decimal\":\"1e-300\"}",
    "{\"decimal\":\"1.5e300\"}",
    "{\"decimal\":\"-9.99e-300\"}",
    "{\"array\":[{\"decimal\":\"1.5\"},{\"string\":\"x\"}]}",
    // Item 9 §3 corpus growth: canonicalization + container/edge coverage.
    // Out-of-order map keys (the top gap) — the encoder must sort to canonical form.
    "{\"map\":[[{\"int\":\"3\"},{\"string\":\"c\"}],[{\"int\":\"1\"},{\"string\":\"a\"}],[{\"int\":\"2\"},{\"string\":\"b\"}]]}",
    // Map with container keys out of order (canonical sort by encoded key bytes).
    "{\"map\":[[{\"array\":[{\"int\":\"2\"}]},{\"string\":\"y\"}],[{\"array\":[{\"int\":\"1\"}]},{\"string\":\"x\"}]]}",
    // Empty set; set of containers (sorted + deduped by encoded bytes).
    "{\"set\":[]}",
    "{\"set\":[{\"array\":[{\"int\":\"2\"}]},{\"array\":[{\"int\":\"1\"}]},{\"array\":[{\"int\":\"2\"}]}]}",
    // Timestamp i64 extremes.
    "{\"timestamp\":\"9223372036854775807\"}",
    "{\"timestamp\":\"-9223372036854775808\"}",
    // Decimal edges: multi-byte exponent, single digit, trailing-zero canonicalization.
    "{\"decimal\":\"2e200\"}",
    "{\"decimal\":\"7\"}",
    "{\"decimal\":\"1.230\"}", // -> 1.23
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();

    const total = json_inputs.len + build_ops.len;
    var idx: usize = 0;

    try w.writeAll("[\n");

    for (json_inputs) |input| {
        const encoded = try struple.fromJson(a, input);
        const canonical = try struple.toJson(a, encoded);
        try w.writeAll("  { \"json\": ");
        try writeJsonStringLiteral(w, canonical);
        try emitBytes(w, encoded);
        try comma(w, &idx, total);
    }

    for (build_ops) |op_text| {
        const op = try std.json.parseFromSliceLeaky(std.json.Value, a, op_text, .{});
        var p = struple.Packer.init(a);
        try buildInto(a, &p, op);
        try w.writeAll("  { \"build\": ");
        try w.writeAll(op_text); // op is valid JSON, embed verbatim
        try w.writeAll(", \"bytes\": \"");
        for (p.bytes()) |b| try w.print("{x:0>2}", .{b});
        try w.writeAll("\"");
        // Decimals are build-only, so the {json,bytes} vectors don't cover their
        // toJson text. Pin it here so the plain/scientific rendering (Item 2) is a
        // cross-language contract. A distinct one-way field name ("to_json", not
        // "json") avoids the round-trip semantics: fromJson of this text would make
        // a float, not the decimal. Runners check toJson(bytes)==to_json when present.
        if (std.mem.startsWith(u8, op_text, "{\"decimal\"") or
            std.mem.startsWith(u8, op_text, "{\"float64\"") or
            std.mem.startsWith(u8, op_text, "{\"float32\""))
        {
            const j = try struple.toJson(a, p.bytes());
            try w.writeAll(", \"to_json\": ");
            try writeJsonStringLiteral(w, j);
        }
        try w.writeAll(" }");
        try comma(w, &idx, total);
    }

    try w.writeAll("]\n");

    try std.fs.cwd().makePath("conformance");
    try std.fs.cwd().writeFile(.{ .sub_path = "conformance/vectors.json", .data = out.items });
    std.debug.print("wrote conformance/vectors.json ({d} vectors: {d} json, {d} build)\n", .{ total, json_inputs.len, build_ops.len });

    try emitSemantic(a);
}

// ---------------------------------------------------------------------------
// Semantic-order corpus: `{a, b, order}` pairs (order = -1 | 0 | 1).
// Each language compares its own semanticOrder(a, b) against `order`.
// ---------------------------------------------------------------------------

fn sp(a: std.mem.Allocator, value: anytype) []const u8 {
    var p = struple.Packer.init(a);
    p.append(value) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sf64(a: std.mem.Allocator, v: f64) []const u8 {
    var p = struple.Packer.init(a);
    p.appendF64(v) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sf32(a: std.mem.Allocator, v: f32) []const u8 {
    var p = struple.Packer.init(a);
    p.appendF32(v) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sbig(a: std.mem.Allocator, neg: bool, mag: []const u8) []const u8 {
    var p = struple.Packer.init(a);
    p.appendBigInt(neg, mag) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sts(a: std.mem.Allocator, micros: i64) []const u8 {
    var p = struple.Packer.init(a);
    p.appendTimestamp(micros) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn suuid(a: std.mem.Allocator, u: [16]u8) []const u8 {
    var p = struple.Packer.init(a);
    p.appendUuid(u) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sundef(a: std.mem.Allocator) []const u8 {
    var p = struple.Packer.init(a);
    p.appendUndefined() catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sdec(a: std.mem.Allocator, s: []const u8) []const u8 {
    var p = struple.Packer.init(a);
    p.appendDecimalString(s) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sjson(a: std.mem.Allocator, text: []const u8) []const u8 {
    return struple.fromJson(a, text) catch unreachable;
}
fn sarr(a: std.mem.Allocator, elems: []const []const u8) []const u8 {
    var child = std.ArrayList(u8).init(a);
    for (elems) |e| child.appendSlice(e) catch unreachable;
    var p = struple.Packer.init(a);
    p.appendArray(child.items) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn sset(a: std.mem.Allocator, elems: []const []const u8) []const u8 {
    var p = struple.Packer.init(a);
    p.appendSet(elems) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}
fn smap(a: std.mem.Allocator, entries: []const [2][]const u8) []const u8 {
    var p = struple.Packer.init(a);
    p.appendMap(entries) catch unreachable;
    return p.toOwnedSlice() catch unreachable;
}

fn emitSemantic(a: std.mem.Allocator) !void {
    const Pair = struct { x: []const u8, y: []const u8 };
    var pairs = std.ArrayList(Pair).init(a);

    // 2^53 / 2^100 / 2^200 as exact floats, plus a big-int magnitude for 2^200.
    const f53 = std.math.ldexp(@as(f64, 1.0), 53);
    const f100 = std.math.ldexp(@as(f64, 1.0), 100);
    const f200 = std.math.ldexp(@as(f64, 1.0), 200);
    var m200 = [_]u8{0} ** 26;
    m200[0] = 1; // 2^200
    var m200p1 = [_]u8{0} ** 26;
    m200p1[0] = 1;
    m200p1[25] = 1; // 2^200 + 1

    const P = struct {
        fn add(list: *std.ArrayList(Pair), x: []const u8, y: []const u8) void {
            list.append(.{ .x = x, .y = y }) catch unreachable;
        }
    };

    // int <-> float by value
    P.add(&pairs, sp(a, @as(i64, 5)), sf64(a, 5.0)); // eq
    P.add(&pairs, sp(a, @as(i64, 3)), sf64(a, 3.5)); // lt
    P.add(&pairs, sp(a, @as(i64, 4)), sf64(a, 3.5)); // gt
    P.add(&pairs, sf64(a, -2.5), sp(a, @as(i64, -2))); // lt
    P.add(&pairs, sf32(a, 1.5), sf64(a, 1.5)); // eq
    P.add(&pairs, sp(a, @as(i64, 0)), sf64(a, -0.0)); // eq
    // Raw -0.0 wire forms (the encoder normalizes -0.0 -> +0.0, so these hand-built
    // bytes are the only way a distinct -0.0 reaches the comparator): they must still
    // compare NUMERICALLY equal to +0.0, not by a signed-zero total order.
    P.add(&pairs, &[_]u8{ 0x35, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, sf64(a, 0.0)); // f64 -0.0 == f64 0.0
    P.add(&pairs, &[_]u8{ 0x34, 0x7f, 0xff, 0xff, 0xff }, sf64(a, 0.0)); // f32 -0.0 == f64 0.0
    // the 2^53 boundary
    P.add(&pairs, sp(a, @as(i64, 1) << 53), sf64(a, f53)); // eq
    P.add(&pairs, sp(a, (@as(i64, 1) << 53) + 1), sf64(a, f53)); // gt
    // i128 vs large float
    P.add(&pairs, sp(a, @as(i128, 1) << 100), sf64(a, f100)); // eq
    P.add(&pairs, sp(a, (@as(i128, 1) << 100) + 1), sf64(a, f100)); // gt
    P.add(&pairs, sp(a, (@as(i128, 1) << 100) - 1), sf64(a, f100)); // lt
    // big-int (> i128) vs float
    P.add(&pairs, sbig(a, false, &m200), sf64(a, f200)); // eq
    P.add(&pairs, sbig(a, false, &m200p1), sf64(a, f200)); // gt
    P.add(&pairs, sbig(a, true, &m200p1), sf64(a, -f200)); // lt
    // infinities / NaN
    P.add(&pairs, sp(a, @as(i128, 1) << 120), sf64(a, std.math.inf(f64))); // lt
    P.add(&pairs, sf64(a, std.math.nan(f64)), sf64(a, std.math.inf(f64))); // gt
    P.add(&pairs, sf64(a, std.math.nan(f64)), sf32(a, std.math.nan(f32))); // eq
    P.add(&pairs, sf64(a, -std.math.inf(f64)), sp(a, @as(i64, -999999))); // lt
    // plain integer ordering (incl. big-int vs fixed)
    P.add(&pairs, sp(a, @as(i64, -5)), sp(a, @as(i64, 5))); // lt
    P.add(&pairs, sbig(a, false, &m200), sp(a, @as(i128, 1) << 120)); // gt (big > fixed)
    // decimals join the number class and compare by exact value
    P.add(&pairs, sdec(a, "5"), sp(a, @as(i64, 5))); // eq (decimal == int)
    P.add(&pairs, sdec(a, "5.0"), sf64(a, 5.0)); // eq (decimal == float)
    P.add(&pairs, sdec(a, "1.50"), sdec(a, "1.5")); // eq (canonical decimal-decimal)
    P.add(&pairs, sdec(a, "1.5"), sdec(a, "1.6")); // lt
    P.add(&pairs, sdec(a, "0.1"), sf64(a, 0.1)); // lt (0.1 is not exactly representable in f64)
    P.add(&pairs, sdec(a, "2.5"), sf64(a, 2.5)); // eq (2.5 is exact in binary)
    P.add(&pairs, sdec(a, "123.5"), sp(a, @as(i64, 123))); // gt
    P.add(&pairs, sdec(a, "-7.25"), sf64(a, -7.25)); // eq
    P.add(&pairs, sdec(a, "1e30"), sdec(a, "1000000000000000000000000000000")); // eq (decimal-decimal, exp form)
    P.add(&pairs, sdec(a, "1e40"), sjson(a, "10000000000000000000000000000000000000000")); // eq (decimal == big-int 10^40)
    P.add(&pairs, sdec(a, "1e308"), sf64(a, 1.0e308)); // exact decimal 10^308 vs the nearest f64
    // cross-type classes
    P.add(&pairs, sp(a, null), sp(a, false)); // nil < bool
    P.add(&pairs, sundef(a), sp(a, true)); // undefined < bool
    P.add(&pairs, sp(a, true), sp(a, @as(i64, 0))); // bool < number
    P.add(&pairs, sf64(a, 1.0e300), sts(a, 0)); // number < timestamp
    P.add(&pairs, sts(a, 999), suuid(a, [_]u8{0} ** 16)); // timestamp < uuid
    P.add(&pairs, suuid(a, [_]u8{0xff} ** 16), sp(a, "")); // uuid < string
    P.add(&pairs, sp(a, "z"), blk: {
        var p = struple.Packer.init(a);
        p.appendBytes(&.{0}) catch unreachable;
        break :blk p.toOwnedSlice() catch unreachable;
    }); // string < bytes
    // containers recurse by value
    P.add(&pairs, sarr(a, &.{sp(a, @as(i64, 5))}), sarr(a, &.{sf64(a, 5.0)})); // eq
    // map / set semantic recursion (Item 9 §3.7 — semantic corpus had no 0x52/0x54)
    P.add(&pairs, smap(a, &.{.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 5)) }}), smap(a, &.{.{ sp(a, @as(i64, 1)), sf64(a, 5.0) }})); // eq (map value int 5 == float 5.0)
    P.add(&pairs, smap(a, &.{.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 5)) }}), smap(a, &.{.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 6)) }})); // lt (map value differs)
    P.add(&pairs, sset(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 2)) }), sset(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 2)) })); // eq (identical sets)
    P.add(&pairs, sset(a, &.{sp(a, @as(i64, 1))}), sset(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 2)) })); // lt (prefix: fewer elements)
    P.add(&pairs, sset(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 2)) }), sset(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 3)) })); // lt (2 < 3)
    P.add(&pairs, sarr(a, &.{ sp(a, @as(i64, 1)), sp(a, @as(i64, 2)) }), sarr(a, &.{ sp(a, @as(i64, 1)), sf64(a, 2.5) })); // lt
    // prefix: shorter tuple sorts first
    P.add(&pairs, sp(a, @as(i64, 1)), blk: {
        var p = struple.Packer.init(a);
        p.appendInt(1) catch unreachable;
        p.appendInt(0) catch unreachable;
        break :blk p.toOwnedSlice() catch unreachable;
    }); // lt

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("[\n");
    for (pairs.items, 0..) |pr, i| {
        const ord = try struple.semanticOrder(a, pr.x, pr.y);
        const n: i8 = switch (ord) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        try w.writeAll("  { \"a\": \"");
        for (pr.x) |byte| try w.print("{x:0>2}", .{byte});
        try w.writeAll("\", \"b\": \"");
        for (pr.y) |byte| try w.print("{x:0>2}", .{byte});
        try w.print("\", \"order\": {d} }}", .{n});
        if (i + 1 < pairs.items.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try w.writeAll("]\n");

    try std.fs.cwd().writeFile(.{ .sub_path = "conformance/semantic_vectors.json", .data = out.items });
    std.debug.print("wrote conformance/semantic_vectors.json ({d} pairs)\n", .{pairs.items.len});
}

fn emitBytes(w: anytype, encoded: []const u8) !void {
    try w.writeAll(", \"bytes\": \"");
    for (encoded) |b| try w.print("{x:0>2}", .{b});
    try w.writeAll("\" }");
}

fn comma(w: anytype, idx: *usize, total: usize) !void {
    idx.* += 1;
    if (idx.* < total) try w.writeByte(',');
    try w.writeByte('\n');
}

/// Interpret a build op into the packer (the single source of op -> bytes logic;
/// the TypeScript and Python conformance tests mirror it).
fn buildInto(a: std.mem.Allocator, p: *struple.Packer, op: std.json.Value) !void {
    var it = op.object.iterator();
    const e = it.next().?;
    const key = e.key_ptr.*;
    const val = e.value_ptr.*;

    if (std.mem.eql(u8, key, "nil")) {
        try p.appendNil();
    } else if (std.mem.eql(u8, key, "undef")) {
        try p.appendUndefined();
    } else if (std.mem.eql(u8, key, "bool")) {
        try p.appendBool(val.bool);
    } else if (std.mem.eql(u8, key, "int")) {
        try p.appendInt(try std.fmt.parseInt(i64, val.string, 10));
    } else if (std.mem.eql(u8, key, "float64")) {
        try p.appendF64(asF64(val));
    } else if (std.mem.eql(u8, key, "float32")) {
        try p.appendF32(@floatCast(asF64(val)));
    } else if (std.mem.eql(u8, key, "timestamp")) {
        try p.appendTimestamp(try std.fmt.parseInt(i64, val.string, 10));
    } else if (std.mem.eql(u8, key, "uuid")) {
        const raw = try hexDecode(a, val.string);
        try p.appendUuid(raw[0..16].*);
    } else if (std.mem.eql(u8, key, "decimal")) {
        try p.appendDecimalString(val.string);
    } else if (std.mem.eql(u8, key, "string")) {
        try p.appendString(val.string);
    } else if (std.mem.eql(u8, key, "bytes")) {
        try p.appendBytes(try hexDecode(a, val.string));
    } else if (std.mem.eql(u8, key, "array")) {
        var child = struple.Packer.init(a);
        for (val.array.items) |item| try buildInto(a, &child, item);
        try p.appendArray(child.bytes());
    } else if (std.mem.eql(u8, key, "set")) {
        var elems = std.ArrayList([]const u8).init(a);
        for (val.array.items) |item| {
            var ep = struple.Packer.init(a);
            try buildInto(a, &ep, item);
            try elems.append(ep.bytes());
        }
        try p.appendSet(elems.items);
    } else if (std.mem.eql(u8, key, "map")) {
        var entries = std.ArrayList([2][]const u8).init(a);
        for (val.array.items) |pair| {
            var kp = struple.Packer.init(a);
            try buildInto(a, &kp, pair.array.items[0]);
            var vp = struple.Packer.init(a);
            try buildInto(a, &vp, pair.array.items[1]);
            try entries.append(.{ kp.bytes(), vp.bytes() });
        }
        try p.appendMap(entries.items);
    } else {
        return error.UnknownOp;
    }
}

fn asF64(val: std.json.Value) f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn hexDecode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len / 2);
    for (out, 0..) |*b, i| b.* = try std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16);
    return out;
}

fn writeJsonStringLiteral(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
