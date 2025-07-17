const std = @import("std");
const builtin = @import("builtin");
const c = @import("constants.zig");
const Build = std.Build;
const Module = Build.Module;
const Step = Build.Step;

pub const CodegenTasks = struct {
    /// zlint lib
    zlint: *Module,
    b: *Build,
    target: ?Build.ResolvedTarget = null,
    optimize: std.builtin.OptimizeMode = .Debug,

    _docgen_exe: ?*Step.Compile = null,
    _confgen_exe: ?*Step.Compile = null,

    /// `zig build docs`
    pub fn docs(self: *CodegenTasks) *Step {
        const b = self.b;
        const docgen_exe = self.docgen();
        const fmt_docs = bun(
            self.b,
            "run",
            &[_][]const u8{ "fmt:some", c.@"docs/rules" },
        );

        const docgen_run = b.addRunArtifact(docgen_exe);
        fmt_docs.step.dependOn(&docgen_run.step);

        const docs_step = b.step("docs", "Generate lint rule docs + zlint library docs");
        docs_step.dependOn(&docgen_run.step);
        docs_step.dependOn(&fmt_docs.step);

        return docs_step;
    }

    /// `zig build config`
    pub fn config(self: *CodegenTasks) *Step {
        const b = self.b;
        const confgen_exe = self.confgen();
        const confgen_run = b.addRunArtifact(confgen_exe);

        const fmt_rule_docs = b.addSystemCommand(
            &[_][]const u8{ "zig", "fmt", c.@"rules_config.zig" },
        );

        const config_step = b.step("config", "Generate rules config");
        config_step.dependOn(&confgen_run.step);
        config_step.dependOn(&fmt_rule_docs.step);

        return config_step;
    }

    pub fn docgen(self: *CodegenTasks) *Step.Compile {
        if (self._docgen_exe) |exe| return exe;
        const b = self.b;
        const docgen_mod = b.createModule(Module.CreateOptions{
            .root_source_file = b.path("tasks/docgen.zig"),
            .optimize = self.optimize,
            .target = self.target,
            .imports = &[_]Module.Import{
                .{ .name = "zlint", .module = self.zlint },
            },
        });
        self._docgen_exe = b.addExecutable(.{
            .name = "docgen",
            .root_module = docgen_mod,
            .optimize = self.optimize,
        });
        return self._docgen_exe.?;
    }

    pub fn confgen(self: *CodegenTasks) *Step.Compile {
        if (self._confgen_exe) |exe| return exe;
        const b = self.b;
        const confgen_mod = b.createModule(Module.CreateOptions{
            .root_source_file = b.path("tasks/confgen.zig"),
            .optimize = self.optimize,
            .target = self.target,
            .imports = &[_]Module.Import{
                .{ .name = "zlint", .module = self.zlint },
            },
        });
        self._confgen_exe = b.addExecutable(.{
            .name = "confgen",
            .root_module = confgen_mod,
            .optimize = self.optimize,
        });
        return self._confgen_exe.?;
    }
};

pub fn bun(b: *Build, comptime cmd: []const u8, comptime args: []const []const u8) *Step.Run {
    return runBun(b, false, cmd, args);
}

pub fn bunx(b: *Build, comptime cmd: []const u8, comptime args: []const []const u8) *Step.Run {
    return runBun(b, true, cmd, args);
}

fn runBun(
    b: *Build,
    comptime is_bunx: bool,
    comptime cmd: []const u8,
    comptime args: []const []const u8,
) *Step.Run {
    const bun_exe = if (is_bunx) "bunx" else "bun";
    return b.addSystemCommand(.{ bun_exe, cmd } ++ args);
}
