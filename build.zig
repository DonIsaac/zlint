const std = @import("std");
const Build = std.Build;
const Module = std.Build.Module;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // default to -freference-trace, but respect -fnoreference-trace
    if (b.reference_trace == null) {
        b.reference_trace = 256;
    }

    // cli options
    const single_threaded = b.option(bool, "single-threaded", "Build a single-threaded executable");

    // dependencies
    const cham = b.dependency("chameleon", .{});
    const modcham = cham.module("chameleon");
    const sp = b.dependency("smart-pointers", .{ .target = target, .optimize = optimize });
    const libsp = sp.artifact("smart-pointers");
    const modsp = sp.module("smart-pointers");

    // modules
    const util = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .single_threaded = single_threaded,
        .target = target,
        .optimize = optimize,
    });
    const zlint = b.addModule("zlint", .{
        .root_source_file = b.path("src/root.zig"),
        .single_threaded = single_threaded,
        .target = target,
        .optimize = optimize,
    });
    zlint.addImport("util", util);
    zlint.addImport("smart-pointers", modsp);

    // artifacts
    const exe = b.addExecutable(.{
        .name = "zlint",
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("util", util);
    exe.root_module.addImport("smart-pointers", modsp);
    exe.root_module.addImport("chameleon", modcham);
    exe.linkLibrary(libsp);
    exe.installLibraryHeaders(libsp);
    b.installArtifact(exe);

    const e2e = b.addExecutable(.{
        .name = "test-e2e",
        .root_source_file = b.path("test/test_e2e.zig"),
        .single_threaded = single_threaded,
        .target = target,
        .optimize = optimize,
    });
    // util omitted
    e2e.root_module.addImport("zlint", zlint);
    e2e.root_module.addImport("smart-pointers", modsp);
    e2e.root_module.addImport("chameleon", modcham);
    e2e.linkLibrary(libsp);
    e2e.installLibraryHeaders(libsp);
    b.installArtifact(e2e);

    const unit = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = target,
        .optimize = optimize,
    });
    unit.root_module.addImport("util", util);
    unit.root_module.addImport("zlint", zlint);
    unit.root_module.addImport("smart-pointers", modsp);
    unit.root_module.addImport("chameleon", modcham);
    unit.linkLibrary(libsp);
    unit.installLibraryHeaders(libsp);
    b.installArtifact(unit);

    // steps

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run = b.step("run", "Run zlint from the current directory");
    run.dependOn(&run_exe.step);

    const run_tests = b.addRunArtifact(unit);
    const unit_step = b.step("test", "Run unit tests");
    unit_step.dependOn(&run_tests.step);

    const run_e2e = b.addRunArtifact(e2e);
    const e2e_step = b.step("test-e2e", "Run e2e tests");
    e2e_step.dependOn(&run_e2e.step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_tests.step);
    test_all_step.dependOn(&run_e2e.step);

    // check is down here because it's weird. We create mocks of each artifacts
    // that never get installed. This (allegedly) skips llvm emit.
    {
        const check_exe = b.addExecutable(.{ .name = "zlint", .root_source_file = b.path("src/main.zig"), .target = target });
        // mock library so zlint module is checked
        const check_lib = b.addStaticLibrary(.{ .name = "zlint", .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
        const check_unit = b.addTest(.{ .root_source_file = b.path("src/root.zig") });
        const check_e2e = b.addExecutable(.{ .name = "test-e2e", .root_source_file = b.path("test/test_e2e.zig"), .target = target });
        check_e2e.root_module.addImport("zlint", zlint);

        const check = b.step("check", "Check for semantic errors");
        inline for (.{ check_exe, check_lib, check_unit, check_e2e }) |c| {
            c.root_module.addImport("util", util);
            c.root_module.addImport("smart-pointers", modsp);
            c.root_module.addImport("chameleon", modcham);
            check.dependOn(&c.step);
        }
    }
}
