const std = @import("std");
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
    // Zig's self-hosted x86_64 backend (default for Debug on Linux) emits debug
    // info that kcov cannot map to source lines, yielding empty coverage. Force
    // the LLVM backend for coverage builds so kcov produces real reports.
    const coverage = b.option(bool, "coverage", "Build test binaries with the LLVM backend for kcov coverage") orelse false;
    const use_llvm: ?bool = if (coverage) true else null;
    // these are relative to the caller, so if we are a dependency, it will be relative to the depender
    const custom_rule_paths = b.option(
        []const Build.LazyPath,
        "custom_rules",
        "comma separated list of custom rule files. See https://donisaac.github.io/zlint/docs/configuration/custom-rules",
    ) orelse &.{};

    var l = Linker.init(b);
    defer l.deinit();
    if (debug_release) {
        l.optimize = .ReleaseSafe;
    }

    // dependencies
    l.dependency("chameleon", .{});
    {
        const dep = l.b.dependency("smart_pointers", .{});
        l.dependencies.put(b.allocator, "smart-pointers", dep) catch @panic("OOM");
        l.modules.put(b.allocator, "smart-pointers", dep.module("smart-pointers")) catch @panic("OOM");
    }
    l.devDependency("recover", "recover", .{});

    // modules
    l.createModule("util", .{
        .root_source_file = b.path("src/util.zig"),
        .single_threaded = single_threaded,
        .optimize = l.optimize,
        .target = l.target,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) .sync else null,
        .omit_frame_pointer = if (debug_release) false else null,
        .strip = if (debug_release) false else null,
    });
    l.modules.get("util").?.addImport("config", l.modules.get("config").?);

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
    const lib = b.addLibrary(.{
        .name = "zlint-lib",
        .root_module = zlint,
        .linkage = .static,
    });
    l.link(zlint, false, .{});
    b.modules.put(b.allocator, b.dupe("zlint"), zlint) catch @panic("OOM");
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .optimize = l.optimize,
        .target = l.target,
        .error_tracing = if (debug_release) true else null,
        .unwind_tables = if (debug_release) .sync else null,
        .omit_frame_pointer = if (debug_release) false else null,
        .strip = if (debug_release) false else null,
    });
    l.link(exe_mod, false, .{});
    // The CLI consumes the library as a module rather than re-including its
    // sources, so a custom rule's `@import("zlint")` refers to the same module
    // the exe was built from.
    exe_mod.addImport("zlint", zlint);
    zlint.addImport("zlint", zlint);

    const custom_rules_mod = b.createModule(.{
        // root_source_file set below
        .target = l.target,
        .optimize = l.optimize,
    });

    const custom_rules_header =
        \\pub const custom_rules = struct {
        \\
    ;
    const custom_rules_footer =
        \\};
        \\
    ;
    var custom_rules_bytes = std.Io.Writer.Allocating.initCapacity(
        b.allocator,
        custom_rules_header.len + custom_rules_footer.len + 1,
    ) catch @panic("OOM");
    defer custom_rules_bytes.deinit();

    custom_rules_bytes.writer.writeAll(custom_rules_header) catch @panic("OOM");

    var custom_rule_tests = std.ArrayListUnmanaged(*Build.Step.Compile).initCapacity(b.allocator, custom_rule_paths.len) catch @panic("OOM");
    defer custom_rule_tests.deinit(b.allocator);

    for (custom_rule_paths, 0..) |p, i| {
        // NOTE: never freed, we assume the build graph keeps a ref
        const name = std.fmt.allocPrint(b.allocator, "custom_rules_{d}", .{i}) catch @panic("OOM");
        const custom_rule_mod = b.createModule(.{
            .root_source_file = p,
            .target = l.target,
            .optimize = l.optimize,
        });
        custom_rule_mod.addImport("zlint", zlint);
        custom_rules_mod.addImport(name, custom_rule_mod);
        custom_rules_bytes.writer.print(
            \\    pub const {0s} = @import("{0s}");
            \\
        , .{name}) catch @panic("OOM");

        // Zig only collects `test` decls from a compilation's root module, so
        // each custom rule needs its own test artifact
        const custom_rule_test = b.addTest(.{
            .name = b.fmt("test-{s}", .{name}),
            .root_module = custom_rule_mod,
            .use_llvm = use_llvm,
        });
        b.installArtifact(custom_rule_test);
        custom_rule_tests.appendAssumeCapacity(custom_rule_test);
    }

    custom_rules_bytes.writer.writeAll(custom_rules_footer) catch @panic("OOM");

    const custom_rules_files = b.addWriteFiles();
    const custom_rules_mod_file = custom_rules_files.add("custom_rules.zig", custom_rules_bytes.written());
    custom_rules_mod.root_source_file = custom_rules_mod_file;
    zlint.addImport("custom_rules", custom_rules_mod);

    // Reached from a consuming package via `addCustomLintRulesTest`.
    const custom_rules_test_step = b.step("test-custom-rules", "Run tests for custom lint rules");
    for (custom_rule_tests.items) |custom_rule_test| {
        custom_rules_test_step.dependOn(&b.addRunArtifact(custom_rule_test).step);
    }

    // zig build docs, zig build config
    var ct = codegen.CodegenTasks{
        .b = b,
        .optimize = l.optimize,
        .target = l.target,
        .zlint = zlint,
    };

    {
        _ = ct.config();
        const docs_step = ct.docs();
        var lib_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });
        docs_step.dependOn(&lib_docs.step);
    }

    const exe = b.addExecutable(.{
        .name = "zlint",
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);

    // exe.want_lto
    // l.link(exe.root_module else &exe.root_module, false, .{});

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
        .use_llvm = use_llvm,
    });

    // util omitted
    e2e_mod.addImport("zlint", zlint);
    e2e_mod.addImport("chameleon", l.dependencies.get("chameleon").?.module("chameleon"));
    l.link(e2e_mod, true, .{ "smart-pointers", "recover", "chameleon" });

    b.installArtifact(e2e);

    const test_lib = b.addTest(.{
        .name = "test",
        .root_module = zlint,
        .use_llvm = use_llvm,
    });
    // Test fixtures live outside `src/`, so they must be registered as imports
    // before unit tests can `@embedFile` them.
    inline for (.{"unresolved_reference.zig"}) |fixture| {
        test_lib.root_module.addAnonymousImport("fixtures/" ++ fixture, .{
            .root_source_file = b.path("test/fixtures/simple/pass/" ++ fixture),
        });
    }
    b.installArtifact(test_lib);

    // `src/cli/` and `src/io/` live in the exe's module, so their tests need
    // their own artifact.
    const test_cli = b.addTest(.{
        .name = "test-cli",
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(test_cli);

    const test_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
        .error_tracing = if (debug_release) true else null,
        .strip = if (debug_release) false else null,
    });
    test_utils_mod.addImport("config", l.modules.get("config").?);
    const test_utils = b.addTest(.{
        .name = "test-utils",
        .root_module = test_utils_mod,
        .use_llvm = use_llvm,
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
        const run_lib_tests = b.addRunArtifact(test_lib);
        const run_cli_tests = b.addRunArtifact(test_cli);
        const run_utils_tests = b.addRunArtifact(test_utils);
        const unit_step = b.step("test", "Run unit tests");
        unit_step.dependOn(&run_lib_tests.step);
        unit_step.dependOn(&run_cli_tests.step);
        unit_step.dependOn(&run_utils_tests.step);

        const run_e2e = b.addRunArtifact(e2e);
        const e2e_step = b.step("test-e2e", "Run e2e tests");
        e2e_step.dependOn(&run_e2e.step);

        const test_all_step = b.step("test-all", "Run all tests");
        test_all_step.dependOn(unit_step);
        test_all_step.dependOn(e2e_step);
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

pub const ZLintStep = struct {
    step: Build.Step,
};

/// Add an opaque run step that runs the linter.
pub fn addRunLint(b: *std.Build, zlint_dep: *std.Build.Dependency) *ZLintStep {
    const exe = zlint_dep.artifact("zlint");
    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    return @ptrCast(run);
}

/// Step that runs the `test` blocks in each registered custom rule.
pub fn addRunCustomLintRulesTest(b: *std.Build, zlint_dep: *std.Build.Dependency) *Build.Step {
    _ = b;
    const tls = zlint_dep.builder.top_level_steps.get("test-custom-rules") orelse
        @panic("zlint dependency is missing the 'test-custom-rules' step");
    return &tls.step;
}
