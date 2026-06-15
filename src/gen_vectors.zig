//! Generates conformance/vectors.json — the language-neutral cross-language
//! contract. Each entry is {"json": "<canonical JSON text>", "bytes": "<hex>"}.
//!
//! A conforming implementation must satisfy, for every vector:
//!     fromJson(json) == bytes        (encode is canonical, byte-exact)
//!     toJson(bytes)  == json         (decode is canonical; floats compare by value)
//!
//! `json` is stored as a string (the exact canonical text) so the contract is
//! unambiguous regardless of a consumer's number parsing. Run `zig build vectors`.

const std = @import("std");
const struple = @import("struple");

/// Canonical JSON inputs spanning the JSON-expressible type space.
/// Floats are non-integer-valued so their canonical text keeps a decimal point.
const inputs = [_][]const u8{
    "null",
    "true",
    "false",
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
    "100000000000000000000000000000",
    "-99999999999999999999999999999999",
    "1.5",
    "-3.14159",
    "0.5",
    "\"\"",
    "\"app\"",
    "\"apple\"",
    "\"hello world\"",
    "\"tab\\tnewline\\n\"",
    "[]",
    "[1,2,3]",
    "[null,true,\"x\",[1,2]]",
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

        try w.writeAll("  { \"json\": ");
        try writeJsonStringLiteral(w, canonical);
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

/// Emit `s` as a JSON string literal (escaping it a second time, since `s` is
/// itself canonical JSON text).
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
