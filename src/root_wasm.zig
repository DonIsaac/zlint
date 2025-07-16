const std = @import("std");

pub const semantic = @import("semantic.zig");
pub const Source = @import("source.zig").Source;
pub const report = @import("reporter.zig");

pub const lint = @import("lint.zig");

/// Internal. Exported for codegen.
pub const json = @import("json.zig");

export fn alloc_string(size: usize) [*]const u8 {
    return (std.heap.wasm_allocator.alloc(u8, size) catch @panic("oom")).ptr;
}

export fn free_string(ptr: [*]const u8, len: usize) void {
    return std.heap.wasm_allocator.free(ptr[0..len]);
}

const AnalyzeRes = extern struct {
  len: u32,
  ptr: [*]const u8,
};
 
export fn analyze(ptr: [*]const u8, len: usize) AnalyzeRes {
    _ = ptr;
    _ = len;
    const fake_result = "hello world!";
    return .{
        .len = fake_result.len,
        .ptr = fake_result.ptr,
    };
}
