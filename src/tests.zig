const std = @import("std");
const testing = std.testing;
const struple = @import("struple.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pack a single value alone and return owned bytes.
fn packOne(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var p = struple.Packer.init(allocator);
    defer p.deinit();
    try p.append(value);
    return p.toOwnedSlice();
}

fn expectBytes(value: anytype, expected: []const u8) !void {
    const got = try packOne(testing.allocator, value);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, expected, got);
}

fn concat(arena: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const out = try arena.alloc(u8, total);
    var w: usize = 0;
    for (parts) |p| {
        @memcpy(out[w .. w + p.len], p);
        w += p.len;
    }
    return out;
}

fn packArray(arena: std.mem.Allocator, elem_encs: []const []const u8) ![]u8 {
    var p = struple.Packer.init(arena);
    try p.appendArray(try concat(arena, elem_encs));
    return p.toOwnedSlice();
}

fn packSet(arena: std.mem.Allocator, elem_encs: []const []const u8) ![]u8 {
    var p = struple.Packer.init(arena);
    try p.appendSet(elem_encs);
    return p.toOwnedSlice();
}

fn packMap(arena: std.mem.Allocator, entries: []const [2][]const u8) ![]u8 {
    var p = struple.Packer.init(arena);
    try p.appendMap(entries);
    return p.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Golden vectors — pin the exact wire format
// ---------------------------------------------------------------------------

test "golden: simple scalars" {
    try expectBytes(null, &.{0x01}); // nil
    try expectBytes(false, &.{0x05});
    try expectBytes(true, &.{0x06});
    try expectBytes(@as(u64, 0), &.{0x20});

    var p = struple.Packer.init(testing.allocator);
    defer p.deinit();
    try p.appendUndefined();
    try testing.expectEqualSlices(u8, &.{0x02}, p.bytes());
}

test "golden: positive integers" {
    try expectBytes(@as(u64, 1), &.{ 0x21, 0x01 });
    try expectBytes(@as(u64, 255), &.{ 0x21, 0xFF });
    try expectBytes(@as(u64, 256), &.{ 0x22, 0x01, 0x00 });
    try expectBytes(@as(u64, 1000), &.{ 0x22, 0x03, 0xE8 });
    try expectBytes(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), &.{ 0x28, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
}

test "golden: negative integers (excess form)" {
    try expectBytes(@as(i64, -1), &.{ 0x1F, 0xFF });
    try expectBytes(@as(i64, -100), &.{ 0x1F, 0x9C });
    try expectBytes(@as(i64, -256), &.{ 0x1F, 0x00 });
    try expectBytes(@as(i64, -257), &.{ 0x1E, 0xFE, 0xFF });
    try expectBytes(@as(i64, std.math.minInt(i64)), &.{ 0x18, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "golden: arbitrary-precision integers" {
    // 2^64 = first value needing the big path: magnitude 01 followed by eight 00 (9 bytes)
    try expectBytes(@as(i128, 1) << 64, &.{ 0x31, 0x01, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // -(2^64): big negative, every field complemented
    try expectBytes(-(@as(i128, 1) << 64), &.{ 0x0F, 0xFE, 0xF6, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
}

test "golden: floats" {
    try expectBytes(@as(f32, 1.0), &.{ 0x34, 0xBF, 0x80, 0x00, 0x00 });
    try expectBytes(@as(f32, -1.0), &.{ 0x34, 0x40, 0x7F, 0xFF, 0xFF });
    try expectBytes(@as(f64, 1.0), &.{ 0x35, 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "golden: timestamp" {
    var p = struple.Packer.init(testing.allocator);
    defer p.deinit();
    try p.appendTimestamp(0);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, p.bytes());
    p.reset();
    try p.appendTimestamp(-1);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, p.bytes());
}

test "golden: strings and bytes" {
    try expectBytes("", &.{ 0x48, 0x00 });
    try expectBytes("app", &.{ 0x48, 0x61, 0x70, 0x70, 0x00 });
    try expectBytes("apple", &.{ 0x48, 0x61, 0x70, 0x70, 0x6C, 0x65, 0x00 });

    var p = struple.Packer.init(testing.allocator);
    defer p.deinit();
    try p.appendBytes(&.{ 0x00, 0x01 });
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x00, 0xFF, 0x01, 0x00 }, p.bytes());
}

test "golden: containers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // array (1, 2)
    const arr = try packArray(a, &.{ try packOne(a, @as(i64, 1)), try packOne(a, @as(i64, 2)) });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x21, 0x01, 0x21, 0x02, 0x00 }, arr);

    // map {"a":1, "b":2} given out of order -> canonical
    const map = try packMap(a, &.{
        .{ try packOne(a, "b"), try packOne(a, @as(i64, 2)) },
        .{ try packOne(a, "a"), try packOne(a, @as(i64, 1)) },
    });
    try testing.expectEqualSlices(u8, &.{ 0x52, 0x48, 0x61, 0x00, 0xFF, 0x21, 0x01, 0x48, 0x62, 0x00, 0xFF, 0x21, 0x02, 0x00 }, map);

    // set {3,1,2} -> sorted
    const set = try packSet(a, &.{
        try packOne(a, @as(i64, 3)), try packOne(a, @as(i64, 1)), try packOne(a, @as(i64, 2)),
    });
    try testing.expectEqualSlices(u8, &.{ 0x54, 0x21, 0x01, 0x21, 0x02, 0x21, 0x03, 0x00 }, set);
}

// ---------------------------------------------------------------------------
// Round-trip
// ---------------------------------------------------------------------------

test "round-trip: integers" {
    const a = testing.allocator;
    const cases = [_]i64{
        std.math.minInt(i64), -1_000_000_000_000, -65537, -65536, -257, -256,
        -255,                 -100,                -2,     -1,     0,    1,
        2,                    100,                 255,    256,    257,  65535,
        65536,                1_000_000_000_000,   std.math.maxInt(i64),
    };
    for (cases) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(@as(i128, v), (try r.next()).?.int);
        try testing.expect(try r.next() == null);
    }
}

test "round-trip: arbitrary-precision integers" {
    const a = testing.allocator;

    // values that fit i128 but use the big path (9–16 byte magnitudes)
    const big_cases = [_]i128{
        @as(i128, 1) << 64, -(@as(i128, 1) << 64),  @as(i128, 1) << 100,
        -(@as(i128, 1) << 100), std.math.maxInt(i128), std.math.minInt(i128),
    };
    for (big_cases) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        const elem = (try r.next()).?;
        try testing.expectEqual(v, elem.big_int.toI128().?);
    }

    // a magnitude far beyond i128 round-trips via the byte API
    {
        var mag: [40]u8 = undefined;
        for (&mag, 0..) |*b, i| b.* = @intCast((i * 7 + 1) & 0xFF);
        mag[0] |= 0x80; // ensure no leading-zero trimming surprises

        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendBigInt(true, &mag);

        var r = struple.reader(p.bytes());
        const bi = (try r.next()).?.big_int;
        try testing.expect(bi.negative);
        try testing.expect(bi.toI128() == null);
        const got = try bi.magnitudeAlloc(a);
        defer a.free(got);
        try testing.expectEqualSlices(u8, &mag, got);
    }
}

test "round-trip: floats incl. specials" {
    const a = testing.allocator;
    const f64s = [_]f64{ -std.math.inf(f64), -1.5, -1.0, 0.0, 1.0, 3.14159, std.math.inf(f64) };
    for (f64s) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(v, (try r.next()).?.float64);
    }
    const nan_buf = try packOne(a, std.math.nan(f64));
    defer a.free(nan_buf);
    var rn = struple.reader(nan_buf);
    try testing.expect(std.math.isNan((try rn.next()).?.float64));

    const f32s = [_]f32{ -3.5, -1.0, 0.0, 1.0, 2.5 };
    for (f32s) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(v, (try r.next()).?.float32);
    }
}

test "round-trip: timestamp" {
    const a = testing.allocator;
    const cases = [_]i64{ std.math.minInt(i64), -1_000_000, -1, 0, 1, 1_700_000_000_000_000, std.math.maxInt(i64) };
    for (cases) |v| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendTimestamp(v);
        var r = struple.reader(p.bytes());
        try testing.expectEqual(v, (try r.next()).?.timestamp);
    }
}

test "round-trip: undefined and nil" {
    const a = testing.allocator;
    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.appendNil();
    try p.appendUndefined();
    var r = struple.reader(p.bytes());
    try testing.expectEqual(struple.Kind.nil, (try r.next()).?);
    try testing.expectEqual(struple.Kind.undef, (try r.next()).?);
}

test "round-trip: strings and bytes with NULs" {
    const a = testing.allocator;
    const samples = [_][]const u8{ "", "a", "hello world", &.{ 0x00, 0x00 }, &.{ 0x00, 0xFF, 0x00 } };
    for (samples) |s| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendString(s);
        var r = struple.reader(p.bytes());
        const got = try struple.unescapeAlloc(a, (try r.next()).?.string);
        defer a.free(got);
        try testing.expectEqualSlices(u8, s, got);
    }
}

test "round-trip: array, map, set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // array of mixed elements
    const arr = try packArray(a, &.{
        try packOne(a, "city"), try packOne(a, @as(i64, 256)), try packOne(a, true),
    });
    {
        var r = struple.reader(arr);
        const content = try struple.unescapeAlloc(a, (try r.next()).?.array);
        var cr = struple.reader(content);
        try testing.expectEqualStrings("city", (try cr.next()).?.string);
        try testing.expectEqual(@as(i128, 256), (try cr.next()).?.int);
        try testing.expectEqual(true, (try cr.next()).?.boolean);
        try testing.expect(try cr.next() == null);
    }

    // map: out-of-order input encodes identically to sorted input
    const m1 = try packMap(a, &.{
        .{ try packOne(a, "b"), try packOne(a, @as(i64, 2)) },
        .{ try packOne(a, "a"), try packOne(a, @as(i64, 1)) },
    });
    const m2 = try packMap(a, &.{
        .{ try packOne(a, "a"), try packOne(a, @as(i64, 1)) },
        .{ try packOne(a, "b"), try packOne(a, @as(i64, 2)) },
    });
    try testing.expectEqualSlices(u8, m1, m2);
    {
        var r = struple.reader(m1);
        const content = try struple.unescapeAlloc(a, (try r.next()).?.map);
        var cr = struple.reader(content);
        try testing.expectEqualStrings("a", (try cr.next()).?.string);
        try testing.expectEqual(@as(i128, 1), (try cr.next()).?.int);
        try testing.expectEqualStrings("b", (try cr.next()).?.string);
        try testing.expectEqual(@as(i128, 2), (try cr.next()).?.int);
        try testing.expect(try cr.next() == null);
    }

    // set: duplicates removed, sorted
    const s = try packSet(a, &.{
        try packOne(a, @as(i64, 2)), try packOne(a, @as(i64, 1)),
        try packOne(a, @as(i64, 2)), try packOne(a, @as(i64, 3)),
        try packOne(a, @as(i64, 1)),
    });
    {
        var r = struple.reader(s);
        const content = try struple.unescapeAlloc(a, (try r.next()).?.set);
        var cr = struple.reader(content);
        try testing.expectEqual(@as(i128, 1), (try cr.next()).?.int);
        try testing.expectEqual(@as(i128, 2), (try cr.next()).?.int);
        try testing.expectEqual(@as(i128, 3), (try cr.next()).?.int);
        try testing.expect(try cr.next() == null);
    }
}

// ---------------------------------------------------------------------------
// Ordering — the whole point
// ---------------------------------------------------------------------------

test "ordering: headline cases" {
    const a = testing.allocator;
    {
        const app = try packOne(a, "app");
        defer a.free(app);
        const apple = try packOne(a, "apple");
        defer a.free(apple);
        try testing.expectEqual(std.math.Order.lt, struple.order(app, apple));
    }
    {
        const n256 = try packOne(a, @as(i64, -256));
        defer a.free(n256);
        const n100 = try packOne(a, @as(i64, -100));
        defer a.free(n100);
        const n1 = try packOne(a, @as(i64, -1));
        defer a.free(n1);
        try testing.expectEqual(std.math.Order.lt, struple.order(n256, n100));
        try testing.expectEqual(std.math.Order.lt, struple.order(n100, n1));
    }
}

test "ordering: a long ascending chain holds under memcmp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var encs = std.ArrayList([]const u8).init(a);

    // scalars in strict ascending order, crossing every band boundary
    try encs.append(try packOne(a, null)); // nil
    {
        var p = struple.Packer.init(a);
        try p.appendUndefined();
        try encs.append(try p.toOwnedSlice());
    }
    try encs.append(try packOne(a, false));
    try encs.append(try packOne(a, true));

    // big negatives (sort below all fixed negatives), then fixed ints, then big positives
    try encs.append(try packOne(a, -(@as(i128, 1) << 100)));
    try encs.append(try packOne(a, -(@as(i128, 1) << 65)));
    try encs.append(try packOne(a, -(@as(i128, 1) << 64)));
    const ints = [_]i64{
        std.math.minInt(i64), -65537, -257, -256, -1, 0, 1, 256, 65536, std.math.maxInt(i64),
    };
    for (ints) |v| try encs.append(try packOne(a, @as(i128, v)));
    try encs.append(try packOne(a, @as(i128, 1) << 64));
    try encs.append(try packOne(a, @as(i128, 1) << 65));
    try encs.append(try packOne(a, @as(i128, 1) << 100));

    // floats sort after all ints
    const floats = [_]f64{ -std.math.inf(f64), -1.0, 0.0, 1.0, std.math.inf(f64), std.math.nan(f64) };
    for (floats) |v| try encs.append(try packOne(a, v));

    // timestamps sort after floats
    inline for (.{ @as(i64, -1), @as(i64, 0), @as(i64, 1) }) |ts| {
        var p = struple.Packer.init(a);
        try p.appendTimestamp(ts);
        try encs.append(try p.toOwnedSlice());
    }

    // strings, then bytes
    const strings = [_][]const u8{ "", "app", "apple", "b" };
    for (strings) |v| try encs.append(try packOne(a, v));
    {
        const byte_samples = [_][]const u8{ &.{}, &.{0x00}, &.{0x01}, &.{0xFF} };
        for (byte_samples) |bs| {
            var p = struple.Packer.init(a);
            try p.appendBytes(bs);
            try encs.append(try p.toOwnedSlice());
        }
    }

    for (1..encs.items.len) |i| {
        if (struple.order(encs.items[i - 1], encs.items[i]) != .lt) {
            std.debug.print("ordering violation at {d}: {x} !< {x}\n", .{ i, encs.items[i - 1], encs.items[i] });
            return error.OrderingViolation;
        }
    }

    // shuffle + sort by bytes -> original order
    const shuffled = try a.dupe([]const u8, encs.items);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    prng.random().shuffle([]const u8, shuffled);
    std.mem.sort([]const u8, shuffled, {}, struple.lessThan);
    for (encs.items, shuffled) |want, got| try testing.expectEqualSlices(u8, want, got);
}

test "ordering: containers (array < map < set, and within each)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const e1 = try packOne(a, @as(i64, 1));
    const e2 = try packOne(a, @as(i64, 2));
    const ka = try packOne(a, "a");
    const kb = try packOne(a, "b");

    var chain = std.ArrayList([]const u8).init(a);
    // arrays: () < (1) < (1,2) < (2)
    try chain.append(try packArray(a, &.{}));
    try chain.append(try packArray(a, &.{e1}));
    try chain.append(try packArray(a, &.{ e1, e2 }));
    try chain.append(try packArray(a, &.{e2}));
    // maps (sort after arrays): {} < {a:1} < {a:2} < {b:1}
    try chain.append(try packMap(a, &.{}));
    try chain.append(try packMap(a, &.{.{ ka, e1 }}));
    try chain.append(try packMap(a, &.{.{ ka, e2 }}));
    try chain.append(try packMap(a, &.{.{ kb, e1 }}));
    // sets (sort after maps): {} < {1} < {1,2} < {2}
    try chain.append(try packSet(a, &.{}));
    try chain.append(try packSet(a, &.{e1}));
    try chain.append(try packSet(a, &.{ e1, e2 }));
    try chain.append(try packSet(a, &.{e2}));

    for (1..chain.items.len) |i| {
        try testing.expectEqual(std.math.Order.lt, struple.order(chain.items[i - 1], chain.items[i]));
    }
}

// ---------------------------------------------------------------------------
// Decode error handling
// ---------------------------------------------------------------------------

test "decode: truncated and invalid input" {
    {
        var r = struple.reader(&.{0x22}); // 2 payload bytes promised, none follow
        try testing.expectError(error.Truncated, r.next());
    }
    {
        var r = struple.reader(&.{ 0x48, 0x61 }); // unterminated string
        try testing.expectError(error.Truncated, r.next());
    }
    {
        var r = struple.reader(&.{0x7F}); // invalid type code
        try testing.expectError(error.InvalidType, r.next());
    }
    {
        var r = struple.reader(&.{0x30}); // reserved 16-byte fixed int slot
        try testing.expectError(error.UnsupportedType, r.next());
    }
}

// ---------------------------------------------------------------------------
// JSON <-> struple
// ---------------------------------------------------------------------------

fn expectJsonRoundtrip(canonical: []const u8) !void {
    const a = testing.allocator;
    const encoded = try struple.fromJson(a, canonical);
    defer a.free(encoded);
    const back = try struple.toJson(a, encoded);
    defer a.free(back);
    try testing.expectEqualStrings(canonical, back);
}

test "json: fromJson matches manual packing" {
    const a = testing.allocator;
    {
        const j = try struple.fromJson(a, "12345");
        defer a.free(j);
        const m = try packOne(a, @as(i64, 12345));
        defer a.free(m);
        try testing.expectEqualSlices(u8, m, j);
    }
    {
        const j = try struple.fromJson(a, "\"users\"");
        defer a.free(j);
        const m = try packOne(a, "users");
        defer a.free(m);
        try testing.expectEqualSlices(u8, m, j);
    }
    {
        const j = try struple.fromJson(a, "true");
        defer a.free(j);
        try testing.expectEqualSlices(u8, &.{0x06}, j);
    }
}

test "json: round-trips (canonical form is byte-stable)" {
    try expectJsonRoundtrip("null");
    try expectJsonRoundtrip("true");
    try expectJsonRoundtrip("false");
    try expectJsonRoundtrip("0");
    try expectJsonRoundtrip("12345");
    try expectJsonRoundtrip("-42");
    try expectJsonRoundtrip("\"hello world\"");
    try expectJsonRoundtrip("\"quote\\\"and\\\\slash\"");
    try expectJsonRoundtrip("[]");
    try expectJsonRoundtrip("{}");
    try expectJsonRoundtrip("[1,2,3]");
    try expectJsonRoundtrip("{\"a\":1,\"b\":2}");
    try expectJsonRoundtrip("[null,true,\"x\",[1,2],{\"k\":\"v\"}]");
    // arbitrary-precision integers survive (a JS f64 round-trip would not)
    try expectJsonRoundtrip("100000000000000000000000000000");
    try expectJsonRoundtrip("-99999999999999999999999999999999");
}

test "json: object keys are canonicalized (sorted)" {
    const a = testing.allocator;
    const encoded = try struple.fromJson(a, "{\"b\":1,\"a\":2,\"c\":3}");
    defer a.free(encoded);
    const back = try struple.toJson(a, encoded);
    defer a.free(back);
    try testing.expectEqualStrings("{\"a\":2,\"b\":1,\"c\":3}", back);
}

test "json: floats round-trip by value" {
    const a = testing.allocator;
    const inputs = [_][]const u8{ "1.5", "-3.14159", "0.1", "1e10", "2.5e-3" };
    for (inputs) |s| {
        const encoded = try struple.fromJson(a, s);
        defer a.free(encoded);
        const back = try struple.toJson(a, encoded);
        defer a.free(back);
        try testing.expectEqual(try std.fmt.parseFloat(f64, s), try std.fmt.parseFloat(f64, back));
    }
}
