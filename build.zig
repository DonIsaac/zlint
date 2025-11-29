const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Module = std.Build.Module;
const codegen = @import("tasks/codegen_task.zig");

pub fn build(b: *std.Build) void {
    // default to -freference-trace, but respect -fnoreference-trace
    if (b.reference_trace == null) {
        b.reference_trace = 256;
    }

    // cli options
    const single_threaded = b.option(bool, "single-threaded", "Build a single-threaded executable");
    const debug_release = b.option(bool, "debug-release", "Build with debug info in release mode") orelse false;
    // const version = b.option([]const u8, "version", "ZLint version") orelse "0.0.0";

    var l = Linker.init(b);
    defer l.deinit();
    if (debug_release) {
        l.optimize = .ReleaseSafe;
    }

    // dependencies
    l.dependency("chameleon", .{});
    // l.dependency("smart-pointers", .{});
    {
        const dep = l.b.dependency("smart_pointers", .{});
        l.dependencies.put(b.allocator, "smart-pointers", dep) catch @panic("OOM");
        l.modules.put(b.allocator, "smart-pointers", dep.module("smart-pointers")) catch @panic("OOM");
    }
    l.devDependency("recover", "recover", .{});

    // modules
    l.createModule("util", .{
        .root_source_file = b.path("src/util.zig"),
    });

    // artifacts
    const zlint = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .single_threaded = single_threaded,
        .optimize = l.optimize,
        .target = l.target,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) .sync else null,
        .omit_frame_pointer = if (debug_release) false else null,
        .strip = if (debug_release) false else null,
    });
    // var lib = b.addStaticLibrary(.{
    //     .name = "zlint",
    //     .root_source_file = b.path("src/root.zig"),
    //     .single_threaded = single_threaded,
    //     .target = l.target,
    //     .optimize = l.optimize,
    //     .error_tracing = if (debug_release) true else null,
    //     .unwind_tables = if (debug_release) true else null,
    //     .omit_frame_pointer = if (debug_release) false else null,
    //     .strip = if (debug_release) false else null,
    // });
    // const zlint: *Build.Module = lib.root_module;
    const lib = b.addLibrary(.{
        .name = "zlint",
        .root_module = zlint,
        .linkage = .static,
    });
    l.link(zlint, false, .{});
    b.modules.put(b.dupe("zlint"), zlint) catch @panic("OOM");
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zlint",
        .root_module = zlint,
    });
    // exe.want_lto
    // l.link(exe.root_module else &exe.root_module, false, .{});
    b.installArtifact(exe);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/test_e2e.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) .sync else null,
        .strip = if (debug_release) false else null,
    });

    const e2e = b.addExecutable(.{
        .name = "test-e2e",
        .root_module = e2e_mod,
    });

    // util and chameleon omitted
    e2e_mod.addImport("zlint", zlint);
    l.link(e2e_mod, true, .{ "smart-pointers", "recover" });

    b.installArtifact(e2e);

    const test_exe = b.addTest(.{
        .name = "test-e2e",
        .root_module = zlint,
    });
    b.installArtifact(test_exe);

    const test_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    const test_utils = b.addTest(.{
        .name = "test-utils",
        .root_module = test_utils_mod,
    });
    b.installArtifact(test_utils);

    // steps

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run = b.step("run", "Run zlint from the current directory");
    run.dependOn(&run_exe.step);

    // zig build test
    {
        const run_exe_tests = b.addRunArtifact(test_exe);
        const run_utils_tests = b.addRunArtifact(test_utils);
        const unit_step = b.step("test", "Run unit tests");
        unit_step.dependOn(&run_exe_tests.step);
        unit_step.dependOn(&run_utils_tests.step);

        const run_e2e = b.addRunArtifact(e2e);
        const e2e_step = b.step("test-e2e", "Run e2e tests");
        e2e_step.dependOn(&run_e2e.step);

        const test_all_step = b.step("test-all", "Run all tests");
        test_all_step.dependOn(&run_exe_tests.step);
        test_all_step.dependOn(&run_utils_tests.step);
        test_all_step.dependOn(&run_e2e.step);
    }

    // zig build (docs, confgen, codegen
    var ct = codegen.CodegenTasks{
        .b = b,
        .optimize = l.optimize,
        .target = l.target,
        .zlint = zlint,
    };
    {
        const config_step = ct.config();
        const docs_step = ct.docs();

        const lib_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });
        lib_docs.step.dependOn(docs_step);

        const codegen_step = b.step("codegen", "Generate all codegen artifacts");
        codegen_step.dependOn(config_step);
        codegen_step.dependOn(docs_step);
    }

    // // check is down here because it's weird. We create mocks of each artifacts
    // // that never get installed. This (allegedly) skips llvm emit.
    // {
    //     const check_exe = b.addExecutable(.{ .name = "zlint", .root_source_file = b.path("src/main.zig"), .target = l.target });
    //     // mock library so zlint module is checked
    //     const check_lib = b.addStaticLibrary(.{ .name = "zlint", .root_source_file = b.path("src/root.zig"), .target = l.target, .optimize = l.optimize });
    //     const check_test_lib = b.addTest(.{ .root_source_file = b.path("src/root.zig") });
    //     const check_test_exe = b.addTest(.{ .root_source_file = b.path("src/main.zig") });
    //     const check_e2e = b.addExecutable(.{ .name = "test-e2e", .root_source_file = b.path("test/test_e2e.zig"), .target = l.target });
    //     l.link(check_e2e.root_module, true, .{"recover"});
    //     // tasks
    //     const check_docgen = ct.docgen();
    //     const check_confgen = ct.confgen();

    //     // these compilation targets depend on zlint as a module
    //     const needs_zlint = .{ check_e2e, check_docgen, check_confgen };
    //     inline for (needs_zlint) |exe_to_check| {
    //         exe_to_check.root_module.addImport("zlint", zlint);
    //     }

    //     const check = b.step("check", "Check for semantic errors");
    //     const substeps = .{
    //         check_exe,
    //         check_lib,
    //         check_test_lib,
    //         check_test_exe,
    //         check_e2e,
    //         check_docgen,
    //         check_confgen,
    //     };
    //     inline for (substeps) |c| {
    //         l.link(c.root_module, false, .{});
    //         check.dependOn(&c.step);
    //     }
    // }
    const check = b.step("check", "Check for semantic errors");
    check.dependOn(&lib.step);
    check.dependOn(&ct.docgen().step);
    check.dependOn(&ct.confgen().step);
    check.dependOn(&e2e.step);
}

/// Stores modules and dependencies. Use `link` to register them as imports.
const Linker = struct {
    b: *Build,
    options: *Build.Step.Options,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependencies: std.StringHashMapUnmanaged(*Build.Dependency) = .{},
    modules: std.StringHashMapUnmanaged(*Module) = .{},
    dev_modules: std.StringHashMapUnmanaged(*Module) = .{},

    fn init(b: *Build) Linker {
        var opts = b.addOptions();
        opts.addOption([]const u8, "version", b.option([]const u8, "version", "ZLint version") orelse "v0.0.0");
        var linker = Linker{
            .b = b,
            .options = opts,
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
        const opts_module = opts.createModule();
        linker.modules.put(b.allocator, "config", opts_module) catch @panic("OOM");

        return linker;
    }

    fn dependency(self: *Linker, comptime name: []const u8, options: anytype) void {
        const dep = self.b.dependency(name, options);
        self.dependencies.put(self.b.allocator, name, dep) catch @panic("OOM");
        self.modules.put(self.b.allocator, name, dep.module(name)) catch @panic("OOM");
    }

    fn devDependency(self: *Linker, comptime dep_name: []const u8, mod_name: []const u8, options: anytype) void {
        const dep = self.b.dependency(dep_name, options);
        self.dependencies.put(self.b.allocator, dep_name, dep) catch @panic("OOM");
        self.dev_modules.put(self.b.allocator, mod_name, dep.module(mod_name)) catch @panic("OOM");
    }

    fn addModule(self: *Linker, comptime name: []const u8, options: Module.CreateOptions) void {
        var opts = options;
        opts.target = opts.target orelse self.target;
        opts.optimize = opts.optimize orelse self.optimize;
        const mod = self.b.addModule(name, opts);
        self.modules.put(self.b.allocator, name, mod) catch @panic("OOM");
    }

    fn createModule(self: *Linker, comptime name: []const u8, options: Module.CreateOptions) void {
        var opts = options;
        opts.target = opts.target orelse self.target;
        opts.optimize = opts.optimize orelse self.optimize;
        const mod = self.b.createModule(opts);
        self.modules.put(self.b.allocator, name, mod) catch @panic("OOM");
    }

    /// Link a set of modules as imports. When `imports` is empty, all modules
    /// are linked.
    fn link(self: *Linker, mod: *Module, dev: bool, comptime imports: anytype) void {
        if (imports.len > 0) {
            inline for (imports) |import| {
                const dep = self.modules.get(import) orelse self.dev_modules.get(import) orelse @panic("Missing module: " ++ import);
                mod.addImport(import, dep);
            }
            return;
        }

        {
            var it = self.modules.iterator();
            while (it.next()) |ent| {
                const name = ent.key_ptr.*;
                const dep = ent.value_ptr.*;
                if (mod == dep) continue;
                mod.addImport(name, dep);
            }
        }

        if (dev) {
            var it = self.dev_modules.iterator();
            while (it.next()) |ent| {
                const name = ent.key_ptr.*;
                const dep = ent.value_ptr.*;
                if (mod == dep) continue;
                mod.addImport(name, dep);
            }
        }
    }

    fn deinit(self: *Linker) void {
        self.dependencies.deinit(self.b.allocator);
        self.modules.deinit(self.b.allocator);
    }
};
