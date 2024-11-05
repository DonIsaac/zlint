const builtin = @import("builtin");

pub const string = []const u8;
pub const stringSlice = [:0]const u8;
pub const stringMut = []u8;
pub const IS_DEBUG = builtin.mode == .Debug;
