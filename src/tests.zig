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

test "golden: wide integers (i128 fixed slots)" {
    // 2^64: 9-byte fixed positive (slot 0x29)
    try expectBytes(@as(i128, 1) << 64, &.{ 0x29, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // -(2^64): the excess-form carry drops it to an 8-byte fixed negative (slot 0x18)
    try expectBytes(-(@as(i128, 1) << 64), &.{ 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // i128 max = 2^127 - 1: widest fixed positive (slot 0x30)
    try expectBytes(@as(i128, std.math.maxInt(i128)), &([_]u8{ 0x30, 0x7F } ++ [_]u8{0xFF} ** 15));
    // i128 min = -2^127: widest fixed negative (slot 0x10)
    try expectBytes(@as(i128, std.math.minInt(i128)), &([_]u8{ 0x10, 0x80 } ++ [_]u8{0x00} ** 15));
}

test "golden: big integers (beyond i128)" {
    const a = testing.allocator;
    // 2^127: first value past i128 max -> big-int code 0x31, [m=1][n=16][magnitude]
    {
        var mag = [_]u8{0} ** 16;
        mag[0] = 0x80;
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendBigInt(false, &mag);
        try testing.expectEqualSlices(u8, &([_]u8{ 0x31, 0x01, 0x10, 0x80 } ++ [_]u8{0x00} ** 15), p.bytes());
    }
    // -(2^127) - 1: first value past i128 min -> big-int code 0x0F, every field complemented
    {
        var mag = [_]u8{0} ** 16;
        mag[0] = 0x80;
        mag[15] = 0x01; // magnitude 2^127 + 1
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendBigInt(true, &mag);
        try testing.expectEqualSlices(u8, &([_]u8{ 0x0F, 0xFE, 0xEF, 0x7F } ++ [_]u8{0xFF} ** 14 ++ [_]u8{0xFE}), p.bytes());
    }
}

test "golden: decimals" {
    const a = testing.allocator;
    const cases = [_]struct { s: []const u8, hex: []const u8 }{
        .{ .s = "0", .hex = &.{ 0x38, 0x02 } },
        .{ .s = "12.345", .hex = &.{ 0x38, 0x03, 0x21, 0x02, 0x0D, 0x23, 0x33, 0x00 } },
        .{ .s = "-12.345", .hex = &.{ 0x38, 0x01, 0xDE, 0xFD, 0xF2, 0xDC, 0xCC, 0xFF } },
        .{ .s = "100", .hex = &.{ 0x38, 0x03, 0x21, 0x03, 0x0B, 0x00 } },
        .{ .s = "0.001", .hex = &.{ 0x38, 0x03, 0x1F, 0xFE, 0x0B, 0x00 } },
        .{ .s = "12.300", .hex = &.{ 0x38, 0x03, 0x21, 0x02, 0x0D, 0x1F, 0x00 } }, // canonicalizes to 12.3
    };
    for (cases) |c| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendDecimalString(c.s);
        try testing.expectEqualSlices(u8, c.hex, p.bytes());
    }
}

test "ordering: decimals sort between floats and timestamps, by value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const decs = [_][]const u8{ "-100", "-1.5", "-0.001", "0", "0.001", "1.5", "100", "1e30" };
    var prev: ?[]const u8 = null;
    for (decs) |s| {
        var p = struple.Packer.init(a);
        try p.appendDecimalString(s);
        const cur = try p.toOwnedSlice();
        if (prev) |pr| try testing.expectEqual(std.math.Order.lt, struple.order(pr, cur));
        prev = cur;
    }

    // a decimal sits above any float and below any timestamp in raw byte order
    var fbuf = struple.Packer.init(a);
    try fbuf.appendF64(std.math.inf(f64));
    var dbuf = struple.Packer.init(a);
    try dbuf.appendDecimalString("-1e9");
    var tbuf = struple.Packer.init(a);
    try tbuf.appendTimestamp(std.math.minInt(i64));
    try testing.expectEqual(std.math.Order.lt, struple.order(fbuf.bytes(), dbuf.bytes())); // float < decimal
    try testing.expectEqual(std.math.Order.lt, struple.order(dbuf.bytes(), tbuf.bytes())); // decimal < timestamp
}

test "round-trip: decimals" {
    const a = testing.allocator;
    const samples = [_][]const u8{ "0", "5", "-5", "12.345", "-12.345", "0.001", "100", "9.99", "1e30", "1e-9", "-0.5" };
    for (samples) |s| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendDecimalString(s);

        var r = struple.reader(p.bytes());
        const d = (try r.next()).?.decimal;
        try testing.expect(try r.next() == null);

        // re-pack from the decoded (sign, digits, exponent) -> byte-identical
        var dig: [64]u8 = undefined;
        const digs = d.coefficientDigits(&dig);
        var q = struple.Packer.init(a);
        defer q.deinit();
        try q.appendDecimal(d.negative, digs, @intCast(d.exponent()));
        try testing.expectEqualSlices(u8, p.bytes(), q.bytes());
    }

    // a fully-specified decode: 12.345 = +12345 x 10^-3
    {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendDecimalString("12.345");
        var r = struple.reader(p.bytes());
        const d = (try r.next()).?.decimal;
        try testing.expect(!d.negative and !d.isZero());
        try testing.expectEqual(@as(usize, 5), d.digitCount());
        try testing.expectEqual(@as(i64, -3), d.exponent());
        var dig: [16]u8 = undefined;
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, d.coefficientDigits(&dig));
    }
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

test "golden + round-trip: uuid" {
    const a = testing.allocator;
    const u = [16]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.appendUuid(u);
    try testing.expectEqualSlices(u8, &([_]u8{0x44} ++ u), p.bytes());

    var r = struple.reader(p.bytes());
    try testing.expectEqual(u, (try r.next()).?.uuid);
    try testing.expect(try r.next() == null);
}

test "ordering: uuid sits between timestamp and string, ordered by bytes" {
    const a = testing.allocator;
    var lo = struple.Packer.init(a);
    defer lo.deinit();
    try lo.appendUuid([_]u8{0} ** 16);
    var hi = struple.Packer.init(a);
    defer hi.deinit();
    try hi.appendUuid([_]u8{0} ** 15 ++ [_]u8{1});
    try testing.expectEqual(std.math.Order.lt, struple.order(lo.bytes(), hi.bytes()));

    var ts = struple.Packer.init(a);
    defer ts.deinit();
    try ts.appendTimestamp(std.math.maxInt(i64));
    var str = struple.Packer.init(a);
    defer str.deinit();
    try str.appendString("");
    try testing.expectEqual(std.math.Order.lt, struple.order(ts.bytes(), lo.bytes())); // timestamp < uuid
    try testing.expectEqual(std.math.Order.lt, struple.order(hi.bytes(), str.bytes())); // uuid < string
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

test "round-trip: wide integers (i128 fixed slots and beyond)" {
    const a = testing.allocator;

    // values across the 9–16 byte fixed slots now decode straight to .int
    const fixed_cases = [_]i128{
        @as(i128, 1) << 64, -(@as(i128, 1) << 64),  @as(i128, 1) << 100,
        -(@as(i128, 1) << 100), std.math.maxInt(i128), std.math.minInt(i128),
    };
    for (fixed_cases) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(v, (try r.next()).?.int);
    }

    // boundary: 2^127 (one past i128 max) uses the big-int path; -2^127 still fits
    {
        var mag = [_]u8{0} ** 16;
        mag[0] = 0x80; // 2^127
        var pp = struple.Packer.init(a);
        defer pp.deinit();
        try pp.appendBigInt(false, &mag);
        var rp = struple.reader(pp.bytes());
        const ep = (try rp.next()).?;
        try testing.expect(ep == .big_int and ep.big_int.toI128() == null);

        var pn = struple.Packer.init(a);
        defer pn.deinit();
        try pn.appendBigInt(true, &mag); // -2^127 == i128 min
        var rn = struple.reader(pn.bytes());
        try testing.expectEqual(std.math.minInt(i128), (try rn.next()).?.int);
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
        var r = struple.reader(&.{0x29}); // 9-byte fixed int, payload missing
        try testing.expectError(error.Truncated, r.next());
    }
    {
        // non-canonical 16-byte positive: value >= 2^127 must use the big-int code
        const buf = [_]u8{ 0x30, 0x80 } ++ [_]u8{0x00} ** 15;
        var r = struple.reader(&buf);
        try testing.expectError(error.InvalidType, r.next());
    }
    {
        // Item 1 — big-int length header claims n=2^64-1 (10 bytes total). Must be a
        // clean Truncated, never an overflow-driven OOB read / panic.
        var r = struple.reader(&.{ 0x31, 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        try testing.expectError(error.Truncated, r.next());
    }
    {
        // Item 1 — negative big-int, same class. Length bytes are bit-complemented,
        // so m byte 0xF7 = 8 and magnitude-length bytes 0x00 = n=2^64-1.
        var r = struple.reader(&.{ 0x0f, 0xf7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
        try testing.expectError(error.Truncated, r.next());
    }
    {
        // Item 1 — length-of-length m=9 exceeds the 8-byte cap.
        var r = struple.reader(&.{ 0x31, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        try testing.expectError(error.InvalidType, r.next());
    }
    {
        // Item 1 — truncated big-int: m announced, length byte missing.
        var r = struple.reader(&.{ 0x31, 0x01 });
        try testing.expectError(error.Truncated, r.next());
    }
    {
        // Item 7 — strict decode rejects non-canonical forms.
        const cases = [_][]const u8{
            &.{ 0x22, 0x00, 0x05 }, // fixed int: leading-zero positive (5 in 2 bytes)
            &.{ 0x1e, 0xff, 0x00 }, // fixed int: non-minimal negative (-256 in 2 bytes)
            &.{ 0x31, 0x00 }, // big-int: empty magnitude (zero-magnitude intSign bug)
            &.{ 0x31, 0x01, 0x01, 0x05 }, // big-int: value fits the fixed range
            // big-int with a non-minimal length header (m=2 for n=17):
            &.{ 0x31, 0x02, 0x00, 0x11, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        };
        for (cases) |c| {
            var r = struple.reader(c);
            try testing.expectError(error.InvalidType, r.next());
        }
    }
}

// ---------------------------------------------------------------------------
// JSON <-> struple
// ---------------------------------------------------------------------------

test "depth cap: deeply nested input is rejected, not a stack overflow" {
    const a = testing.allocator;
    // fromJson: 1000-deep JSON array (> max_depth) rejects on the pre-parse scan.
    {
        var s = std.ArrayList(u8).init(a);
        defer s.deinit();
        try s.appendNTimes('[', 1000);
        try s.appendNTimes(']', 1000);
        try testing.expectError(error.NestingTooDeep, struple.fromJson(a, s.items));
    }
    // Build a 300-deep nested array encoding, then toJson / semanticOrder must
    // reject it at the cap rather than recursing to overflow.
    {
        var buf = std.ArrayList(u8).init(a);
        defer buf.deinit();
        {
            var inner = struple.Packer.init(a);
            defer inner.deinit();
            try inner.appendInt(0);
            try buf.appendSlice(inner.bytes());
        }
        var d: usize = 0;
        while (d < 300) : (d += 1) {
            var p = struple.Packer.init(a);
            defer p.deinit();
            try p.appendArray(buf.items);
            buf.clearRetainingCapacity();
            try buf.appendSlice(p.bytes());
        }
        try testing.expectError(error.NestingTooDeep, struple.toJson(a, buf.items));
        try testing.expectError(error.NestingTooDeep, struple.semanticOrder(a, buf.items, buf.items));
    }
}

test "decimal: exponent bounds, scientific render, DoS short-circuit (Item 2)" {
    const a = testing.allocator;

    // Encode-side bounds: exponent literal / adjusted exponent past i32 are rejected.
    {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try testing.expectError(error.InvalidDecimal, p.appendDecimalString("1e9999999999"));
        try testing.expectError(error.InvalidDecimal, p.appendDecimalString("1e2147483647")); // adj_exp 2^31
    }
    // Valid boundary: adjusted exponent == i32 max decodes cleanly.
    {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendDecimalString("1e2147483646"); // adj_exp = 2147483647 = i32 max
        var r = struple.reader(p.bytes());
        _ = try r.next();
    }
    // Decode-side bound: a wire decimal with adjusted exponent i32max+1 is rejected.
    {
        const bad = [_]u8{ 0x38, 0x03, 0x24, 0x80, 0x00, 0x00, 0x00, 0x0b, 0x00 };
        var r = struple.reader(&bad);
        try testing.expectError(error.InvalidType, r.next());
    }
    // Scientific toJson past the plain-notation pad threshold (also pinned by corpus).
    {
        const cases = [_]struct { s: []const u8, j: []const u8 }{
            .{ .s = "1e40", .j = "10000000000000000000000000000000000000000" },
            .{ .s = "1e41", .j = "1e+41" },
            .{ .s = "1e300", .j = "1e+300" },
            .{ .s = "1e-300", .j = "1e-300" },
            .{ .s = "1.5e300", .j = "1.5e+300" },
        };
        for (cases) |c| {
            var p = struple.Packer.init(a);
            defer p.deinit();
            try p.appendDecimalString(c.s);
            const j = try struple.toJson(a, p.bytes());
            defer a.free(j);
            try testing.expectEqualStrings(c.j, j);
        }
    }
    // Semantic short-circuit: an astronomically large/small (but i32-valid) exponent
    // must decide by order of magnitude, never by materializing a 2^31-scaled value.
    {
        var huge = struple.Packer.init(a);
        defer huge.deinit();
        try huge.appendDecimalString("1e2000000000");
        var tiny = struple.Packer.init(a);
        defer tiny.deinit();
        try tiny.appendDecimalString("1e-2000000000");
        var five = struple.Packer.init(a);
        defer five.deinit();
        try five.appendInt(5);
        var onef = struple.Packer.init(a);
        defer onef.deinit();
        try onef.appendF64(1.0);
        try testing.expectEqual(std.math.Order.gt, try struple.semanticOrder(a, huge.bytes(), five.bytes()));
        try testing.expectEqual(std.math.Order.lt, try struple.semanticOrder(a, tiny.bytes(), five.bytes()));
        try testing.expectEqual(std.math.Order.gt, try struple.semanticOrder(a, huge.bytes(), onef.bytes()));
        try testing.expectEqual(std.math.Order.lt, try struple.semanticOrder(a, tiny.bytes(), onef.bytes()));
    }
}

test "fromJson rejects grammar-edge inputs (Item 4)" {
    const a = testing.allocator;
    const reject = [_][]const u8{
        "{\"k\":1,\"k\":2}", // duplicate key
        "\"\\ud800\"", // lone high surrogate
        "\"\\udc00\"", // lone low surrogate
        "1e999", // float overflow
        "-", // sign only
        "NaN", // not JSON
        "Infinity", // not JSON
        "-Infinity", // not JSON
    };
    for (reject) |c| {
        try testing.expect(std.meta.isError(struple.fromJson(a, c)));
    }
    // A valid surrogate pair (astral char) is accepted.
    const ok = try struple.fromJson(a, "\"\\ud83d\\ude00\"");
    a.free(ok);
}

test "toJson float format: ECMAScript Number::toString (Item 3)" {
    const a = testing.allocator;
    const cases = [_]struct { f: f64, j: []const u8 }{
        .{ .f = 0.1, .j = "0.1" },
        .{ .f = 1.5, .j = "1.5" },
        .{ .f = 100.0, .j = "100" },
        .{ .f = 1234.5678, .j = "1234.5678" },
        .{ .f = 1e-6, .j = "0.000001" },
        .{ .f = 1e-7, .j = "1e-7" }, // first exponential on the small side
        .{ .f = 1e16, .j = "10000000000000000" },
        .{ .f = 1e20, .j = "100000000000000000000" },
        .{ .f = 1e21, .j = "1e+21" }, // first exponential on the large side
        .{ .f = 5e-324, .j = "5e-324" }, // smallest subnormal
        .{ .f = 1.7976931348623157e308, .j = "1.7976931348623157e+308" }, // max f64
        .{ .f = -0.0, .j = "0" },
        .{ .f = -2.5, .j = "-2.5" },
    };
    for (cases) |c| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendF64(c.f);
        const j = try struple.toJson(a, p.bytes());
        defer a.free(j);
        try testing.expectEqualStrings(c.j, j);
    }
}

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

test "json: decimals render as exact number literals (one-way)" {
    const a = testing.allocator;
    const cases = [_]struct { s: []const u8, want: []const u8 }{
        .{ .s = "0", .want = "0" },
        .{ .s = "12.345", .want = "12.345" },
        .{ .s = "-12.345", .want = "-12.345" },
        .{ .s = "100", .want = "100" },
        .{ .s = "0.001", .want = "0.001" },
        .{ .s = "12.300", .want = "12.3" }, // canonical
        .{ .s = "-0.5", .want = "-0.5" },
        .{ .s = "1e3", .want = "1000" },
    };
    for (cases) |c| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendDecimalString(c.s);
        const json = try struple.toJson(a, p.bytes());
        defer a.free(json);
        try testing.expectEqualStrings(c.want, json);
    }
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

// ---------------------------------------------------------------------------
// Navigation / query (View, MapView)
// ---------------------------------------------------------------------------

fn intOf(view_bytes: []const u8) !i128 {
    var r = struple.reader(view_bytes);
    return (try r.next()).?.int;
}

test "navigate: stream ops (count/at/head/tail/nthRest/take)" {
    const a = testing.allocator;
    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.append("users");
    try p.append(@as(i64, 12345));
    try p.append(true);
    var child = struple.Packer.init(a);
    defer child.deinit();
    try child.appendInt(1);
    try child.appendInt(2);
    try child.appendInt(3);
    try p.appendArray(child.bytes());

    const v = struple.view(p.bytes());
    try testing.expectEqual(@as(usize, 4), try v.count());
    try testing.expectEqual(@as(?u8, struple.tc.string), v.headType());

    // at() yields decodable sub-views
    var r0 = struple.reader((try v.at(0)).?);
    try testing.expectEqualStrings("users", (try r0.next()).?.string);
    try testing.expectEqual(@as(i128, 12345), try intOf((try v.at(1)).?));
    try testing.expect(try v.at(4) == null);

    // head == at(0)
    try testing.expectEqualSlices(u8, (try v.at(0)).?, (try v.head()).?);

    // tail = elements 1.. ; nthRest(2) = elements 2.. ; take(2) = prefix
    try testing.expectEqual(@as(usize, 3), try struple.view(try v.tail()).count());
    try testing.expectEqual(@as(usize, 2), try struple.view(try v.nthRest(2)).count());
    const tk = try v.take(2);
    try testing.expectEqual(@as(usize, 2), try struple.view(tk).count());
    try testing.expectEqualSlices(u8, p.bytes()[0..tk.len], tk);
}

test "navigate: predicates and container descent" {
    const a = testing.allocator;
    {
        const b = try packOne(a, "x");
        defer a.free(b);
        try testing.expect(struple.view(b).isString());
    }
    {
        const b = try packOne(a, @as(i64, 5));
        defer a.free(b);
        const v = struple.view(b);
        try testing.expect(v.isInt() and v.isNumber() and !v.isFloat());
    }
    {
        const b = try packOne(a, @as(f64, 1.5));
        defer a.free(b);
        const v = struple.view(b);
        try testing.expect(v.isFloat() and v.isNumber() and !v.isInt());
    }
    {
        const b = try packOne(a, null);
        defer a.free(b);
        try testing.expect(struple.view(b).isNil());
    }

    // array: one top-level element that descends to its 2-element inner stream
    var child = struple.Packer.init(a);
    defer child.deinit();
    try child.appendInt(10);
    try child.appendInt(20);
    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.appendArray(child.bytes());

    const v = struple.view(p.bytes());
    try testing.expect(v.isArray() and v.isContainer());
    try testing.expectEqual(@as(usize, 1), try v.count());
    const inner = (try v.containedItems(a)).?;
    defer a.free(inner);
    const iv = struple.view(inner);
    try testing.expectEqual(@as(usize, 2), try iv.count());
    try testing.expectEqual(@as(i128, 10), try intOf((try iv.at(0)).?));
    try testing.expectEqual(@as(i128, 20), try intOf((try iv.at(1)).?));
}

test "navigate: map lookup (get/iterator)" {
    const a = testing.allocator;
    const ka = try packOne(a, "a");
    defer a.free(ka);
    const kb = try packOne(a, "b");
    defer a.free(kb);
    const kc = try packOne(a, "c");
    defer a.free(kc);
    const kz = try packOne(a, "z");
    defer a.free(kz);
    const v1 = try packOne(a, @as(i64, 1));
    defer a.free(v1);
    const v2 = try packOne(a, @as(i64, 2));
    defer a.free(v2);
    const v3 = try packOne(a, @as(i64, 3));
    defer a.free(v3);

    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.appendMap(&.{ .{ kc, v3 }, .{ ka, v1 }, .{ kb, v2 } }); // out of order -> canonical

    const mv = struple.view(p.bytes());
    try testing.expect(mv.isMap());
    const inner = (try mv.containedItems(a)).?;
    defer a.free(inner);
    const m = struple.MapView.init(inner);
    try testing.expectEqual(@as(usize, 3), try m.count());

    // hit
    try testing.expectEqualSlices(u8, v2, (try m.get(kb)).?);
    // miss past the end (early exit) and in the middle
    try testing.expect(try m.get(kz) == null);
    const kaa = try packOne(a, "aa");
    defer a.free(kaa);
    try testing.expect(try m.get(kaa) == null);

    // iterator yields keys in canonical (sorted) order
    var it = m.iterator();
    try testing.expectEqualSlices(u8, ka, (try it.next()).?.key);
    try testing.expectEqualSlices(u8, kb, (try it.next()).?.key);
    try testing.expectEqualSlices(u8, kc, (try it.next()).?.key);
    try testing.expect(try it.next() == null);
}

test "navigate: indexed map (O(log n) get, positional at)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
    const keys = [_][]const u8{ "h", "c", "a", "g", "d", "f", "b", "e" };
    var entries: [keys.len][2][]const u8 = undefined;
    for (keys, 0..) |k, i| {
        entries[i] = .{ try packOne(a, k), try packOne(a, @as(i64, @intCast(i + 1))) };
    }
    var p = struple.Packer.init(a);
    try p.appendMap(&entries);

    const mv = struple.view(p.bytes());
    const inner = (try mv.containedItems(a)).?;
    var im = try struple.IndexedMap.init(a, inner);
    defer im.deinit(a);

    try testing.expectEqual(@as(usize, 8), im.count());

    // at() walks canonical (sorted) order: a,b,c,...,h
    for ("abcdefgh", 0..) |ch, i| {
        const e = im.at(i).?;
        var kr = struple.reader(e.key);
        try testing.expectEqualStrings(&[_]u8{ch}, (try kr.next()).?.string);
    }
    try testing.expect(im.at(8) == null);

    // get() binary-searches; agrees with the linear MapView.get on every key
    const m = struple.MapView.init(inner);
    for ("abcdefgh") |ch| {
        const key = try packOne(a, &[_]u8{ch});
        const want = (try m.get(key)).?;
        try testing.expectEqualSlices(u8, want, im.get(key).?);
    }
    // "e" was inserted 8th (value 8) but sits at sorted position 4 — get still finds it
    try testing.expectEqual(@as(usize, 4), im.find(try packOne(a, "e")).?);
    try testing.expectEqual(@as(i128, 8), try intOf(im.get(try packOne(a, "e")).?));

    // misses: before, between, and after the key range
    try testing.expect(im.get(try packOne(a, "A")) == null); // below "a"
    try testing.expect(im.get(try packOne(a, "cc")) == null); // between "c" and "d"
    try testing.expect(im.get(try packOne(a, "z")) == null); // above "h"
    try testing.expect(im.find(try packOne(a, "a")).? == 0);
    try testing.expect(im.find(try packOne(a, "h")).? == 7);

    // iterator yields the same canonical order
    var it = im.iterator();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 8), n);
}

// ---------------------------------------------------------------------------
// Semantic (value-based) ordering
// ---------------------------------------------------------------------------

fn semF64(a: std.mem.Allocator, v: f64) ![]u8 {
    var p = struple.Packer.init(a);
    try p.appendF64(v);
    return p.toOwnedSlice();
}
fn semF32(a: std.mem.Allocator, v: f32) ![]u8 {
    var p = struple.Packer.init(a);
    try p.appendF32(v);
    return p.toOwnedSlice();
}
fn semBig(a: std.mem.Allocator, neg: bool, mag: []const u8) ![]u8 {
    var p = struple.Packer.init(a);
    try p.appendBigInt(neg, mag);
    return p.toOwnedSlice();
}
fn semDec(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var p = struple.Packer.init(a);
    try p.appendDecimalString(s);
    return p.toOwnedSlice();
}

test "semantic: numbers compare by exact value across representations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lt = std.math.Order.lt;
    const eq = std.math.Order.eq;
    const gt = std.math.Order.gt;

    // int <-> float by value (and -0.0 == 0 == 0.0)
    try testing.expectEqual(eq, try struple.semanticOrder(a, try packOne(a, @as(i64, 5)), try semF64(a, 5.0)));
    try testing.expectEqual(eq, try struple.semanticOrder(a, try packOne(a, @as(i64, 0)), try semF64(a, -0.0)));
    try testing.expectEqual(lt, try struple.semanticOrder(a, try packOne(a, @as(i64, 3)), try semF64(a, 3.5)));
    try testing.expectEqual(gt, try struple.semanticOrder(a, try packOne(a, @as(i64, 4)), try semF64(a, 3.5)));
    try testing.expectEqual(lt, try struple.semanticOrder(a, try semF64(a, -2.5), try packOne(a, @as(i64, -2))));
    try testing.expectEqual(eq, try struple.semanticOrder(a, try semF32(a, 1.5), try semF64(a, 1.5)));

    // the 2^53 boundary — exact, where f64 loses integer precision
    const two53: i64 = 1 << 53;
    try testing.expectEqual(eq, try struple.semanticOrder(a, try packOne(a, two53), try semF64(a, @floatFromInt(two53))));
    try testing.expectEqual(gt, try struple.semanticOrder(a, try packOne(a, two53 + 1), try semF64(a, @as(f64, @floatFromInt(two53)))));

    // i128 vs large float (exact power of two)
    const p100 = std.math.ldexp(@as(f64, 1.0), 100);
    try testing.expectEqual(eq, try struple.semanticOrder(a, try packOne(a, @as(i128, 1) << 100), try semF64(a, p100)));
    try testing.expectEqual(gt, try struple.semanticOrder(a, try packOne(a, (@as(i128, 1) << 100) + 1), try semF64(a, p100)));
    try testing.expectEqual(lt, try struple.semanticOrder(a, try packOne(a, (@as(i128, 1) << 100) - 1), try semF64(a, p100)));

    // big-int (> i128) vs float, exact
    var m200 = [_]u8{0} ** 26;
    m200[0] = 1; // 2^200
    const p200 = std.math.ldexp(@as(f64, 1.0), 200);
    try testing.expectEqual(eq, try struple.semanticOrder(a, try semBig(a, false, &m200), try semF64(a, p200)));
    var m200p1 = [_]u8{0} ** 26;
    m200p1[0] = 1;
    m200p1[25] = 1; // 2^200 + 1
    try testing.expectEqual(gt, try struple.semanticOrder(a, try semBig(a, false, &m200p1), try semF64(a, p200)));
    try testing.expectEqual(lt, try struple.semanticOrder(a, try semBig(a, true, &m200p1), try semF64(a, -p200)));

    // infinities and NaN
    try testing.expectEqual(lt, try struple.semanticOrder(a, try packOne(a, @as(i128, 1) << 120), try semF64(a, std.math.inf(f64))));
    try testing.expectEqual(gt, try struple.semanticOrder(a, try semF64(a, std.math.nan(f64)), try semF64(a, std.math.inf(f64))));
    try testing.expectEqual(eq, try struple.semanticOrder(a, try semF64(a, std.math.nan(f64)), try semF32(a, std.math.nan(f32))));
    try testing.expectEqual(lt, try struple.semanticOrder(a, try semF64(a, -std.math.inf(f64)), try packOne(a, @as(i64, -999999))));
}

test "semantic: decimals compare by exact value across representations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lt = std.math.Order.lt;
    const eq = std.math.Order.eq;
    const gt = std.math.Order.gt;
    const so = struple.semanticOrder;

    // decimal vs int / float / decimal, by value
    try testing.expectEqual(eq, try so(a, try semDec(a, "5"), try packOne(a, @as(i64, 5))));
    try testing.expectEqual(eq, try so(a, try semDec(a, "5.0"), try semF64(a, 5.0)));
    try testing.expectEqual(eq, try so(a, try semDec(a, "1.50"), try semDec(a, "1.5")));
    try testing.expectEqual(lt, try so(a, try semDec(a, "1.5"), try semDec(a, "1.6")));
    try testing.expectEqual(gt, try so(a, try semDec(a, "123.5"), try packOne(a, @as(i64, 123))));
    try testing.expectEqual(eq, try so(a, try semDec(a, "-7.25"), try semF64(a, -7.25)));
    try testing.expectEqual(eq, try so(a, try semDec(a, "0"), try semF64(a, -0.0)));

    // exactness: 0.1 is not representable in f64, so decimal 0.1 < float 0.1
    try testing.expectEqual(lt, try so(a, try semDec(a, "0.1"), try semF64(a, 0.1)));
    try testing.expectEqual(eq, try so(a, try semDec(a, "2.5"), try semF64(a, 2.5))); // 2.5 is exact

    // decimal vs big-int (beyond i128) by exact value: 10^40
    const big1e40 = try struple.fromJson(a, "10000000000000000000000000000000000000000");
    try testing.expectEqual(eq, try so(a, try semDec(a, "1e40"), big1e40));
    try testing.expectEqual(gt, try so(a, try semDec(a, "1.0000000000000000000000000000000000000001e40"), big1e40));

    // decimal is in the number class: a huge decimal still sorts below a timestamp
    var ts = struple.Packer.init(a);
    try ts.appendTimestamp(0);
    try testing.expectEqual(lt, try so(a, try semDec(a, "1e1000"), try ts.toOwnedSlice()));
}

test "semantic: cross-type classes and container recursion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lt = std.math.Order.lt;
    const eq = std.math.Order.eq;

    // nil < undefined < bool < number < timestamp < uuid < string < bytes
    var chain = std.ArrayList([]const u8).init(a);
    try chain.append(try packOne(a, null));
    {
        var p = struple.Packer.init(a);
        try p.appendUndefined();
        try chain.append(try p.toOwnedSlice());
    }
    try chain.append(try packOne(a, true));
    try chain.append(try semF64(a, 1.0e300)); // a number (huge, but still < timestamp class)
    {
        var p = struple.Packer.init(a);
        try p.appendTimestamp(0);
        try chain.append(try p.toOwnedSlice());
    }
    {
        var p = struple.Packer.init(a);
        try p.appendUuid([_]u8{0} ** 16);
        try chain.append(try p.toOwnedSlice());
    }
    try chain.append(try packOne(a, "z"));
    {
        var p = struple.Packer.init(a);
        try p.appendBytes(&.{0x00});
        try chain.append(try p.toOwnedSlice());
    }
    for (1..chain.items.len) |i| {
        try testing.expectEqual(lt, try struple.semanticOrder(a, chain.items[i - 1], chain.items[i]));
    }

    // containers recurse by value: [5] == [5.0], and [1,2] < [1, 2.5]
    const arr_i = try packArray(a, &.{try packOne(a, @as(i64, 5))});
    const arr_f = try packArray(a, &.{try semF64(a, 5.0)});
    try testing.expectEqual(eq, try struple.semanticOrder(a, arr_i, arr_f));

    const arr_12 = try packArray(a, &.{ try packOne(a, @as(i64, 1)), try packOne(a, @as(i64, 2)) });
    const arr_125 = try packArray(a, &.{ try packOne(a, @as(i64, 1)), try semF64(a, 2.5) });
    try testing.expectEqual(lt, try struple.semanticOrder(a, arr_12, arr_125));

    // a shorter tuple sorts before a longer one that extends it
    try testing.expectEqual(lt, try struple.semanticOrder(a, try packOne(a, @as(i64, 1)), try concat(a, &.{ try packOne(a, @as(i64, 1)), try packOne(a, @as(i64, 0)) })));
}
