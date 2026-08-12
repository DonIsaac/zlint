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

const max_redirect_url_len = 2048;
const release_redirect_hosts = [_][]const u8{"api.github.com"};

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

pub fn fetchRelease(self: *Self, url: []const u8) ![]u8 {
    var head_buffer: [8 * 1024]u8 = undefined;
    var url_buffer: [max_redirect_url_len]u8 = undefined;
    // SAFETY: assigned by `openHttps` before it returns successfully.
    var request: std.http.Client.Request = undefined;
    var response = try self.openHttps(&request, &url_buffer, &head_buffer, url, 3, &release_headers, &release_redirect_hosts);
    defer request.deinit();
    try requireOk(response.head.status);

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    return reader.allocRemaining(self.allocator, .limited(metadata_limit));
}

/// The caller syncs and closes `destination`.
pub fn downloadAsset(
    self: *Self,
    url: []const u8,
    expected_size: u64,
    destination: *Io.File,
) !release.Digest {
    var head_buffer: [8 * 1024]u8 = undefined;
    var url_buffer: [max_redirect_url_len]u8 = undefined;
    // SAFETY: assigned by `openHttps` before it returns successfully.
    var request: std.http.Client.Request = undefined;
    var response = try self.openHttps(
        &request,
        &url_buffer,
        &head_buffer,
        url,
        5,
        &asset_headers,
        null,
    );
    defer request.deinit();
    try requireOk(response.head.status);
    if (response.head.content_length) |content_length| {
        if (content_length != expected_size) return error.DownloadSizeMismatch;
    }

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = destination.writer(self.io, &file_buffer);
    var transfer_buffer: [64]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    const digest = try copyExactAndHash(
        response_reader,
        &file_writer.interface,
        expected_size,
    );
    try file_writer.interface.flush();
    return digest;
}

/// `std.http.Client` derives each hop's protocol from the redirect URI's
/// scheme, so its built-in redirect handling silently downgrades to plaintext.
///
/// `request_out` is caller-owned; the returned response borrows it, and the
/// caller must `deinit` it on success.
fn openHttps(
    self: *Self,
    request_out: *std.http.Client.Request,
    url_buffer: *[max_redirect_url_len]u8,
    head_buffer: []u8,
    url: []const u8,
    max_redirects: u8,
    extra_headers: []const std.http.Header,
    /// `Location` reidrect allowlist
    allowed_hosts: ?[]const []const u8,
) !std.http.Client.Response {
    var current = url;
    var remaining = max_redirects;
    while (true) {
        request_out.* = try self.get(current, extra_headers);
        errdefer request_out.deinit();

        try request_out.sendBodiless();
        var response = try request_out.receiveHead(head_buffer);
        if (response.head.status.class() != .redirect) return response;

        if (remaining == 0) return error.TooManyHttpRedirects;
        remaining -= 1;

        const location = response.head.location orelse return error.HttpRedirectLocationMissing;
        // Copy before deinit; `location` points into the response head.
        current = try copyHttpsLocation(url_buffer, location, allowed_hosts);
        request_out.deinit();
    }
}

/// Relative locations are rejected rather than resolved; GitHub always sends
/// absolute URLs, so failing closed beats reimplementing URI resolution.
fn copyHttpsLocation(
    buffer: *[max_redirect_url_len]u8,
    location: []const u8,
    allowed_hosts: ?[]const []const u8,
) ![]const u8 {
    const uri = std.Uri.parse(location) catch return error.InsecureRedirect;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureRedirect;
    if (allowed_hosts) |hosts| {
        if (!isAllowedHost(uri.host, hosts)) return error.RedirectHostNotAllowed;
    }
    if (location.len > buffer.len) return error.RedirectLocationTooLong;

    @memcpy(buffer[0..location.len], location);
    return buffer[0..location.len];
}

fn isAllowedHost(
    host: ?std.Uri.Component,
    allowed_hosts: []const []const u8,
) bool {
    const name = switch (host orelse return false) {
        .raw, .percent_encoded => |text| text,
    };
    for (allowed_hosts) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}

fn get(
    self: *Self,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !std.http.Client.Request {
    return self.http.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
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

test "redirects may not leave HTTPS" {
    var buffer: [max_redirect_url_len]u8 = undefined;

    const absolute = "https://objects.githubusercontent.com/zlint-linux-x86_64";
    try t.expectEqualStrings(absolute, try copyHttpsLocation(&buffer, absolute, null));
    try t.expectEqualStrings("HTTPS://EXAMPLE.COM/x", try copyHttpsLocation(&buffer, "HTTPS://EXAMPLE.COM/x", null));

    try t.expectError(error.InsecureRedirect, copyHttpsLocation(&buffer, "http://evil.example/zlint", null));
    try t.expectError(error.InsecureRedirect, copyHttpsLocation(&buffer, "/next", null));
    try t.expectError(error.InsecureRedirect, copyHttpsLocation(&buffer, "evil.example/zlint", null));
    try t.expectError(error.InsecureRedirect, copyHttpsLocation(&buffer, "ftp://example.com/zlint", null));

    const too_long = "https://example.com/" ++ ("a" ** max_redirect_url_len);
    try t.expectError(error.RedirectLocationTooLong, copyHttpsLocation(&buffer, too_long, null));
}

test "release metadata redirects may not leave GitHub" {
    var buffer: [max_redirect_url_len]u8 = undefined;
    const hosts: []const []const u8 = &release_redirect_hosts;

    const same_host = "https://api.github.com/repos/DonIsaac/zlint/releases/29";
    try t.expectEqualStrings(same_host, try copyHttpsLocation(&buffer, same_host, hosts));
    try t.expectEqualStrings("https://API.GITHUB.COM/x", try copyHttpsLocation(&buffer, "https://API.GITHUB.COM/x", hosts));

    try t.expectError(error.RedirectHostNotAllowed, copyHttpsLocation(&buffer, "https://evil.example/releases", hosts));
    try t.expectError(error.RedirectHostNotAllowed, copyHttpsLocation(&buffer, "https://api.github.com.evil.example/x", hosts));
    try t.expectError(error.RedirectHostNotAllowed, copyHttpsLocation(&buffer, "https://api.github.com@evil.example/x", hosts));
    try t.expectError(error.RedirectHostNotAllowed, copyHttpsLocation(&buffer, "https:///x", hosts));
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
