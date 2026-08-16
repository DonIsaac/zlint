//! Same-directory staging and platform-specific executable replacement.

io: Io,
executable_path: []const u8,
directory_path: []const u8,
directory: Io.Dir,
staged: Io.File.Atomic,

const Self = @This();
const windows_handoff_script = @embedFile("windows_handoff.ps1");

pub const InstallResult = enum {
    replaced,
    deferred,
};

/// `executable_path` is borrowed for the lifetime of the returned value.
pub fn new(io: Io, executable_path: []const u8) !Self {
    const directory_path = path.dirname(executable_path) orelse return error.InvalidExecutablePath;
    const basename = path.basename(executable_path);

    var directory = try Io.Dir.openDirAbsolute(io, directory_path, .{});
    errdefer directory.close(io);

    var installed_file = try directory.openFile(io, basename, .{ .allow_directory = false });
    defer installed_file.close(io);
    const installed_stat = try installed_file.stat(io);

    var staged = try directory.createFileAtomic(io, basename, .{
        .permissions = installed_stat.permissions,
        .replace = true,
    });
    errdefer staged.deinit(io);
    try staged.file.setPermissions(io, installed_stat.permissions);

    return .{
        .io = io,
        .executable_path = executable_path,
        .directory_path = directory_path,
        .directory = directory,
        .staged = staged,
    };
}

pub fn deinit(self: *Self) void {
    self.staged.deinit(self.io);
    self.directory.close(self.io);
    self.* = undefined;
}

pub fn file(self: *Self) *Io.File {
    return &self.staged.file;
}

pub fn finishWriting(self: *Self) !void {
    try self.staged.file.sync(self.io);
    self.staged.file.close(self.io);
    self.staged.file_open = false;
}

pub fn install(self: *Self, alloc: Allocator) !InstallResult {
    if (comptime builtin.os.tag == .windows) {
        try self.handoffWindows(alloc);
        return .deferred;
    }

    try self.staged.replace(self.io);
    return .replaced;
}

fn handoffWindows(self: *Self, alloc: Allocator) !void {
    if (comptime builtin.os.tag != .windows) unreachable;

    const staged_basename = std.fmt.hex(self.staged.file_basename_hex);
    const staged_path = try path.join(alloc, &.{ self.directory_path, &staged_basename });
    defer alloc.free(staged_path);

    var helper_basename_buffer: [staged_basename.len + ".ps1".len]u8 = undefined;
    const helper_basename = try std.fmt.bufPrint(&helper_basename_buffer, "{s}.ps1", .{staged_basename});
    var helper_file = try self.staged.dir.createFile(self.io, helper_basename, .{
        .exclusive = true,
        .permissions = .default_file,
    });
    var helper_file_open = true;
    defer if (helper_file_open) helper_file.close(self.io);
    errdefer self.staged.dir.deleteFile(self.io, helper_basename) catch {};

    const helper_path = try path.join(alloc, &.{ self.directory_path, helper_basename });
    defer alloc.free(helper_path);
    const parent_pid_arg = try std.fmt.allocPrint(alloc, "{d}", .{std.os.windows.GetCurrentProcessId()});
    defer alloc.free(parent_pid_arg);

    try helper_file.writeStreamingAll(self.io, windows_handoff_script);
    try helper_file.sync(self.io);
    helper_file.close(self.io);
    helper_file_open = false;

    var child = std.process.spawn(self.io, .{
        .argv = &.{
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            helper_path,
            parent_pid_arg,
            staged_path,
            self.executable_path,
            helper_path,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.WindowsHandoffFailed;

    std.os.windows.CloseHandle(child.thread_handle);
    std.os.windows.CloseHandle(child.id.?);
    child.id = null;
    self.staged.file_exists = false;
}

const std = @import("std");
const builtin = @import("builtin");

const path = std.fs.path;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const t = std.testing;

test "verified file atomically replaces executable and preserves permissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "zlint",
        .data = "old binary",
        .flags = .{ .permissions = .executable_file },
    });

    const executable_path = try tmp.dir.realPathFileAlloc(t.io, "zlint", t.allocator);
    defer t.allocator.free(executable_path);
    const original_stat = try tmp.dir.statFile(t.io, "zlint", .{});

    var staged = try Self.new(t.io, executable_path);
    defer staged.deinit();
    try staged.file().writeStreamingAll(t.io, "new binary");
    try staged.finishWriting();
    try t.expectEqual(.replaced, try staged.install(t.allocator));

    const installed = try tmp.dir.readFileAlloc(t.io, "zlint", t.allocator, .limited(1024));
    defer t.allocator.free(installed);
    const installed_stat = try tmp.dir.statFile(t.io, "zlint", .{});
    try t.expectEqualStrings("new binary", installed);
    try t.expectEqual(original_stat.permissions, installed_stat.permissions);
}

test "abandoned staged file is cleaned up without changing executable" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zlint", .data = "old binary" });

    const executable_path = try tmp.dir.realPathFileAlloc(t.io, "zlint", t.allocator);
    defer t.allocator.free(executable_path);
    {
        var staged = try Self.new(t.io, executable_path);
        defer staged.deinit();
        try staged.file().writeStreamingAll(t.io, "incomplete download");
    }

    const installed = try tmp.dir.readFileAlloc(t.io, "zlint", t.allocator, .limited(1024));
    defer t.allocator.free(installed);
    try t.expectEqualStrings("old binary", installed);

    var entries = tmp.dir.iterate();
    var entry_count: usize = 0;
    while (try entries.next(t.io)) |entry| {
        entry_count += 1;
        try t.expectEqualStrings("zlint", entry.name);
    }
    try t.expectEqual(@as(usize, 1), entry_count);
}

test "Windows handoff replaces a file after its parent exits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "installed.exe", .data = "old binary" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "staged.exe", .data = "new binary" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "handoff.ps1", .data = windows_handoff_script });

    const installed_path = try tmp.dir.realPathFileAlloc(t.io, "installed.exe", t.allocator);
    defer t.allocator.free(installed_path);
    const staged_path = try tmp.dir.realPathFileAlloc(t.io, "staged.exe", t.allocator);
    defer t.allocator.free(staged_path);
    const script_path = try tmp.dir.realPathFileAlloc(t.io, "handoff.ps1", t.allocator);
    defer t.allocator.free(script_path);

    // Invoke the script the same way `handoffWindows` does; `-File` is what
    // makes the script's exit code the process exit code.
    const command = try std.fmt.allocPrint(t.allocator,
        \\$parent = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Milliseconds 100') -WindowStyle Hidden -PassThru;
        \\& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '{s}' $parent.Id '{s}' '{s}' '{s}';
        \\exit $LASTEXITCODE
    , .{ script_path, staged_path, installed_path, script_path });
    defer t.allocator.free(command);

    const result = try std.process.run(t.allocator, t.io, .{
        .argv = &.{
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        },
        .stderr_limit = .limited(4096),
        .stdout_limit = .limited(4096),
    });
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("handoff failed ({d}): {s}\n", .{ code, result.stderr });
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }

    const installed = try tmp.dir.readFileAlloc(t.io, "installed.exe", t.allocator, .limited(1024));
    defer t.allocator.free(installed);
    try t.expectEqualStrings("new binary", installed);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "staged.exe", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "handoff.ps1", .{}));
}
