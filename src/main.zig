//! Tiny demo / smoke test for struple. Run with `zig build run`.

const std = @import("std");
const struple = @import("struple");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const out = std.io.getStdOut().writer();

    // Build a record: ("users", 12345, "alice", true)
    var p = struple.Packer.init(gpa);
    defer p.deinit();
    try p.append("users");
    try p.append(@as(i64, 12345));
    try p.append("alice");
    try p.append(true);

    try out.print("packed {d} bytes: ", .{p.bytes().len});
    for (p.bytes()) |b| try out.print("{x:0>2} ", .{b});
    try out.print("\n\ndecoded:\n", .{});

    var r = struple.reader(p.bytes());
    while (try r.next()) |elem| {
        switch (elem) {
            .string => |s| try out.print("  string  {s}\n", .{s}),
            .int => |v| try out.print("  int     {d}\n", .{v}),
            .boolean => |v| try out.print("  bool    {}\n", .{v}),
            .float64 => |v| try out.print("  f64     {d}\n", .{v}),
            else => try out.print("  {s}\n", .{@tagName(elem)}),
        }
    }

    // Ordering: "app" really does sort before "apple" now.
    var app = struple.Packer.init(gpa);
    defer app.deinit();
    try app.append("app");
    var apple = struple.Packer.init(gpa);
    defer apple.deinit();
    try apple.append("apple");

    try out.print("\n\"app\" < \"apple\"  =>  {}\n", .{struple.order(app.bytes(), apple.bytes()) == .lt});
}
