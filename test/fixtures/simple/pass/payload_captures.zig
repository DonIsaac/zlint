//! Every construct that binds a capture payload, in one file.

const U = union(enum) {
    a: u32,
    b: u32,
};

fn log(_: anyerror) void {}

extern fn puts(s: [*:0]const u8) c_int;

fn next() anyerror!?u32 {
    return 1;
}

fn errdeferPayload() !void {
    errdefer |err| log(err);
    return error.Oops;
}

fn whileElseCapture() void {
    while (next()) |value| {
        _ = value;
    } else |err| {
        log(err);
    }
}

fn switchCaptures(u: U) void {
    switch (u) {
        inline else => |value, tag| {
            _ = value;
            _ = tag;
        },
    }
}

fn switchPointerCaptures(u: *U) void {
    switch (u.*) {
        inline else => |*value, tag| {
            _ = value;
            _ = tag;
        },
    }
}

fn callExternFn() c_int {
    return puts("hi");
}
