//! An error reported during parsing, semantic analysis, or linting.
//!
//! An error's memory is entirely borrowed. It is the caller's responsibility to
//! alloc/free it correctly.
//!
//! Errors are most commonly managed by a `Result`. In this form, the `Result`
//! holds ownership over allocations.

code: []const u8 = "",
message: PossiblyStaticStr,
severity: Severity = .err,
/// Text ranges over problematic parts of the source code.
labels: std.ArrayListUnmanaged(LabeledSpan) = .{},
// labels: []LabeledSpan = NO_SPANS,
/// Name of the file being linted.
source_name: ?string = null,
source: ?ArcStr = null,
/// Optional help text. This will go under the code snippet.
help: ?PossiblyStaticStr = null,

// Although this is not [:0]const u8, it should not be mutated. Needs to be mut
// to indicate to Arc it's owned by the Error. Otherwise, arc.deinit() won't
// free the slice.
const ArcStr = Arc([:0]u8);
pub const PossiblyStaticStr = struct {
    static: bool = true,
    str: string,

    pub fn format(this: PossiblyStaticStr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.writeAll(this.str);
    }
};

pub fn new(message: string) Error {
    return Error{ .message = .{ .str = message, .static = false } };
}

pub fn newStatic(message: string) Error {
    return Error{ .message = .{ .str = message, .static = true } };
}

pub fn fmt(alloc: Allocator, comptime format: string, args: anytype) Allocator.Error!Error {
    return Error{ .message = .{
        .str = try std.fmt.allocPrint(alloc, format, args),
        .static = false,
    } };
}

pub fn newAtLocation(message: string, span: Span) Error {
    return Error{
        .message = message,
        .labels = [_]Span{span},
    };
}

pub fn deinit(self: *Error, alloc: std.mem.Allocator) void {
    if (!self.message.static) alloc.free(self.message.str);

    if (self.help != null and !self.help.?.static) alloc.free(self.help.?.str);
    if (self.source_name != null) alloc.free(self.source_name.?);
    if (self.source != null) self.source.?.deinit();
    for (self.labels.items) |*label| {
        if (label.label) |*label_text| label_text.deinit();
    }
    self.labels.deinit(alloc);
}

const ParseError = json.ParseError(json.Scanner);
const severity_map = std.StaticStringMap(Severity).initComptime([_]struct { []const u8, Severity }{
    .{ "error", Severity.err },
    .{ "deny", Severity.err },
    .{ "warn", Severity.warning },
    .{ "off", Severity.off },
    .{ "allow", Severity.off },
});

/// Severity level for issues found by lint rules.
///
/// Each lint rule gets assigned a severity level.
/// - Errors cause a non-zero exit code. They are highlighted in red.
/// - Warnings do not affect exit code and are yellow.
/// - Off skips the rule entirely.
pub const Severity = enum {
    err,
    warning,
    notice,
    off,

    /// `std.json.parseFromSlice` looks for and calls methods called `jsonParse`
    /// when they exist.
    pub fn jsonParse(_: Allocator, source: *json.Scanner, options: json.ParseOptions) !Severity {
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string => {
                return severity_map.get(tok.string) orelse return ParseError.InvalidEnumTag;
            },
            .number => {
                switch (tok.number[0]) {
                    '0' => return .off,
                    '1' => return .warning,
                    '2' => return .err,
                    else => return ParseError.InvalidEnumTag,
                }
            },
            else => return ParseError.UnexpectedToken,
        }
    }
};

/// Results hold a value and a list of errors. Useful for error-recoverable
/// situations, where a value may still be produced even if errors are
/// encountered.
///
/// All errors in a `Result` must be allocated with the same allocator, which
/// must be `Result.alloc`.
pub fn Result(comptime T: type) type {
    const ErrorList = std.ArrayListUnmanaged(Error);
    return struct {
        value: T,
        ///
        errors: ErrorList = .{},
        alloc: Allocator,

        const Self = @This();
        const type_info = @typeInfo(T);

        /// Create a new `Result`. No memory is allocated.
        pub fn new(alloc: Allocator, value: T, errors: ErrorList) Self {
            return .{
                .value = value,
                .errors = errors,
                .alloc = alloc,
            };
        }

        /// Create a successful `Result` instance. No memory is allocated.
        pub fn fromValue(alloc: std.mem.Allocator, value: T) Self {
            return .{
                .value = value,
                .alloc = alloc,
            };
        }

        /// Free both the success value and the error list. The result is no
        /// longer usable after calls to this method.
        pub fn deinit(self: *Self) void {
            if (@hasDecl(T, "deinit")) {
                self.value.deinit();
            } else {
                switch (type_info) {
                    .Pointer => {
                        if (@hasDecl(type_info.Pointer.child, "deinit")) {
                            @compileError("Uhg I need to get deinit() from a child type");
                        }
                    },
                    .Optional => {
                        const child = type_info.Optional.child;
                        if (@hasDecl(child, "deinit")) {
                            if (self.value != null) {
                                self.value.*.deinit();
                            }
                        }
                    },
                }
            }

            self.deinitErrors();
        }

        /// Free the error list, leaving `value` untouched. Caller must ensure
        /// that `value` gets de-alloc'd later. Following calls to
        /// `Result.deinit` will result in a double-free.
        pub fn deinitErrors(self: *Self) void {
            var i: usize = 0;
            const len = self.errors.items.len;
            while (i < len) {
                self.errors.items[i].deinit(self.alloc);
                i += 1;
            }
            self.errors.deinit(self.alloc);
        }

        pub fn hasErrors(self: *Self) bool {
            return self.errors.items.len != 0;
        }
    };
}

const Error = @This();

const std = @import("std");
const json = std.json;
const ptrs = @import("smart-pointers");
const util = @import("util");
const _src = @import("source.zig");
const _span = @import("span.zig");

const Allocator = std.mem.Allocator;
const Arc = ptrs.Arc;
const string = util.string;

const Source = _src.Source;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;

const t = std.testing;

fn expectParse(input: []const u8, expected: Severity) !void {
    const actual = try json.parseFromSlice(Severity, t.allocator, input, .{});
    defer actual.deinit();
    try t.expectEqual(expected, actual.value);
}

test "Severity.jsonParse" {
    try expectParse("\"error\"", Severity.err);
    try expectParse("\"deny\"", Severity.err);
    try expectParse("2", Severity.err);

    try expectParse("\"warn\"", Severity.warning);
    try expectParse("1", Severity.warning);

    try expectParse("\"off\"", Severity.off);
    try expectParse("\"allow\"", Severity.off);
    try expectParse("0", Severity.off);
}
