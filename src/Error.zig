//! An error reported during parsing, semantic analysis, or linting.
//!
//! An error's memory is entirely borrowed. It is the caller's responsibility to
//! alloc/free it correctly.
//!
//! Errors are most commonly managed by a `Result`. In this form, the `Result`
//! holds ownership over allocations.

code: []const u8 = "",
message: Cow(false),
severity: Severity = .err,
/// Text ranges over problematic parts of the source code.
labels: std.ArrayListUnmanaged(LabeledSpan) = .{},
// labels: []LabeledSpan = NO_SPANS,
/// Name of the file being linted.
source_name: ?[]const u8 = null,
source: ?ArcStr = null,
/// Optional help text. This will go under the code snippet.
help: ?Cow(false) = null,

// Although this is not [:0]const u8, it should not be mutated. Needs to be mut
// to indicate to Arc it's owned by the Error. Otherwise, arc.deinit() won't
// free the slice.
pub const ArcStr = Arc([:0]u8);

pub fn new(message: []u8, allocator: Allocator) Error {
    return Error{ .message = Cow(false).owned(message, allocator) };
}

pub fn newStatic(comptime message: []const u8) Error {
    return Error{ .message = Cow(false).static(message) };
}

pub fn fmt(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!Error {
    return Error{ .message = try Cow(false).fmt(alloc, format, args) };
}

pub fn newAtLocation(message: []const u8, span: Span) Error {
    return Error{
        .message = message,
        .labels = [_]Span{span},
    };
}

pub fn deinit(self: *Error, alloc: std.mem.Allocator) void {
    self.message.deinit(alloc);

    if (self.help) |*help| help.deinit(alloc);
    if (self.source_name) |src_name| alloc.free(src_name);
    if (self.source) |*src| src.deinit();
    for (self.labels.items) |*label| {
        if (label.label) |*label_text| label_text.deinit(alloc);
    }
    self.labels.deinit(alloc);
}

pub fn jsonStringify(self: *const Error, jw: anytype) !void {
    // const W = std.json.WriteStream(std.io.AnyWriter, .{});
    // const jw = @as(W, jw_);
    try jw.beginObject();

    try jw.objectFieldRaw("\"level\"");
    try jw.write(self.severity.asSlice());

    try jw.objectFieldRaw("\"message\"");
    try jw.write(self.message.borrow());

    try jw.objectFieldRaw("\"code\"");
    try jw.write(if (self.code.len > 0) self.code else null);

    if (self.source) |source| {
        const src: []const u8 = source.deref().*[0..];
        try jw.objectFieldRaw("\"labels\"");
        try jw.beginArray();
        for (self.labels.items) |label| {
            try jw.write(label.fmtJson(src));
        }
        try jw.endArray();
    }

    try jw.objectFieldRaw("\"source_name\"");
    try jw.write(self.source_name);

    try jw.objectFieldRaw("\"help\"");
    try jw.write(self.help);

    try jw.endObject();
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

    pub fn jsonSchema(ctx: *Schema.Context) !Schema {
        const numeric = Schema.Integer.schema(0, 2);
        const str = Schema.Enum.schema(severity_map.keys());

        var schema = try ctx.oneOf(&[_]Schema{ numeric, str });
        _ = schema.common()
            .withTitle("Severity")
            .withDescription(
            \\Set the error level of a rule. 'off' and 'allow' do the same thing.
        );
        _ = &schema;
        return schema;
    }

    pub fn asSlice(self: Severity) []const u8 {
        switch (self) {
            .err => return "error",
            .warning => return "warn",
            .notice => return "notice",
            .off => return "off",
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
const _span = @import("span.zig");
const Schema = @import("json.zig").Schema;

const Allocator = std.mem.Allocator;
const Arc = ptrs.Arc;
const Cow = util.Cow;

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
