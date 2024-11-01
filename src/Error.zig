message: string,
severity: Severity = .err,
labels: []Span = undefined,
source_name: ?string = null,
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
pub fn Result(comptime T: type) type {
    return struct {
        value: T,
        errors: ErrorList = .{},
        alloc: Allocator,

        const Self = @This();
        const type_info = @typeInfo(T);

        pub fn new(alloc: Allocator, value: T, errors: ErrorList) Self {
            return .{
                .value = value,
                .errors = errors,
                .alloc = alloc,
            };
        }

        pub fn fromValue(alloc: std.mem.Allocator, value: T) Self {
            return .{
                .value = value,
                .alloc = alloc,
            };
        }

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

        /// Free the error list, leaving `semantic` untouched.
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
