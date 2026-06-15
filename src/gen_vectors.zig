//! Generates conformance/vectors.json — the language-neutral cross-language
//! contract. Two entry shapes:
//!
//!   { "json":  "<canonical JSON text>", "bytes": "<hex>" }   -- JSON round-trip
//!   { "build": <op>,                    "bytes": "<hex>" }   -- typed value
//!
//! JSON entries:  fromJson(json) == bytes  and  toJson(bytes) == json.
//! Build entries: encode(build(op)) == bytes  and  transcode(bytes) == bytes,
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
    "-3.14159",            "0.5",                              "\"\"",
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
};

/// Op descriptors for the non-JSON types. Each is valid JSON, embedded verbatim.
const build_ops = [_][]const u8{
    "{\"undef\":null}",
    "{\"float32\":1.5}",
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
        try emitBytes(w, p.bytes());
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
fn sarr(a: std.mem.Allocator, elems: []const []const u8) []const u8 {
    var child = std.ArrayList(u8).init(a);
    for (elems) |e| child.appendSlice(e) catch unreachable;
    var p = struple.Packer.init(a);
    p.appendArray(child.items) catch unreachable;
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
