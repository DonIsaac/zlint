// source: https://www.openmymind.net/Zig-Interfaces/
const Writer = struct {
    // These two fields are the same as before
    ptr: *anyopaque,
    writeAllFn: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,

    // This is new
    fn init(ptr: anytype) Writer {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn writeAll(pointer: *anyopaque, data: []const u8) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.writeAll(self, data);
            }
        };

        return .{
            .ptr = ptr,
            .writeAllFn = gen.writeAll,
        };
    }

    // This is the same as before
    pub fn writeAll(self: Writer, data: []const u8) !void {
        return self.writeAllFn(self.ptr, data);
    }
};
