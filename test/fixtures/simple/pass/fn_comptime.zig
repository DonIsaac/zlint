fn Box(T: type) type {
    return struct {
        inner: *T,
        const Self = @This();

        pub fn deref(self: *Self) *T {
            return self.inner;
        }
    };
}

fn FixedIntArray(comptime size: usize) type {
    return struct { inner: [size]u32 };
}

fn add(comptime a: isize, b: usize) usize {
    comptime {
        const c = 3;
        if (a < c) {
            @compileError("a cannot be less than 3");
        }
    }
    const a2: usize = @intCast(a);
    return a2 + b;
}
