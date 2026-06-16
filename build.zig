const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public library module — depend on this as `struple`.
    const struple_mod = b.addModule("struple", .{
        .root_source_file = b.path("src/struple.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact (handy for C / FFI / WASM consumers later).
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "struple",
        .root_module = struple_mod,
    });
    b.installArtifact(lib);

    // Demo executable.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("struple", struple_mod);
    const exe = b.addExecutable(.{ .name = "struple-demo", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    // Tests: src/struple.zig pulls in the full suite from src/tests.zig.
    const tests = b.addTest(.{ .root_module = struple_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Conformance vector generator: writes conformance/vectors.json.
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/gen_vectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_mod.addImport("struple", struple_mod);
    const gen_exe = b.addExecutable(.{ .name = "gen-vectors", .root_module = gen_mod });
    const gen_run = b.addRunArtifact(gen_exe);
    gen_run.setCwd(b.path("."));
    const vectors_step = b.step("vectors", "Generate conformance/vectors.json");
    vectors_step.dependOn(&gen_run.step);

    // Benchmarks: always ReleaseFast (regardless of the global optimize mode) so
    // the numbers are meaningful. Writes BENCHMARKS.md + bench/payloads.json.
    const bench_struple = b.addModule("struple-bench-lib", .{
        .root_source_file = b.path("src/struple.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("struple", bench_struple);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    bench_exe.linkLibC(); // bench uses std.heap.c_allocator (fast malloc)
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.setCwd(b.path("."));
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast); writes BENCHMARKS.md + bench/payloads.json");
    bench_step.dependOn(&bench_run.step);
}
