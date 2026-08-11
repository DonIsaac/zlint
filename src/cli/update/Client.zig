//! HTTP client for release metadata and bounded binary downloads.

allocator: Allocator,
io: Io,
http: std.http.Client,
proxy_arena: std.heap.ArenaAllocator,

const Self = @This();
const request_user_agent = "zlint-update";
const release_headers = [_]std.http.Header{
    .{ .name = "Accept", .value = "application/vnd.github+json" },
    .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
};
const asset_headers = [_]std.http.Header{
    .{ .name = "Accept", .value = "application/octet-stream" },
};

pub const metadata_limit = 1024 * 1024;

/// Initializes TLS and proxy configuration from the process environment.
pub fn init(alloc: Allocator, io: Io, environ: std.process.Environ) !Self {
    var env_map = try environ.createMap(alloc);
    defer env_map.deinit();

    var proxy_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer proxy_arena.deinit();

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    errdefer http.deinit();
    try http.initDefaultProxies(proxy_arena.allocator(), &env_map);

    return .{
        .allocator = alloc,
        .io = io,
        .http = http,
        .proxy_arena = proxy_arena,
    };
}

pub fn deinit(self: *Self) void {
    self.http.deinit();
    self.proxy_arena.deinit();
    self.* = undefined;
}

// Release metadata

/// Fetches a release response into bounded, caller-owned storage.
pub fn fetchRelease(self: *Self, url: []const u8) ![]u8 {
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var request = try self.get(url, 3, &release_headers);
    defer request.deinit();

    try request.sendBodiless();
    var response = try request.receiveHead(&redirect_buffer);
    try requireOk(response.head.status);

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    return reader.allocRemaining(self.allocator, .limited(metadata_limit));
}

// Binary download

/// Streams exactly `expected_size` bytes to `destination` while hashing them.
/// The caller remains responsible for syncing and closing the destination.
pub fn downloadAsset(self: *Self, url: []const u8, expected_size: u64, destination: *Io.File) !release.Digest {
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var request = try self.get(url, 5, &asset_headers);
    defer request.deinit();

    try request.sendBodiless();
    var response = try request.receiveHead(&redirect_buffer);
    try requireOk(response.head.status);
    if (response.head.content_length) |content_length| {
        if (content_length != expected_size) return error.DownloadSizeMismatch;
    }

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = destination.writer(self.io, &file_buffer);
    var transfer_buffer: [64]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    const digest = try copyExactAndHash(response_reader, &file_writer.interface, expected_size);
    try file_writer.interface.flush();
    return digest;
}

// Shared HTTP and streaming primitives

fn get(
    self: *Self,
    url: []const u8,
    comptime redirect_count: u8,
    extra_headers: []const std.http.Header,
) !std.http.Client.Request {
    return self.http.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = @enumFromInt(redirect_count),
        .headers = .{
            .user_agent = .{ .override = request_user_agent },
            .accept_encoding = .omit,
        },
        .extra_headers = extra_headers,
    });
}

const HttpStatusError = error{
    HttpBadRequest,
    HttpUnauthorized,
    HttpForbidden,
    HttpNotFound,
    HttpRequestTimeout,
    HttpRateLimited,
    HttpClientError,
    HttpServerError,
    HttpUnexpectedStatus,
};

/// Converts unsuccessful HTTP statuses into stable errors that the command can
/// explain without exposing Zig's internal status names to users.
fn requireOk(status: std.http.Status) HttpStatusError!void {
    if (status == .ok) return;

    return switch (status) {
        .bad_request => error.HttpBadRequest,
        .unauthorized => error.HttpUnauthorized,
        .forbidden => error.HttpForbidden,
        .not_found => error.HttpNotFound,
        .request_timeout => error.HttpRequestTimeout,
        .too_many_requests => error.HttpRateLimited,
        else => switch (status.class()) {
            .client_error => error.HttpClientError,
            .server_error => error.HttpServerError,
            else => error.HttpUnexpectedStatus,
        },
    };
}

fn copyExactAndHash(reader: *Io.Reader, writer: *Io.Writer, expected_size: u64) !release.Digest {
    var hash_buffer: [64 * 1024]u8 = undefined;
    var hashed: Io.Writer.Hashed(Sha256) = .initHasher(writer, Sha256.init(.{}), &hash_buffer);

    try reader.streamExact64(&hashed.writer, expected_size);
    reader.fill(1) catch |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    };
    if (reader.bufferedLen() != 0) return error.StreamTooLong;

    try hashed.writer.flush();
    return hashed.hasher.finalResult();
}

const std = @import("std");
const release = @import("release.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const t = std.testing;

test "exact download writes bytes and computes SHA-256" {
    var reader = Io.Reader.fixed("abc");
    var output: Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();

    const actual = try copyExactAndHash(&reader, &output.writer, 3);
    var expected: release.Digest = undefined;
    Sha256.hash("abc", &expected, .{});

    try t.expectEqualStrings("abc", output.written());
    try t.expectEqual(expected, actual);
}

test "exact download rejects truncated and oversized bodies" {
    var short_reader = Io.Reader.fixed("ab");
    var short_output: Io.Writer.Allocating = .init(t.allocator);
    defer short_output.deinit();
    try t.expectError(error.EndOfStream, copyExactAndHash(&short_reader, &short_output.writer, 3));

    var long_reader = Io.Reader.fixed("abcd");
    var long_output: Io.Writer.Allocating = .init(t.allocator);
    defer long_output.deinit();
    try t.expectError(error.StreamTooLong, copyExactAndHash(&long_reader, &long_output.writer, 3));
}

test "HTTP response statuses have actionable error categories" {
    try requireOk(.ok);
    try t.expectError(error.HttpBadRequest, requireOk(.bad_request));
    try t.expectError(error.HttpUnauthorized, requireOk(.unauthorized));
    try t.expectError(error.HttpForbidden, requireOk(.forbidden));
    try t.expectError(error.HttpNotFound, requireOk(.not_found));
    try t.expectError(error.HttpRequestTimeout, requireOk(.request_timeout));
    try t.expectError(error.HttpRateLimited, requireOk(.too_many_requests));
    try t.expectError(error.HttpClientError, requireOk(.unprocessable_entity));
    try t.expectError(error.HttpServerError, requireOk(.service_unavailable));
    try t.expectError(error.HttpUnexpectedStatus, requireOk(.not_modified));
}
