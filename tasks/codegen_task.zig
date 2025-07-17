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

    _docgen_mod: ?*Module = null,
    _confgen_mod: ?*Module = null,

    pub fn docgenStep(self: *CodegenTasks) *Step {
        const b = self.b;
        const docgen_exe = b.addExecutable(Build.ExecutableOptions{
            .name = "docgen",
            .root_module = self.docgen(),
            .optimize = self.optimize,
            .target = self.target,
        });
        const docgen_run = b.addRunArtifact(docgen_exe);

        const docgen_step = b.step("docgen", "Generate lint rule docs");
        docgen_step.dependOn(&docgen_run.step);
        docgen_step.dependOn(bun(self.b, "run", .{ "fmt:some", c.@"docs/rules" }));

        return docgen_step;
    }

    pub fn confgenStep(self: *CodegenTasks) *Step {
        const b = self.b;
        const confgen_exe = b.addExecutable(Build.ExecutableOptions{
            .name = "confgen",
            .root_module = self.confgen(),
            .optimize = self.optimize,
            .target = self.target,
        });
        const confgen_run = b.addRunArtifact(confgen_exe);

        const fmt_rule_docs = b.addSystemCommand(
            &[_][]const u8{ "zig", "fmt", c.@"rules_config.zig" },
        );

        const confgen_step = b.step("confgen", "Generate rules config");
        confgen_step.dependOn(&confgen_run.step);
        confgen_step.dependOn(&fmt_rule_docs.step);

        return confgen_step;
    }

    pub fn docgen(self: *CodegenTasks) *Module {
        return self._docgen_mod orelse new: {
            const b = self.b;
            self._docgen_mod = b.createModule(Module.CreateOptions{
                .root_source_file = b.path("tasks/docgen.zig"),
                .optimize = self.optimize,
                .target = self.target,
                .imports = &[_]Module.Import{
                    .{ .name = "zlint", .module = self.zlint },
                },
            });
            break :new self._docgen_mod.?;
        };
    }

    pub fn confgen(self: *CodegenTasks) *Module {
        return self._confgen_mod orelse new: {
            const b = self.b;
            self._confgen_mod = b.createModule(Module.CreateOptions{
                .root_source_file = b.path("tasks/confgen.zig"),
                .optimize = self.optimize,
                .target = self.target,
                .imports = &[_]Module.Import{
                    .{ .name = "zlint", .module = self.zlint },
                },
            });
            break :new self._confgen_mod.?;
        };
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
