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

    var l = Linker.init(b);
    defer l.deinit();

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
    });
    l.link(zlint, false, .{});

    // artifacts
    const exe = b.addExecutable(.{
        .name = "zlint",
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
    });
    l.link(&exe.root_module, false, .{});
    b.installArtifact(exe);

    const e2e = b.addExecutable(.{
        .name = "test-e2e",
        .root_source_file = b.path("test/test_e2e.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
    });
    // util and chameleon omitted
    e2e.root_module.addImport("zlint", zlint);
    l.link(&e2e.root_module, true, .{ "smart-pointers", "recover" });

    b.installArtifact(e2e);

    const unit = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .single_threaded = single_threaded,
        .target = l.target,
        .optimize = l.optimize,
    });
    l.link(&unit.root_module, true, .{});
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
        const check_exe = b.addExecutable(.{ .name = "zlint", .root_source_file = b.path("src/main.zig"), .target = l.target });
        // mock library so zlint module is checked
        const check_lib = b.addStaticLibrary(.{ .name = "zlint", .root_source_file = b.path("src/root.zig"), .target = l.target, .optimize = l.optimize });
        const check_test_lib = b.addTest(.{ .root_source_file = b.path("src/root.zig") });
        const check_test_exe = b.addTest(.{ .root_source_file = b.path("src/main.zig") });
        const check_e2e = b.addExecutable(.{ .name = "test-e2e", .root_source_file = b.path("test/test_e2e.zig"), .target = l.target });
        check_e2e.root_module.addImport("zlint", zlint);
        check_e2e.root_module.addImport("zig-recover", zlint);

        const check = b.step("check", "Check for semantic errors");
        const substeps = .{ check_exe, check_lib, check_test_lib, check_test_exe, check_e2e };
        inline for (substeps) |c| {
            l.link(&c.root_module, false, .{});
            check.dependOn(&c.step);
        }

        // const rules_path = "src/linter/rules";
        // const rules_dir = b.path(rules_path);
        // var rules = std.fs.openDirAbsolute(rules_dir.getPath(b), .{ .iterate = true }) catch |e| {
        //     std.debug.panic("Failed to open rules directory: {any}", .{e});
        // };
        // defer rules.close();
        // var rules_walker = rules.walk(b.allocator) catch @panic("Failed to create rules walker");
        // var stack_fallback = std.heap.stackFallback(512, b.allocator);
        // const stack_alloc = stack_fallback.get();
        // while (true) {
        //     const rule = rules_walker.next() catch continue orelse break;
        //     const full_path = std.fs.path.join(stack_alloc, &[_][]const u8{ rules_path, rule.path }) catch @panic("OOM");
        //     defer stack_alloc.free(full_path);
        //     var fake_rule_tests = b.addTest(.{
        //         .root_source_file = .{ .cwd_relative = full_path },
        //         .optimize = optimize,
        //         .target = target,
        //     });
        //     check.dependOn(&fake_rule_tests.step);
        // }
    }
}

/// Stores modules and dependencies. Use `link` to register them as imports.
const Linker = struct {
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependencies: std.StringHashMapUnmanaged(*Build.Dependency) = .{},
    modules: std.StringHashMapUnmanaged(*Module) = .{},
    dev_modules: std.StringHashMapUnmanaged(*Module) = .{},

    fn init(b: *Build) Linker {
        return Linker{
            .b = b,
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
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
                std.debug.print("linking dev module: {s}\n", .{name});
                mod.addImport(name, dep);
            }
        }
    }

    fn deinit(self: *Linker) void {
        self.dependencies.deinit(self.b.allocator);
        self.modules.deinit(self.b.allocator);
    }
};
