const std = @import("std");
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

        const bun_fmt_docs = b.addSystemCommand(&.{ "bun", "run", "fmt:some", c.@"docs/rules" });

        const docgen_run = b.addRunArtifact(docgen_exe);
        bun_fmt_docs.step.dependOn(&docgen_run.step);

        const docs_step = b.step("docs", "Generate lint rule docs + zlint library docs");
        docs_step.dependOn(&docgen_run.step);
        docs_step.dependOn(&bun_fmt_docs.step);

        return docs_step;
    }

    /// `zig build config`
    pub fn configMod(self: *CodegenTasks) *Build.Module {
        const b = self.b;
        const confgen_exe = self.confgen();
        const confgen_run = b.addRunArtifact(confgen_exe);

        const conf_mod = self.b.createModule(.{
            .root_source_file = confgen_run.captureStdOut(.{}),
            .optimize = self.optimize,
            .target = self.target,
        });

        return conf_mod;
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
        });
        return self._confgen_exe.?;
    }
};
