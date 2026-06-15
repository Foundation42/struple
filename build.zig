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
}
