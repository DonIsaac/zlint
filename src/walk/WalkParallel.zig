// pub fn WalkParallel(comptime VisitorBuilder: type, comptime Visitor: type) type {
//     if (comptime !@hasDecl(Visitor, "build")) {
//         @compileError("VisitorBuilder must have a build() method that returns a Visitor");
//     }
//     if (comptime !@hasDecl(Visitor, "visit")) {
//         @compileError("Visitor must have a visit() method");
//     }

//     return struct {
//         builder: VisitorBuilder,
//         walker: Walker,
//         alloc: Allocator,

//         const Self = @This();

//         pub fn init(alloc: Allocator, dir: Dir, builder: VisitorBuilder) !Self {
//             const walker = try Walker.init(alloc, dir, .{ .filter_dir = &shouldIgnoreDir });
//             return Self{

//                 .builder = builder,
//                 .alloc = alloc,
//             };
//         }
//     };
// }

// fn shouldIgnoreDir(_: *const Dir, path: [:0]const u8) bool {
// }

const std = @import("std");
const fs = std.fs;
const Dir = std.fs.Dir;
const Allocator = std.mem.Allocator;
const Walker = @import("./Walker.zig");
