const Config = @This();

/// `true` when stderr is an interactive terminal. Gates *cursor control*:
is_tty: bool = false,
/// `true` when status lines may use SGR color.
color: bool = false,
/// How suite output is framed. Separate from `color` and `is_tty`: it decides
/// what *structure* the reader understands, not what it can render.
format: Format = .utf8,

pub const Format = enum {
    utf8,
    github,
};

pub fn new(io: Io, environ: *const Environ.Map) Config {
    const is_tty = Io.File.stderr().isTty(io) catch false;
    return .{
        .is_tty = is_tty,
        .color = resolveColor(is_tty, environ),
        .format = resolveFormat(environ),
    };
}

fn resolveFormat(environ: *const Environ.Map) Format {
    // GitHub Actions sets this to "true" for every step.
    if (isSetAndNonEmpty(environ, "GITHUB_ACTIONS")) return .github;
    return .utf8;
}

/// Decide whether color is wanted, in precedence order.
fn resolveColor(is_tty: bool, environ: *const Environ.Map) bool {
    // `FORCE_COLOR` wins over everything
    if (environ.get("FORCE_COLOR")) |value| {
        return !std.mem.eql(u8, value, "0");
    }
    // https://no-color.org: presence with a non-empty value disables color.
    if (isSetAndNonEmpty(environ, "NO_COLOR")) return false;
    if (is_tty) return true;

    return isColorCapableCi(environ);
}

/// CI environments whose log viewers render SGR color despite stderr being a
/// pipe.
fn isColorCapableCi(environ: *const Environ.Map) bool {
    return switch (resolveFormat(environ)) {
        .github => true,
        .utf8 => false,
    };
}

fn isSetAndNonEmpty(environ: *const Environ.Map, key: []const u8) bool {
    const value = environ.get(key) orelse return false;
    return value.len > 0;
}

const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;
