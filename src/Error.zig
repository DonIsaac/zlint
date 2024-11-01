//! An error reported during parsing, semantic analysis, or linting.
//!
//! An error's memory is entirely borrowed. It is the caller's responsibility to
//! alloc/free it correctly.
//!
//! Errors are most commonly managed by a `Result`. In this form, the `Result`
//! holds ownership over allocations.

message: string,
severity: Severity = .err,
/// Text ranges over problematic parts of the source code.
labels: []Span = undefined,
/// Name of the file being linted.
source_name: ?string = null,
/// Optional help text. This will go under the code snippet.
help: ?string = null,

pub fn new(message: string) Error {
    return Error{
        .message = message,
    };
}

pub fn newAtLocation(message: string, span: Span, source_name: string) Error {
    return Error{
        .message = message,
        .source_name = source_name,
        .labels = [_]Span{span},
    };
}

pub fn deinit(self: *Error, alloc: std.mem.Allocator) void {
    alloc.free(self.message);
    if (self.help != null) alloc.free(self.help.?);
    if (self.source_name != null) alloc.free(self.source_name.?);
    // if (self.labels != null) alloc.free(self.labels);
}

/// Severity level for issues found by lint rules.
///
/// Each lint rule gets assigned a severity level.
/// - Errors cause a non-zero exit code. They are highlighted in red.
/// - Warnings do not affect exit code and are yellow.
/// - Off skips the rule entirely.
const Severity = enum {
    err,
    warning,
    off,
};

pub const ErrorList = std.ArrayListUnmanaged(Error);
/// Results hold a value and a list of errors. Useful for error-recoverable
/// situations, where a value may still be produced even if errors are
/// encountered.
///
/// All errors in a `Result` must be allocated with the same allocator, which
/// must be `Result.alloc`.
pub fn Result(comptime T: type) type {
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
const Allocator = std.mem.Allocator;
const string = @import("str.zig").string;
const Span = @import("source.zig").Span;
