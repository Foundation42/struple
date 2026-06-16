//! struple reference benchmark (Zig).
//!
//! Measures encode (build a stream from in-memory records) and decode (walk a
//! stream, touching every value) throughput for a set of representative
//! workloads — four realistic streaming shapes (stock quotes, geospatial points,
//! tweets, blockchain transactions) plus three structural micro-benchmarks (an
//! integer stream, a string stream, and a nested map/array document).
//!
//! Methodology: ReleaseFast, deterministic data (fixed PRNG seed), per-(payload,
//! op) auto-calibration to a target trial duration, several trials with the
//! median reported, and a global checksum sink so the optimizer can't elide the
//! work. Steady-state buffers are reused (the encoder's output buffer and the
//! decoder's unescape arena retain capacity), so the numbers reflect codec
//! compute, not allocator warm-up.
//!
//! Run with `zig build bench`. Writes BENCHMARKS.md and bench/payloads.json.

const std = @import("std");
const struple = @import("struple");

const Packer = struple.Packer;
const Reader = struple.Reader;

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this; printed at the end so
// the compiler must actually perform the work.
// ---------------------------------------------------------------------------
var g_sink: u64 = 0;

// ---------------------------------------------------------------------------
// Record shapes for the realistic streaming workloads.
// ---------------------------------------------------------------------------

/// A price as an exact decimal: coefficient digits (MSD-first, each 0–9) · 10^exp.
const Dec = struct { digits: []const u8, exp: i32 };

const Quote = struct {
    symbol: []const u8,
    bid: Dec,
    ask: Dec,
    last: f64,
    volume: i64,
    ts: i64, // µs since epoch
};

const Geo = struct {
    lat: f64,
    lon: f64,
    elevation: f64,
    name: []const u8,
    ts: i64,
};

const Tweet = struct {
    id: u64,
    user: []const u8,
    text: []const u8,
    created_at: i64,
    likes: i64,
    retweets: i64,
};

const Tx = struct {
    height: i64,
    tx_hash: [32]u8,
    from: [20]u8,
    to: [20]u8,
    /// Big-endian magnitude of the value in wei. ≤15 bytes → fixed wide-int path;
    /// ≥17 bytes → arbitrary-precision big-int path (the 256-bit showcase).
    value_be: []const u8,
    value_big: bool, // true → big-int code, false → fits the i128 fixed path
    gas: i64,
    nonce: i64,
    ts: i64,
};

const Nested = struct {
    uid: i64,
    name: []const u8,
    active: bool,
    scores: [3]i64,
};

const Data = struct {
    quotes: []Quote,
    geo: []Geo,
    tweets: []Tweet,
    txs: []Tx,
    ints: []i64,
    strings: [][]const u8,
    nested: []Nested,
};

const PKind = enum { quotes, geo, tweets, txs, ints, strings, nested };

const PayloadMeta = struct {
    kind: PKind,
    name: []const u8,
    category: []const u8,
    description: []const u8,
};

const payloads = [_]PayloadMeta{
    .{ .kind = .quotes, .name = "stock_quotes", .category = "streaming", .description = "Level-1 equity quotes: symbol, exact decimal bid/ask, f64 last, volume, timestamp" },
    .{ .kind = .geo, .name = "geo_points", .category = "streaming", .description = "Geospatial fixes: f64 lat/lon/elevation, place name, timestamp" },
    .{ .kind = .tweets, .name = "tweets", .category = "streaming", .description = "Social posts: u64 id, handle, variable-length text, timestamp, like/retweet counts" },
    .{ .kind = .txs, .name = "blockchain_txs", .category = "streaming", .description = "Ledger transactions: 32-byte hash, 20-byte addresses, arbitrary-precision wei value, gas/nonce, timestamp" },
    .{ .kind = .ints, .name = "int_stream", .category = "structural", .description = "Flat stream of i64 — integer codec in isolation (no container framing)" },
    .{ .kind = .strings, .name = "string_stream", .category = "structural", .description = "Flat stream of short strings — framing/escaping in isolation" },
    .{ .kind = .nested, .name = "nested_doc", .category = "structural", .description = "Nested map/array documents — recursion + canonical map ordering" },
};

// Record counts, tuned so each payload lands in the ~100–400 KB range.
const N_QUOTES = 4000;
const N_GEO = 4000;
const N_TWEETS = 3000;
const N_TXS = 3000;
const N_INTS = 50000;
const N_STRINGS = 20000;
const N_NESTED = 2500;

// ---------------------------------------------------------------------------
// Deterministic data generation.
// ---------------------------------------------------------------------------

const symbols = [_][]const u8{ "AAPL", "MSFT", "GOOG", "AMZN", "TSLA", "NVDA", "META", "NFLX", "AMD", "INTC", "BRK.B", "JPM" };
const cities = [_][]const u8{ "London", "Tokyo", "New York", "Paris", "Sydney", "Berlin", "Toronto", "Singapore", "Dubai", "Mumbai", "Lagos", "Reykjavik" };
const words = [_][]const u8{ "the", "struple", "stream", "bytes", "order", "tuple", "encode", "decode", "lexicographic", "wire", "format", "ship", "build", "fast", "zero", "copy", "canonical", "exact", "decimal", "rocket", "today", "again", "memcmp", "tower" };

/// Decimal digits of `v` (v > 0), MSD-first, written into `buf`; returns the slice.
fn digitsOf(v: u64, buf: []u8) []u8 {
    if (v == 0) {
        buf[0] = 0;
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (x /= 10) {
        tmp[n] = @intCast(x % 10);
        n += 1;
    }
    for (0..n) |i| buf[i] = tmp[n - 1 - i];
    return buf[0..n];
}

fn genData(sa: std.mem.Allocator, rnd: std.Random) !Data {
    var d: Data = undefined;

    // Stock quotes — prices as exact 2-dp decimals (cents → digits, exp = -2).
    const quotes = try sa.alloc(Quote, N_QUOTES);
    var base_ts: i64 = 1_700_000_000_000_000; // 2023-ish, µs
    for (quotes) |*q| {
        q.symbol = symbols[rnd.uintLessThan(usize, symbols.len)];
        const bid_cents = rnd.intRangeAtMost(u64, 100, 500_000);
        const ask_cents = bid_cents + rnd.intRangeAtMost(u64, 1, 50);
        q.bid = try decFromCents(sa, bid_cents);
        q.ask = try decFromCents(sa, ask_cents);
        q.last = @as(f64, @floatFromInt(bid_cents)) / 100.0;
        q.volume = @intCast(rnd.intRangeAtMost(u64, 1, 10_000_000));
        base_ts += rnd.intRangeAtMost(i64, 1, 5_000_000);
        q.ts = base_ts;
    }
    d.quotes = quotes;

    // Geospatial points.
    const geo = try sa.alloc(Geo, N_GEO);
    base_ts = 1_700_000_000_000_000;
    for (geo) |*g| {
        g.lat = (rnd.float(f64) * 180.0) - 90.0;
        g.lon = (rnd.float(f64) * 360.0) - 180.0;
        g.elevation = (rnd.float(f64) * 3000.0) - 100.0;
        g.name = cities[rnd.uintLessThan(usize, cities.len)];
        base_ts += rnd.intRangeAtMost(i64, 1, 1_000_000);
        g.ts = base_ts;
    }
    d.geo = geo;

    // Tweets — variable-length text built from a small word table.
    const tweets = try sa.alloc(Tweet, N_TWEETS);
    base_ts = 1_700_000_000_000_000;
    for (tweets, 0..) |*t, i| {
        t.id = rnd.int(u64);
        t.user = try std.fmt.allocPrint(sa, "@user{d}", .{1000 + (i % 9000)});
        const wc = rnd.intRangeAtMost(usize, 4, 24);
        var text = std.ArrayList(u8).init(sa);
        for (0..wc) |w| {
            if (w != 0) try text.append(' ');
            try text.appendSlice(words[rnd.uintLessThan(usize, words.len)]);
        }
        t.text = try text.toOwnedSlice();
        base_ts += rnd.intRangeAtMost(i64, 1, 2_000_000);
        t.created_at = base_ts;
        t.likes = @intCast(rnd.intRangeAtMost(u64, 0, 500_000));
        t.retweets = @intCast(rnd.intRangeAtMost(u64, 0, 50_000));
    }
    d.tweets = tweets;

    // Blockchain transactions — half fixed wide-int values, half big-int (256-bit).
    const txs = try sa.alloc(Tx, N_TXS);
    base_ts = 1_700_000_000_000_000;
    for (txs) |*x| {
        x.height = @intCast(rnd.intRangeAtMost(u64, 1, 20_000_000));
        rnd.bytes(&x.tx_hash);
        rnd.bytes(&x.from);
        rnd.bytes(&x.to);
        if (rnd.boolean()) {
            // Big value: 17–32 bytes, top byte forced nonzero → beyond i128.
            const len = rnd.intRangeAtMost(usize, 17, 32);
            const mag = try sa.alloc(u8, len);
            rnd.bytes(mag);
            if (mag[0] == 0) mag[0] = 1;
            x.value_be = mag;
            x.value_big = true;
        } else {
            // Small value: 1–15 bytes → fits the i128 fixed path.
            const len = rnd.intRangeAtMost(usize, 1, 15);
            const mag = try sa.alloc(u8, len);
            rnd.bytes(mag);
            if (mag[0] == 0) mag[0] = 1;
            x.value_be = mag;
            x.value_big = false;
        }
        x.gas = @intCast(rnd.intRangeAtMost(u64, 21_000, 5_000_000));
        x.nonce = @intCast(rnd.intRangeAtMost(u64, 0, 1_000_000));
        base_ts += rnd.intRangeAtMost(i64, 1, 15_000_000);
        x.ts = base_ts;
    }
    d.txs = txs;

    // Integer stream.
    const ints = try sa.alloc(i64, N_INTS);
    for (ints) |*v| v.* = rnd.int(i64);
    d.ints = ints;

    // String stream — short tokens.
    const strings = try sa.alloc([]const u8, N_STRINGS);
    for (strings) |*s| {
        const a = words[rnd.uintLessThan(usize, words.len)];
        const b = words[rnd.uintLessThan(usize, words.len)];
        s.* = try std.fmt.allocPrint(sa, "{s}_{s}{d}", .{ a, b, rnd.uintLessThan(u32, 1000) });
    }
    d.strings = strings;

    // Nested documents.
    const nested = try sa.alloc(Nested, N_NESTED);
    for (nested, 0..) |*n, i| {
        n.uid = @intCast(i);
        n.name = words[rnd.uintLessThan(usize, words.len)];
        n.active = rnd.boolean();
        n.scores = .{
            @intCast(rnd.intRangeAtMost(u64, 0, 100)),
            @intCast(rnd.intRangeAtMost(u64, 0, 100)),
            @intCast(rnd.intRangeAtMost(u64, 0, 100)),
        };
    }
    d.nested = nested;

    return d;
}

fn decFromCents(sa: std.mem.Allocator, cents: u64) !Dec {
    var buf: [20]u8 = undefined;
    const ds = digitsOf(cents, &buf);
    const owned = try sa.dupe(u8, ds);
    return .{ .digits = owned, .exp = -2 };
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `main` is reset by the caller each iteration;
// `scratch` frames one record at a time; `arena` backs the nested-doc map entries.
// ---------------------------------------------------------------------------

fn encodeOnce(kind: PKind, d: *const Data, out: *Packer, scratch: *Packer, arena: *std.heap.ArenaAllocator) !void {
    switch (kind) {
        .quotes => for (d.quotes) |q| {
            scratch.reset();
            try scratch.appendString(q.symbol);
            try scratch.appendDecimal(false, q.bid.digits, q.bid.exp);
            try scratch.appendDecimal(false, q.ask.digits, q.ask.exp);
            try scratch.appendF64(q.last);
            try scratch.appendInt(q.volume);
            try scratch.appendTimestamp(q.ts);
            try out.appendArray(scratch.bytes());
        },
        .geo => for (d.geo) |g| {
            scratch.reset();
            try scratch.appendF64(g.lat);
            try scratch.appendF64(g.lon);
            try scratch.appendF64(g.elevation);
            try scratch.appendString(g.name);
            try scratch.appendTimestamp(g.ts);
            try out.appendArray(scratch.bytes());
        },
        .tweets => for (d.tweets) |t| {
            scratch.reset();
            try scratch.appendUint(t.id);
            try scratch.appendString(t.user);
            try scratch.appendString(t.text);
            try scratch.appendTimestamp(t.created_at);
            try scratch.appendInt(t.likes);
            try scratch.appendInt(t.retweets);
            try out.appendArray(scratch.bytes());
        },
        .txs => for (d.txs) |x| {
            scratch.reset();
            try scratch.appendInt(x.height);
            try scratch.appendBytes(&x.tx_hash);
            try scratch.appendBytes(&x.from);
            try scratch.appendBytes(&x.to);
            if (x.value_big) {
                try scratch.appendBigInt(false, x.value_be);
            } else {
                var v: i128 = 0;
                for (x.value_be) |b| v = (v << 8) | b;
                try scratch.appendI128(v);
            }
            try scratch.appendInt(x.gas);
            try scratch.appendInt(x.nonce);
            try scratch.appendTimestamp(x.ts);
            try out.appendArray(scratch.bytes());
        },
        .ints => for (d.ints) |v| try out.appendInt(v),
        .strings => for (d.strings) |s| try out.appendString(s),
        .nested => for (d.nested) |n| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            // user sub-map
            var user = Packer.init(a);
            const user_entries = [_][2][]const u8{
                .{ try encStr(a, "id"), try encInt(a, n.uid) },
                .{ try encStr(a, "name"), try encStr(a, n.name) },
            };
            try user.appendMap(&user_entries);
            // scores array
            var scores_inner = Packer.init(a);
            for (n.scores) |sc| try scores_inner.appendInt(sc);
            var scores_arr = Packer.init(a);
            try scores_arr.appendArray(scores_inner.bytes());
            // top-level map (appendMap sorts by encoded key, so order here is free)
            const entries = [_][2][]const u8{
                .{ try encStr(a, "active"), try encBool(a, n.active) },
                .{ try encStr(a, "scores"), scores_arr.bytes() },
                .{ try encStr(a, "user"), user.bytes() },
            };
            try out.appendMap(&entries);
        },
    }
}

fn encStr(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var p = Packer.init(a);
    try p.appendString(s);
    return p.bytes();
}
fn encInt(a: std.mem.Allocator, v: i64) ![]const u8 {
    var p = Packer.init(a);
    try p.appendInt(v);
    return p.bytes();
}
fn encBool(a: std.mem.Allocator, v: bool) ![]const u8 {
    var p = Packer.init(a);
    try p.appendBool(v);
    return p.bytes();
}

/// Record count for a payload (drives the per-record throughput figure).
fn recordCount(kind: PKind, d: *const Data) usize {
    return switch (kind) {
        .quotes => d.quotes.len,
        .geo => d.geo.len,
        .tweets => d.tweets.len,
        .txs => d.txs.len,
        .ints => d.ints.len,
        .strings => d.strings.len,
        .nested => d.nested.len,
    };
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing).
// ---------------------------------------------------------------------------

fn walk(arena: std.mem.Allocator, buf: []const u8) !void {
    var r = Reader.init(buf);
    while (try r.next()) |el| {
        switch (el) {
            .nil, .undef => {},
            .boolean => |b| g_sink +%= @intFromBool(b),
            .int => |v| g_sink +%= @as(u64, @bitCast(@as(i64, @truncate(v)))),
            .big_int => |bi| g_sink +%= bi.mag_stored.len,
            .float32 => |f| g_sink +%= @as(u32, @bitCast(f)),
            .float64 => |f| g_sink +%= @as(u64, @bitCast(f)),
            .decimal => |dc| g_sink +%= dc.coeff_stored.len +% @as(u64, @bitCast(dc.adj_exp)),
            .timestamp => |ts| g_sink +%= @as(u64, @bitCast(ts)),
            .uuid => |u| g_sink +%= u[0],
            .string, .bytes => |s| {
                g_sink +%= s.len;
                if (s.len > 0) g_sink +%= s[0];
            },
            .array, .map, .set => |framed| {
                // Escape-free bodies sub-read zero-copy; otherwise unescape in a
                // single pass into a buffer sized to the framed length (the
                // unescaped length is always ≤ that), skipping the separate
                // hasEscapes/unescapedLen scans and the per-container alloc.
                if (struple.hasEscapes(framed)) {
                    const ubuf = try arena.alloc(u8, framed.len);
                    try walk(arena, struple.unescapeInto(framed, ubuf));
                } else {
                    try walk(arena, framed);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

const Stats = struct {
    ns_per_op: f64,
    bytes: usize,
    records: usize,

    fn mbPerSec(self: Stats) f64 {
        return (@as(f64, @floatFromInt(self.bytes)) / self.ns_per_op) * 1000.0; // bytes/ns → MB/s
    }
    fn nsPerRecord(self: Stats) f64 {
        return self.ns_per_op / @as(f64, @floatFromInt(self.records));
    }
    fn mRecordsPerSec(self: Stats) f64 {
        return (@as(f64, @floatFromInt(self.records)) / self.ns_per_op) * 1000.0; // rec/ns → Mrec/s
    }
};

const target_trial_ns: u64 = 100 * std.time.ns_per_ms;
const n_trials = 9;

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

fn benchEncode(kind: PKind, d: *const Data, gpa: std.mem.Allocator, canonical_len: usize) !Stats {
    var out = Packer.init(gpa);
    defer out.deinit();
    var scratch = Packer.init(gpa);
    defer scratch.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const runOnce = struct {
        fn call(k: PKind, dd: *const Data, m: *Packer, sc: *Packer, ar: *std.heap.ArenaAllocator) !void {
            m.reset();
            try encodeOnce(k, dd, m, sc, ar);
            g_sink +%= m.bytes().len;
        }
    }.call;

    // Warm up (also grows the retained buffers to steady state).
    var i: usize = 0;
    while (i < 5) : (i += 1) try runOnce(kind, d, &out, &scratch, &arena);

    // Calibrate iteration count to ~target_trial_ns.
    var timer = try std.time.Timer.start();
    try runOnce(kind, d, &out, &scratch, &arena);
    const one = @max(timer.read(), 1);
    const iters: usize = @max(1, target_trial_ns / one);

    var trials: [n_trials]f64 = undefined;
    for (&trials) |*slot| {
        timer.reset();
        var j: usize = 0;
        while (j < iters) : (j += 1) try runOnce(kind, d, &out, &scratch, &arena);
        slot.* = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
    }
    return .{ .ns_per_op = median(&trials), .bytes = canonical_len, .records = recordCount(kind, d) };
}

fn benchDecode(kind: PKind, d: *const Data, gpa: std.mem.Allocator, bytes: []const u8) !Stats {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const runOnce = struct {
        fn call(ar: *std.heap.ArenaAllocator, b: []const u8) !void {
            _ = ar.reset(.retain_capacity);
            try walk(ar.allocator(), b);
        }
    }.call;

    var i: usize = 0;
    while (i < 5) : (i += 1) try runOnce(&arena, bytes);

    var timer = try std.time.Timer.start();
    try runOnce(&arena, bytes);
    const one = @max(timer.read(), 1);
    const iters: usize = @max(1, target_trial_ns / one);

    var trials: [n_trials]f64 = undefined;
    for (&trials) |*slot| {
        timer.reset();
        var j: usize = 0;
        while (j < iters) : (j += 1) try runOnce(&arena, bytes);
        slot.* = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
    }
    return .{ .ns_per_op = median(&trials), .bytes = bytes.len, .records = recordCount(kind, d) };
}

/// Build the canonical bytes for a payload once (for size, sha256, and as the
/// decode input).
fn buildCanonical(kind: PKind, d: *const Data, gpa: std.mem.Allocator) ![]u8 {
    var out = Packer.init(gpa);
    defer out.deinit();
    var scratch = Packer.init(gpa);
    defer scratch.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try encodeOnce(kind, d, &out, &scratch, &arena);
    return gpa.dupe(u8, out.bytes());
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

const Result = struct {
    meta: PayloadMeta,
    enc: Stats,
    dec: Stats,
    sha_hex: [64]u8,
};

pub fn main() !void {
    // A production-grade allocator (fast malloc/free): the codec makes transient
    // per-call allocations (decimal scratch, map index), and a debugging allocator
    // would mis-attribute its own overhead to those paths.
    const gpa = std.heap.c_allocator;

    var setup_arena = std.heap.ArenaAllocator.init(gpa);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    var prng = std.Random.DefaultPrng.init(0x57_72_75_70_6c_65_2a); // "Wruple*"
    const rnd = prng.random();
    const data = try genData(sa, rnd);

    var results = std.ArrayList(Result).init(gpa);
    defer results.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("struple benchmark (Zig reference, ReleaseFast)\n\n", .{});

    var total_bytes: usize = 0;
    for (payloads) |meta| {
        const bytes = try buildCanonical(meta.kind, &data, gpa);
        defer gpa.free(bytes);
        total_bytes += bytes.len;

        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &sha, .{});

        const enc = try benchEncode(meta.kind, &data, gpa, bytes.len);
        const dec = try benchDecode(meta.kind, &data, gpa, bytes);

        try results.append(.{ .meta = meta, .enc = enc, .dec = dec, .sha_hex = std.fmt.bytesToHex(sha, .lower) });

        try stdout.print("  {s:<16} {d:>6} rec   enc {d:>7.2} Mrec/s {d:>6.0} MB/s   dec {d:>7.2} Mrec/s {d:>6.0} MB/s\n", .{
            meta.name, enc.records, enc.mRecordsPerSec(), enc.mbPerSec(), dec.mRecordsPerSec(), dec.mbPerSec(),
        });
    }

    const host = hostLabel(gpa) catch try gpa.dupe(u8, "unknown");
    defer gpa.free(host);

    try writeBenchmarksMd(gpa, results.items, host, total_bytes);
    try writePayloadsJson(gpa, results.items);
    try writeResultsJson(gpa, results.items, host);
    try emitData(gpa, &data);

    try stdout.print("\nWrote BENCHMARKS.md, bench/payloads.json, bench/results/zig.json, bench/data/*.json\n", .{});
    try stdout.print("(sink {x})\n", .{g_sink});
}

fn hostLabel(gpa: std.mem.Allocator) ![]u8 {
    const text = std.fs.cwd().readFileAlloc(gpa, "/proc/cpuinfo", 1 << 20) catch return error.NoCpuInfo;
    defer gpa.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |c| {
                return gpa.dupe(u8, std.mem.trim(u8, line[c + 1 ..], " \t"));
            }
        }
    }
    return error.NoCpuInfo;
}

fn writeBenchmarksMd(gpa: std.mem.Allocator, results: []const Result, host: []const u8, total_bytes: usize) !void {
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(
        \\# struple benchmarks
        \\
        \\Encode (build a stream from in-memory records) and decode (walk a stream,
        \\touching every value) throughput, measured per workload. These are the
        \\**Zig reference** numbers; the other eleven ports run the same workloads and
        \\are added as they land (see [`bench/README.md`](bench/README.md)).
        \\
        \\**Mrec/s** (millions of records per second) is the headline figure — how many
        \\quotes, points, tweets, transactions, or items move through the codec each
        \\second. MB/s is shown alongside for the bandwidth view.
        \\
        \\All figures are **single-threaded (per core)**. struple encodes/decodes each
        \\record and stream independently, so the work is embarrassingly parallel —
        \\aggregate throughput scales ~linearly with cores (e.g. ~20M quotes/s/core ×
        \\16 cores ≈ 300M+ quotes/s on this host).
        \\
        \\> Numbers are machine-specific — treat them as relative, not absolute. What
        \\> matters across ports is the *shape*: which workloads are cheap, which are
        \\> dominated by framing/escaping, and how the ports compare on the same bytes.
        \\
        \\
    );
    try w.print("**Host:** {s} · **Build:** Zig ReleaseFast, single-threaded · **Total corpus:** {d:.1} KB\n\n", .{ host, @as(f64, @floatFromInt(total_bytes)) / 1024.0 });

    try w.writeAll("## Streaming workloads\n\n");
    try writeTable(w, results, "streaming");
    try w.writeAll("\n## Structural micro-benchmarks\n\n");
    try writeTable(w, results, "structural");

    try w.writeAll(
        \\
        \\## Method
        \\
        \\- **ReleaseFast**, deterministic data (fixed PRNG seed).
        \\- Per `(payload, op)`: 5 warm-up runs, auto-calibrate iteration count to a
        \\  ~100 ms trial, then 9 trials — the **median** ns/op is reported.
        \\- A global checksum sink consumes every result so the optimizer can't elide
        \\  the work. Steady-state buffers (encoder output, decoder unescape arena)
        \\  retain capacity, so figures reflect codec compute, not allocator warm-up.
        \\- **Encode** = build the framed stream from prepared in-memory records.
        \\  **Decode** = walk the whole stream, descending and unescaping every
        \\  container body and touching every scalar.
        \\
        \\Regenerate with `zig build bench`.
        \\
    );

    try std.fs.cwd().writeFile(.{ .sub_path = "BENCHMARKS.md", .data = buf.items });
}

fn writeTable(w: anytype, results: []const Result, category: []const u8) !void {
    try w.writeAll("| workload | size | records | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |\n");
    try w.writeAll("|---|--:|--:|--:|--:|--:|--:|\n");
    for (results) |r| {
        if (!std.mem.eql(u8, r.meta.category, category)) continue;
        try w.print("| `{s}` | {d:.0} KB | {d} | **{d:.2}** | {d:.0} | **{d:.2}** | {d:.0} |\n", .{
            r.meta.name,
            @as(f64, @floatFromInt(r.enc.bytes)) / 1024.0,
            r.enc.records,
            r.enc.mRecordsPerSec(),
            r.enc.mbPerSec(),
            r.dec.mRecordsPerSec(),
            r.dec.mbPerSec(),
        });
    }
}

fn writePayloadsJson(gpa: std.mem.Allocator, results: []const Result) !void {
    std.fs.cwd().makePath("bench") catch {};
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(
        \\{
        \\  "_comment": "Shared benchmark workload manifest. Generated by `zig build bench`. Each language reproduces these payloads (same record schema + fixed PRNG semantics) and must match byte_len and sha256 before its throughput counts.",
        \\  "payloads": [
        \\
    );
    for (results, 0..) |r, idx| {
        try w.print(
            \\    {{
            \\      "name": "{s}",
            \\      "category": "{s}",
            \\      "description": "{s}",
            \\      "records": {d},
            \\      "byte_len": {d},
            \\      "sha256": "{s}"
            \\    }}{s}
            \\
        , .{
            r.meta.name,
            r.meta.category,
            r.meta.description,
            r.enc.records,
            r.enc.bytes,
            r.sha_hex,
            if (idx + 1 == results.len) "" else ",",
        });
    }
    try w.writeAll(
        \\  ]
        \\}
        \\
    );

    try std.fs.cwd().writeFile(.{ .sub_path = "bench/payloads.json", .data = buf.items });
}

// ---------------------------------------------------------------------------
// Shared workload data emission. Each port reads bench/data/<name>.json and
// rebuilds the records via its own appendX calls, then must reproduce the
// payload's sha256 (byte-identity). All fields are typed strings so any JSON
// library reads them identically across languages:
//   - floats: 16 hex digits of the IEEE-754 bits (exact; no round-trip risk)
//   - ints/u64/timestamps: decimal strings
//   - big-int / fixed-wide value: hex big-endian magnitude
//   - decimals: significant digits (MSD-first) + base-10 exponent
//   - bytes: hex
// See bench/README.md for the per-payload field schema.
// ---------------------------------------------------------------------------

fn emitData(gpa: std.mem.Allocator, d: *const Data) !void {
    std.fs.cwd().makePath("bench/data") catch {};

    // int_stream: ["<i64>", ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.ints, 0..) |v, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("\"{d}\"", .{v});
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/int_stream.json", .data = b.items });
    }

    // string_stream: ["<str>", ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.strings, 0..) |s, i| {
            if (i != 0) try w.writeByte(',');
            try jsonStr(w, s);
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/string_stream.json", .data = b.items });
    }

    // stock_quotes: [["sym","<bidDigits>","<bidExp>","<askDigits>","<askExp>","<lastF64hex>","<vol>","<ts>"], ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.quotes, 0..) |q, i| {
            if (i != 0) try w.writeAll(",\n");
            try w.writeByte('[');
            try jsonStr(w, q.symbol);
            try w.writeByte(',');
            try emitDigits(w, q.bid.digits);
            try w.print(",\"{d}\",", .{q.bid.exp});
            try emitDigits(w, q.ask.digits);
            try w.print(",\"{d}\",", .{q.ask.exp});
            try w.print("\"{x:0>16}\",\"{d}\",\"{d}\"]", .{ @as(u64, @bitCast(q.last)), q.volume, q.ts });
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/stock_quotes.json", .data = b.items });
    }

    // geo_points: [["<lathex>","<lonhex>","<elevhex>","name","<ts>"], ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.geo, 0..) |g, i| {
            if (i != 0) try w.writeAll(",\n");
            try w.print("[\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\",", .{
                @as(u64, @bitCast(g.lat)), @as(u64, @bitCast(g.lon)), @as(u64, @bitCast(g.elevation)),
            });
            try jsonStr(w, g.name);
            try w.print(",\"{d}\"]", .{g.ts});
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/geo_points.json", .data = b.items });
    }

    // tweets: [["<id_u64>","user","text","<created>","<likes>","<rt>"], ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.tweets, 0..) |t, i| {
            if (i != 0) try w.writeAll(",\n");
            try w.print("[\"{d}\",", .{t.id});
            try jsonStr(w, t.user);
            try w.writeByte(',');
            try jsonStr(w, t.text);
            try w.print(",\"{d}\",\"{d}\",\"{d}\"]", .{ t.created_at, t.likes, t.retweets });
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/tweets.json", .data = b.items });
    }

    // blockchain_txs: [["<height>","<hashhex>","<fromhex>","<tohex>","big|fix","<valHex>","<gas>","<nonce>","<ts>"], ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.txs, 0..) |x, i| {
            if (i != 0) try w.writeAll(",\n");
            try w.print("[\"{d}\",", .{x.height});
            try emitHex(w, &x.tx_hash);
            try w.writeByte(',');
            try emitHex(w, &x.from);
            try w.writeByte(',');
            try emitHex(w, &x.to);
            try w.print(",\"{s}\",", .{if (x.value_big) "big" else "fix"});
            try emitHex(w, x.value_be);
            try w.print(",\"{d}\",\"{d}\",\"{d}\"]", .{ x.gas, x.nonce, x.ts });
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/blockchain_txs.json", .data = b.items });
    }

    // nested_doc: [["<active 0|1>","<uid>","name","<s0>","<s1>","<s2>"], ...]
    {
        var b = std.ArrayList(u8).init(gpa);
        defer b.deinit();
        const w = b.writer();
        try w.writeByte('[');
        for (d.nested, 0..) |n, i| {
            if (i != 0) try w.writeAll(",\n");
            try w.print("[\"{d}\",\"{d}\",", .{ @intFromBool(n.active), n.uid });
            try jsonStr(w, n.name);
            try w.print(",\"{d}\",\"{d}\",\"{d}\"]", .{ n.scores[0], n.scores[1], n.scores[2] });
        }
        try w.writeAll("]\n");
        try std.fs.cwd().writeFile(.{ .sub_path = "bench/data/nested_doc.json", .data = b.items });
    }
}

/// Per-language results in the shared schema (merged into BENCHMARKS.md by
/// bench/merge.py). The Zig reference is always byte-canonical, so sha256_ok=true.
fn writeResultsJson(gpa: std.mem.Allocator, results: []const Result, host: []const u8) !void {
    std.fs.cwd().makePath("bench/results") catch {};
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\n  \"lang\": \"Zig\",\n  \"host\": ");
    try jsonStr(w, host);
    try w.writeAll(",\n  \"payloads\": {\n");
    for (results, 0..) |r, idx| {
        try w.print(
            \\    "{s}": {{ "enc_mrec_s": {d:.3}, "enc_mb_s": {d:.1}, "dec_mrec_s": {d:.3}, "dec_mb_s": {d:.1}, "sha256_ok": true }}{s}
            \\
        , .{
            r.meta.name,
            r.enc.mRecordsPerSec(),
            r.enc.mbPerSec(),
            r.dec.mRecordsPerSec(),
            r.dec.mbPerSec(),
            if (idx + 1 == results.len) "" else ",",
        });
    }
    try w.writeAll("  }\n}\n");
    try std.fs.cwd().writeFile(.{ .sub_path = "bench/results/zig.json", .data = buf.items });
}

/// A JSON string with the significant decimal digits (each 0–9) as ASCII.
fn emitDigits(w: anytype, digits: []const u8) !void {
    try w.writeByte('"');
    for (digits) |dig| try w.writeByte('0' + dig);
    try w.writeByte('"');
}

fn emitHex(w: anytype, data: []const u8) !void {
    try w.writeByte('"');
    for (data) |byte| try w.print("{x:0>2}", .{byte});
    try w.writeByte('"');
}

fn jsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
