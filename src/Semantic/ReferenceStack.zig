const ReferenceStack = @This();

frames: std.ArrayListUnmanaged(ReferenceIdList) = .{},

const ReferenceIdList = std.ArrayListUnmanaged(Reference.Id);

/// current frame
pub fn curr(self: *ReferenceStack) *ReferenceIdList {
    assert(self.len() > 0);
    return &self.frames.items[self.len() - 1];
}

/// parent frame. `null` when currently in root scope.
pub fn parent(self: *ReferenceStack) ?*ReferenceIdList {
    return if (self.len() <= 1) null else &self.frames.items[self.len() - 2];
}

/// current number of frames
pub inline fn len(self: ReferenceStack) usize {
    return self.frames.items.len;
}

pub fn enter(self: *ReferenceStack, alloc: Allocator) Allocator.Error!void {
    try self.frames.append(alloc, .{});
}

/// Add an unresolved reference to the current frame
pub fn append(self: *ReferenceStack, alloc: Allocator, ref: Reference.Id) Allocator.Error!void {
    try self.curr().append(alloc, ref);
}

pub fn deinit(self: *ReferenceStack, alloc: Allocator) void {
    for (0..self.frames.items.len) |i| {
        self.frames.items[i].deinit(alloc);
    }
    self.frames.deinit(alloc);
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Semantic = @import("../Semantic.zig");
const Reference = Semantic.Reference;
