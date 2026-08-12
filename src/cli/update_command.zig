//! `zlint update` command parsing and update orchestration.

const std = @import("std");
const builtin = @import("builtin");

const UpdateClient = @import("update/Client.zig");
const StagedExecutable = @import("update/StagedExecutable.zig");
const release = @import("update/release.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const latest_release_url = "https://api.github.com/repos/DonIsaac/zlint/releases/latest";
const usage =
    \\Usage: zlint update
    \\
    \\Download, verify, and install the latest stable version of zlint.
    \\
    \\Aliases: upgrade, up
    \\
    \\-h, --help  Show this help message
;

/// Names that select the updater when used as the first argument.
const command_names = [_][]const u8{ "update", "upgrade", "up" };

fn isUpdateCommand(arg: []const u8) bool {
    for (command_names) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

pub fn isCommand(alloc: Allocator, args: std.process.Args) !bool {
    var argv = try std.process.Args.Iterator.initAllocator(args, alloc);
    defer argv.deinit();
    return isCommandIterator(&argv);
}

pub fn run(
    alloc: Allocator,
    io: Io,
    args: std.process.Args,
    environ: std.process.Environ,
    current_version: []const u8,
) u8 {
    const command = parseArgs(alloc, args) catch |err| {
        printError(io, "invalid update command: {s}", .{@errorName(err)});
        printStderr(io, "{s}\n", .{usage});
        return 1;
    };
    if (command == .help) {
        printStdout(io, "{s}\n", .{usage});
        return 0;
    }

    performUpdate(alloc, io, environ, current_version) catch |err| {
        printUpdateError(io, err, current_version);
        return 1;
    };
    return 0;
}

const Command = enum { update, help };

fn parseArgs(alloc: Allocator, args: std.process.Args) !Command {
    var argv = try std.process.Args.Iterator.initAllocator(args, alloc);
    defer argv.deinit();
    return parseIterator(&argv);
}

fn isCommandIterator(args_iter: anytype) bool {
    var argv = args_iter.*;
    _ = argv.next() orelse return false;
    const command = argv.next() orelse return false;
    return isUpdateCommand(command);
}

fn parseIterator(args_iter: anytype) !Command {
    var argv = args_iter.*;
    _ = argv.next() orelse return error.MissingCommand;
    const command = argv.next() orelse return error.MissingCommand;
    if (!isUpdateCommand(command)) return error.InvalidCommand;

    var parsed: Command = .update;
    while (argv.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed = .help;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

fn performUpdate(
    alloc: Allocator,
    io: Io,
    environ: std.process.Environ,
    current_version_text: []const u8,
) anyerror!void {
    const asset_name = release.assetNameForTarget(builtin.os.tag, builtin.cpu.arch) orelse
        return error.UnsupportedTarget;

    var client = try UpdateClient.init(alloc, io, environ);
    defer client.deinit();

    const metadata_json = client.fetchRelease(latest_release_url) catch |err| switch (err) {
        error.StreamTooLong => return error.ReleaseMetadataTooLarge,
        error.UnknownHostName,
        error.NameServerFailure,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        => return error.CouldNotFetchRelease,
        else => |e| return e,
    };
    defer alloc.free(metadata_json);

    var parsed_release = release.Metadata.parseFromSlice(alloc, metadata_json) catch |err| switch (err) {
        // A local allocation failure is not GitHub sending us bad metadata.
        error.OutOfMemory => |e| return e,
        else => return error.ReleaseRequestFailed,
    };
    defer parsed_release.deinit();
    const metadata = parsed_release.value;

    const latest_version = release.parseVersion(metadata.tag_name) catch return error.InvalidReleaseVersion;
    const current_version = release.parseVersion(current_version_text) catch return error.InvalidCurrentVersion;
    const executable_path = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(executable_path);

    if (current_version.order(latest_version) != .lt) {
        printAlreadyCurrent(io, current_version_text, metadata.tag_name, executable_path);
        return;
    }

    const asset = try metadata.selectAsset(asset_name);
    printStdout(io, "Updating zlint from {s} to {s}...\n", .{
        current_version_text,
        parsed_release.value.tag_name,
    });

    var staged = try StagedExecutable.new(io, executable_path);
    defer staged.deinit();

    const actual_digest = client.downloadAsset(asset.download_url, asset.size, staged.file()) catch |err| switch (err) {
        error.EndOfStream, error.StreamTooLong => return error.DownloadSizeMismatch,
        else => |e| return e,
    };
    try staged.finishWriting();
    try release.verifyDigest(actual_digest, asset.digest);

    switch (try staged.install(alloc)) {
        .replaced => printStdout(io, "Updated zlint to {s} at {s}\n", .{
            parsed_release.value.tag_name,
            executable_path,
        }),
        .deferred => printStdout(io, "Verified zlint {s}; installation will finish after this process exits ({s})\n", .{
            parsed_release.value.tag_name,
            executable_path,
        }),
    }
}

fn printAlreadyCurrent(io: Io, current_version: []const u8, latest_version: []const u8, path: []const u8) void {
    printStdout(io, "zlint {s} is already up to date (latest: {s}) at {s}\n", .{
        current_version,
        latest_version,
        path,
    });
}

fn printUpdateError(io: Io, err: anyerror, current_version: []const u8) void {
    switch (err) {
        error.UnsupportedTarget => printError(io, "no release binary is available for {s}-{s}. Please compile from source or open an issue on GitHub.", .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        }),
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => printError(io, "cannot replace the installed binary; rerun with permission to write its directory", .{}),
        error.ChecksumMismatch => printError(io, "the downloaded binary failed SHA-256 verification; the installed binary was not changed", .{}),
        error.DownloadSizeMismatch => printError(io, "the downloaded binary size does not match the release metadata", .{}),
        error.HttpBadRequest => printError(io, "GitHub rejected the update request (HTTP 400 Bad Request)", .{}),
        error.HttpClientError => printError(io, "GitHub rejected the update request (HTTP 4xx)", .{}),
        error.HttpForbidden => printError(io, "GitHub refused the update request (HTTP 403 Forbidden); the API rate limit may be exhausted", .{}),
        error.HttpNotFound => printError(io, "the requested GitHub release resource was not found (HTTP 404 Not Found)", .{}),
        error.HttpRateLimited => printError(io, "GitHub rate-limited the update request (HTTP 429 Too Many Requests); try again later", .{}),
        error.HttpRequestTimeout => printError(io, "the update request timed out (HTTP 408 Request Timeout)", .{}),
        error.HttpServerError => printError(io, "GitHub is temporarily unavailable (HTTP 5xx); try again later", .{}),
        error.HttpUnauthorized => printError(io, "GitHub rejected the update request (HTTP 401 Unauthorized)", .{}),
        error.HttpUnexpectedStatus => printError(io, "GitHub returned an unexpected HTTP response", .{}),
        error.HttpRedirectLocationMissing => printError(io, "GitHub sent a redirect without a location", .{}),
        error.TooManyHttpRedirects => printError(io, "GitHub redirected the update request too many times", .{}),
        error.InsecureRedirect => printError(io, "the update request was redirected to a non-HTTPS URL; refusing to continue", .{}),
        error.RedirectHostNotAllowed => printError(io, "the release metadata request was redirected away from GitHub; refusing to continue", .{}),
        error.RedirectLocationTooLong => printError(io, "GitHub redirected the update request to an excessively long URL", .{}),
        error.InsecureDownloadUrl => printError(io, "GitHub returned a non-HTTPS download URL", .{}),
        error.InvalidCurrentVersion => printError(io, "the installed version is not a valid semantic version: {s}", .{current_version}),
        error.InvalidDigest => printError(io, "GitHub returned an invalid SHA-256 digest", .{}),
        error.InvalidReleaseVersion => printError(io, "GitHub returned an invalid release version", .{}),
        error.ReleaseAssetMissingDigest => printError(io, "the release asset does not have a SHA-256 digest", .{}),
        error.ReleaseAssetNotFound => printError(io, "the latest release does not contain a binary for this target", .{}),
        error.ReleaseAssetTooLarge => printError(io, "the release binary is unexpectedly large", .{}),
        error.ReleaseMetadataTooLarge => printError(io, "GitHub release metadata exceeded {d} bytes", .{UpdateClient.metadata_limit}),
        error.ReleaseRequestFailed => printError(io, "GitHub returned invalid release metadata", .{}),
        error.WindowsHandoffFailed => printError(io, "could not start the Windows update handoff", .{}),
        error.CouldNotFetchRelease => printError(io, "could not download binary from GitHub. Please check your internet connection.", .{}),
        else => printError(io, "update failed: {s}", .{@errorName(err)}),
    }
}

fn printStdout(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    writer.interface.print(format, args) catch return;
    writer.interface.flush() catch return;
}

fn printStderr(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    writer.interface.print(format, args) catch return;
    writer.interface.flush() catch return;
}

fn printError(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    writer.interface.writeAll("error: ") catch return;
    writer.interface.print(format, args) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

const t = std.testing;

test "update is recognized only as the first argument" {
    inline for (.{ "zlint update", "zlint upgrade", "zlint up" }) |argv| {
        var command = std.mem.splitScalar(u8, argv, ' ');
        try t.expect(isCommandIterator(&command));
    }

    inline for (.{ "zlint -- update", "zlint -- up" }) |argv| {
        var escaped = std.mem.splitScalar(u8, argv, ' ');
        try t.expect(!isCommandIterator(&escaped));
    }

    inline for (.{ "zlint src/update", "zlint src/up", "zlint updated" }) |argv| {
        var path = std.mem.splitScalar(u8, argv, ' ');
        try t.expect(!isCommandIterator(&path));
    }
}

test "update accepts only help flags" {
    inline for (.{ "zlint update", "zlint upgrade", "zlint up" }) |argv| {
        var update_args = std.mem.splitScalar(u8, argv, ' ');
        try t.expectEqual(.update, try parseIterator(&update_args));
    }

    inline for (.{ "zlint update -h", "zlint upgrade -h", "zlint up --help" }) |argv| {
        var help_args = std.mem.splitScalar(u8, argv, ' ');
        try t.expectEqual(.help, try parseIterator(&help_args));
    }

    var long_help = std.mem.splitScalar(u8, "zlint update --help", ' ');
    try t.expectEqual(.help, try parseIterator(&long_help));

    var invalid = std.mem.splitScalar(u8, "zlint update --force", ' ');
    try t.expectError(error.UnexpectedArgument, parseIterator(&invalid));

    var help_with_arg = std.mem.splitScalar(u8, "zlint update --help extra", ' ');
    try t.expectError(error.UnexpectedArgument, parseIterator(&help_with_arg));

    var not_a_command = std.mem.splitScalar(u8, "zlint lint", ' ');
    try t.expectError(error.InvalidCommand, parseIterator(&not_a_command));
}
