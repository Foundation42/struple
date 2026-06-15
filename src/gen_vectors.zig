//! Generates conformance/vectors.json — the language-neutral cross-language
//! contract. Each entry is {"value": <canonical JSON value>, "bytes": "<hex>"}.
//!
//! A conforming implementation must satisfy, for every vector:
//!     fromJson(value) == bytes        (encode is canonical)
//!     toJson(bytes)   == value        (decode is canonical)
//!
//! Run with `zig build vectors`.

const std = @import("std");
const struple = @import("struple");

/// Canonical JSON inputs spanning the JSON-expressible type space.
const inputs = [_][]const u8{
    // null / bool
    "null",
    "true",
    "false",
    // integers across width bands and signs
    "0",
    "1",
    "-1",
    "255",
    "256",
    "-256",
    "12345",
    "-42",
    "9223372036854775807",
    "-9223372036854775808",
    // arbitrary-precision integers (a JS f64 round-trip would corrupt these)
    "100000000000000000000000000000",
    "-99999999999999999999999999999999",
    // floats
    "1.5",
    "-3.14159",
    "1e10",
    // strings (incl. prefixes that exercise lexicographic ordering, and escapes)
    "\"\"",
    "\"app\"",
    "\"apple\"",
    "\"hello world\"",
    "\"tab\\tnewline\\n\"",
    // arrays
    "[]",
    "[1,2,3]",
    "[null,true,\"x\",[1,2]]",
    // objects (canonical = keys sorted)
    "{}",
    "{\"a\":1,\"b\":2}",
    "{\"active\":true,\"id\":12345,\"name\":\"alice\",\"score\":87.5,\"tags\":[\"x\",\"y\"]}",
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();

    try w.writeAll("[\n");
    for (inputs, 0..) |input, i| {
        const encoded = try struple.fromJson(a, input);
        const canonical = try struple.toJson(a, encoded);

        try w.writeAll("  { \"value\": ");
        try w.writeAll(canonical); // already valid JSON
        try w.writeAll(", \"bytes\": \"");
        for (encoded) |b| try w.print("{x:0>2}", .{b});
        try w.writeAll("\" }");
        if (i + 1 < inputs.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try w.writeAll("]\n");

    try std.fs.cwd().makePath("conformance");
    try std.fs.cwd().writeFile(.{ .sub_path = "conformance/vectors.json", .data = out.items });
    std.debug.print("wrote conformance/vectors.json ({d} vectors)\n", .{inputs.len});
}
