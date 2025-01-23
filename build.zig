const std = @import("std");
const Build = std.Build;
const Module = std.Build.Module;

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
    l.dependency("smart-pointers", .{});
    l.devDependency("zig-recover", "recover", .{});

    // modules
    l.createModule("util", .{
        .root_source_file = b.path("src/util.zig"),
    });

    const zlint = b.addModule("zlint", .{
        .root_source_file = b.path("src/root.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    l.link(zlint, false, .{});

    // artifacts
    const exe = b.addExecutable(.{
        .name = "zlint",
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    l.link(&exe.root_module, false, .{});
    b.installArtifact(exe);

    const e2e = b.addExecutable(.{
        .name = "test-e2e",
        .root_source_file = b.path("test/test_e2e.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    // util and chameleon omitted
    e2e.root_module.addImport("zlint", zlint);
    l.link(&e2e.root_module, true, .{ "smart-pointers", "recover" });

    b.installArtifact(e2e);

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    l.link(&test_exe.root_module, true, .{});
    b.installArtifact(test_exe);

    const test_utils = b.addTest(.{
        .name = "test-utils",
        .root_source_file = b.path("src/util.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    b.installArtifact(test_utils);

    // steps

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run = b.step("run", "Run zlint from the current directory");
    run.dependOn(&run_exe.step);

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

    const docs_step = b.step("docs", "Generate documentation");
    const docs_rules_step = Tasks.generateRuleDocs(&l);
    docs_step.dependOn(docs_rules_step);

    const codegen = b.step("codegen", "Codegen");
    const confgen_task = Tasks.generateRulesConfig(&l);
    codegen.dependOn(confgen_task);

    // check is down here because it's weird. We create mocks of each artifacts
    // that never get installed. This (allegedly) skips llvm emit.
    {
        const check_exe = b.addExecutable(.{ .name = "zlint", .root_source_file = b.path("src/main.zig"), .target = l.target });
        // mock library so zlint module is checked
        const check_lib = b.addStaticLibrary(.{ .name = "zlint", .root_source_file = b.path("src/root.zig"), .target = l.target, .optimize = l.optimize });
        const check_test_lib = b.addTest(.{ .root_source_file = b.path("src/root.zig") });
        const check_test_exe = b.addTest(.{ .root_source_file = b.path("src/main.zig") });
        const check_e2e = b.addExecutable(.{ .name = "test-e2e", .root_source_file = b.path("test/test_e2e.zig"), .target = l.target });
        l.link(&check_e2e.root_module, true, .{"recover"});
        // tasks
        const check_docgen = b.addExecutable(.{ .name = "docgen", .root_source_file = b.path("tasks/docgen.zig"), .target = l.target });
        const check_confgen = b.addExecutable(.{ .name = "confgen", .root_source_file = b.path("tasks/confgen.zig"), .target = l.target });

        // these compilation targets depend on zlint as a module
        const needs_zlint = .{ check_e2e, check_docgen, check_confgen };
        inline for (needs_zlint) |exe_to_check| {
            exe_to_check.root_module.addImport("zlint", zlint);
        }

        const check = b.step("check", "Check for semantic errors");
        const substeps = .{
            check_exe,
            check_lib,
            check_test_lib,
            check_test_exe,
            check_e2e,
            check_docgen,
            check_confgen,
        };
        inline for (substeps) |c| {
            l.link(&c.root_module, false, .{});
            check.dependOn(&c.step);
        }
    }
}

const Tasks = struct {
    fn generateRuleDocs(l: *Linker) *Build.Step {
        const docgen_exe = l.b.addExecutable(.{
            .name = "docgen",
            .root_source_file = l.b.path("tasks/docgen.zig"),
            .target = l.target,
            .optimize = l.optimize,
        });
        const zlint = l.b.modules.get("zlint") orelse @panic("Missing module: zlint");
        docgen_exe.root_module.addImport("zlint", zlint);
        const docgen_run = l.b.addRunArtifact(docgen_exe);

        const bunx_prettier = Tasks.bunx(l, "prettier", &[_][]const u8{ "--write", "docs/rules/*.md" });
        bunx_prettier.step.dependOn(&docgen_run.step);

        const docgen = l.b.step("docs:rules", "Generate lint rule documentation");
        docgen.dependOn(&bunx_prettier.step);
        return docgen;
    }

    fn generateRulesConfig(l: *Linker) *Build.Step {
        const confgen_exe = l.b.addExecutable(.{
            .name = "confgen",
            .root_source_file = l.b.path("tasks/confgen.zig"),
            .target = l.target,
            .optimize = l.optimize,
        });
        const zlint = l.b.modules.get("zlint") orelse @panic("Missing module: zlint");
        confgen_exe.root_module.addImport("zlint", zlint);
        const confgen_run = l.b.addRunArtifact(confgen_exe);
        const confgen = l.b.step("codegen:rules-config", "Generate RulesConfig");
        confgen.dependOn(&confgen_run.step);
        return confgen;
    }
    fn bunx(l: *Linker, comptime cmd: []const u8, comptime args: []const []const u8) *Build.Step.Run {
        const b = l.b;
        return b.addSystemCommand(.{ "bunx", cmd } ++ args);
    }
    // fn generateLibDocs(l: *Linker) *Build.Step {
    //     const b = l.b;
    // }
    // fn formatDocs(l: *Linker) *Build.Step {
    //     const b = l.b;
    // }
};

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
