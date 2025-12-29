const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const MAX_HEADER_SIZE = 8 * 1024;
const MAX_BODY_SIZE = 5 * 1024 * 1024 * 1024;
const MAX_KEY_LENGTH = 1024;
const MAX_BUCKET_LENGTH = 63;
const MAX_CONNECTIONS = 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.fs.cwd().makeDir("data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const address = net.Address.parseIp4("0.0.0.0", 9000) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("S3 server listening on http://0.0.0.0:9000", .{});

    const ctx = S3Context{
        .allocator = allocator,
        .data_dir = "data",
        .access_key = "minioadmin",
        .secret_key = "minioadmin",
    };

    if (builtin.os.tag == .linux) {
        try eventLoopEpoll(allocator, &ctx, &server);
    } else {
        try eventLoopPoll(allocator, &ctx, &server);
    }
}

fn eventLoopEpoll(allocator: Allocator, ctx: *const S3Context, server: *net.Server) !void {
    const linux = std.os.linux;
    const epfd = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (@as(isize, @bitCast(epfd)) < 0) return error.EpollCreate;
    defer _ = linux.close(@intCast(epfd));

    var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = server.stream.handle } };
    if (@as(isize, @bitCast(linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_ADD, server.stream.handle, &ev))) < 0)
        return error.EpollCtl;

    var events: [MAX_CONNECTIONS]linux.epoll_event = undefined;

    while (true) {
        const n = linux.epoll_wait(@intCast(epfd), &events, MAX_CONNECTIONS, -1);
        if (@as(isize, @bitCast(n)) < 0) continue;

        for (events[0..n]) |event| {
            if (event.data.fd == server.stream.handle) {
                while (true) {
                    const conn = server.accept() catch break;
                    var cev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .fd = conn.stream.handle } };
                    _ = linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_ADD, conn.stream.handle, &cev);
                }
            } else {
                const stream = net.Stream{ .handle = event.data.fd };
                handleConnectionWithStream(allocator, ctx, stream) catch {};
                _ = linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_DEL, event.data.fd, null);
                stream.close();
            }
        }
    }
}

fn setNonBlocking(fd: posix.fd_t) void {
    const O_NONBLOCK: usize = if (builtin.os.tag == .macos) 0x0004 else 0x800;
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) catch {};
}

fn eventLoopPoll(allocator: Allocator, ctx: *const S3Context, server: *net.Server) !void {
    var fds: [MAX_CONNECTIONS + 1]posix.pollfd = undefined;
    var nfds: usize = 1;

    setNonBlocking(server.stream.handle);
    fds[0] = .{ .fd = server.stream.handle, .events = posix.POLL.IN, .revents = 0 };

    while (true) {
        const ready = posix.poll(fds[0..nfds], -1) catch continue;
        if (ready == 0) continue;

        if (fds[0].revents & posix.POLL.IN != 0) {
            while (nfds <= MAX_CONNECTIONS) {
                const conn = server.accept() catch break;
                fds[nfds] = .{ .fd = conn.stream.handle, .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }

        var i: usize = 1;
        while (i < nfds) {
            if (fds[i].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                const stream = net.Stream{ .handle = fds[i].fd };
                handleConnectionWithStream(allocator, ctx, stream) catch {};
                stream.close();
                fds[i] = fds[nfds - 1];
                nfds -= 1;
            } else {
                i += 1;
            }
        }
    }
}

const S3Context = struct {
    allocator: Allocator,
    data_dir: []const u8,
    access_key: []const u8,
    secret_key: []const u8,

    fn bucketPath(self: *const S3Context, allocator: Allocator, bucket: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket });
    }

    fn objectPath(self: *const S3Context, allocator: Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket, key });
    }
};

const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var lower_buf: [128]u8 = undefined;
        const lower_name = std.ascii.lowerString(&lower_buf, name);
        return self.headers.get(lower_name);
    }

    fn deinit(self: *Request) void {
        self.headers.deinit();
    }
};

const Response = struct {
    status: u16 = 200,
    status_text: []const u8 = "OK",
    headers: std.ArrayListUnmanaged(Header) = .empty,
    body: []const u8 = "",
    allocator: Allocator,

    const Header = struct { name: []const u8, value: []const u8 };

    fn init(allocator: Allocator) Response {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
    }

    fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.append(self.allocator, .{ .name = name, .value = value }) catch {};
    }

    fn ok(self: *Response) void {
        self.status = 200;
        self.status_text = "OK";
    }

    fn noContent(self: *Response) void {
        self.status = 204;
        self.status_text = "No Content";
    }

    fn setXmlBody(self: *Response, body: []const u8) void {
        self.setHeader("Content-Type", "application/xml");
        self.body = body;
    }

    fn write(self: *Response, stream: net.Stream) !void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status, self.status_text });
        try w.print("Content-Length: {d}\r\n", .{self.body.len});
        try w.print("Connection: close\r\n", .{});

        for (self.headers.items) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll("\r\n");

        try stream.writeAll(fbs.getWritten());
        if (self.body.len > 0) {
            try stream.writeAll(self.body);
        }
    }
};

fn parseRequest(allocator: Allocator, stream: net.Stream) !Request {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const n = try stream.read(buf[total_read..]);
        if (n == 0) break;
        total_read += n;

        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |_| break;
    }

    if (total_read == 0) return error.ConnectionClosed;

    const data = buf[0..total_read];
    const line_end = std.mem.indexOf(u8, data, "\r\n") orelse return error.InvalidRequest;
    const request_line = data[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const full_path = parts.next() orelse return error.InvalidRequest;
    var path: []const u8 = full_path;
    var query: []const u8 = "";
    if (std.mem.indexOf(u8, full_path, "?")) |q_idx| {
        path = full_path[0..q_idx];
        query = full_path[q_idx + 1 ..];
    }

    var headers = std.StringHashMap([]const u8).init(allocator);
    var header_section = data[line_end + 2 ..];
    const header_end = std.mem.indexOf(u8, header_section, "\r\n\r\n") orelse header_section.len;
    header_section = header_section[0..header_end];

    var header_lines = std.mem.splitSequence(u8, header_section, "\r\n");
    while (header_lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        var name_buf: [128]u8 = undefined;
        const name = std.ascii.lowerString(&name_buf, std.mem.trim(u8, line[0..colon], " "));
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
    }

    var body: []const u8 = "";
    if (headers.get("content-length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
        if (content_length > MAX_BODY_SIZE) return error.PayloadTooLarge;
        if (content_length > 0) {
            const body_start_idx = std.mem.indexOf(u8, data, "\r\n\r\n").? + 4;
            const already_read = total_read - body_start_idx;

            const body_buf = try allocator.alloc(u8, content_length);
            if (already_read > 0) {
                @memcpy(body_buf[0..already_read], data[body_start_idx..total_read]);
            }

            var remaining = content_length - already_read;
            var offset = already_read;
            while (remaining > 0) {
                const n = try stream.read(body_buf[offset..]);
                if (n == 0) break;
                offset += n;
                remaining -= n;
            }
            body = body_buf;
        }
    }

    return Request{
        .method = try allocator.dupe(u8, method),
        .path = try allocator.dupe(u8, path),
        .query = try allocator.dupe(u8, query),
        .headers = headers,
        .body = body,
    };
}

fn handleConnectionWithStream(allocator: Allocator, ctx: *const S3Context, stream: net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req = try parseRequest(alloc, stream);
    defer req.deinit();

    var res = Response.init(alloc);
    defer res.deinit();

    route(ctx, alloc, &req, &res) catch |err| {
        std.log.err("Handler error: {}", .{err});
        sendError(&res, 500, "InternalError", "Internal server error");
    };

    try res.write(stream);
}

pub fn isValidBucketName(name: []const u8) bool {
    if (name.len < 3 or name.len > MAX_BUCKET_LENGTH) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return false;
    }
    if (name[0] == '-' or name[0] == '.' or name[name.len - 1] == '-' or name[name.len - 1] == '.') return false;
    return true;
}

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY_LENGTH) return false;
    for (key) |c| {
        if (c < 32 or c == 127) return false; // no control chars
    }
    return true;
}

fn route(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response) !void {
    if (!SigV4.verify(ctx, req, allocator)) {
        sendError(res, 403, "AccessDenied", "Invalid credentials");
        return;
    }

    var path = req.path;
    if (path.len > 0 and path[0] == '/') path = path[1..];

    var path_parts = std.mem.splitScalar(u8, path, '/');
    const bucket = path_parts.next() orelse "";
    const key = path_parts.rest();

    if (bucket.len > 0 and !isValidBucketName(bucket)) {
        sendError(res, 400, "InvalidBucketName", "Bucket name is invalid");
        return;
    }
    if (key.len > 0 and !isValidKey(key)) {
        sendError(res, 400, "InvalidKey", "Object key is invalid");
        return;
    }

    if (std.mem.eql(u8, req.method, "GET")) {
        if (bucket.len == 0) {
            try handleListBuckets(ctx, allocator, res);
        } else if (key.len == 0) {
            try handleListObjects(ctx, allocator, req, res, bucket);
        } else {
            try handleGetObject(ctx, allocator, req, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "PUT")) {
        if (key.len == 0) {
            try handleCreateBucket(ctx, allocator, res, bucket);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleUploadPart(ctx, allocator, req, res, bucket, key);
        } else {
            try handlePutObject(ctx, allocator, req, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "DELETE")) {
        if (key.len == 0) {
            try handleDeleteBucket(ctx, allocator, res, bucket);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleAbortMultipart(ctx, allocator, req, res);
        } else {
            try handleDeleteObject(ctx, allocator, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "HEAD")) {
        try handleHeadObject(ctx, allocator, res, bucket, key);
    } else if (std.mem.eql(u8, req.method, "POST")) {
        if (hasQuery(req.query, "uploads")) {
            try handleInitiateMultipart(ctx, allocator, res, bucket, key);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleCompleteMultipart(ctx, allocator, req, res, bucket, key);
        } else {
            sendError(res, 400, "InvalidRequest", "Unknown POST operation");
        }
    } else {
        sendError(res, 405, "MethodNotAllowed", "Method not allowed");
    }
}

pub const SigV4 = struct {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const Sha256 = std.crypto.hash.sha2.Sha256;

    const ParsedAuth = struct {
        access_key: []const u8,
        date: []const u8,
        region: []const u8,
        service: []const u8,
        signed_headers: []const u8,
        signature: []const u8,
    };

    fn verify(ctx: *const S3Context, req: *const Request, allocator: Allocator) bool {
        const auth_header = req.header("authorization") orelse return false;
        const x_amz_date = req.header("x-amz-date") orelse return false;
        const x_amz_content_sha256 = req.header("x-amz-content-sha256") orelse "UNSIGNED-PAYLOAD";

        const parsed = parseAuthHeader(auth_header) orelse return false;

        if (!std.mem.eql(u8, parsed.access_key, ctx.access_key)) return false;

        const canonical = buildCanonicalRequest(
            allocator,
            req,
            parsed.signed_headers,
            x_amz_content_sha256,
        ) catch return false;
        defer allocator.free(canonical);

        const string_to_sign = buildStringToSign(
            allocator,
            x_amz_date,
            parsed.date,
            parsed.region,
            parsed.service,
            canonical,
        ) catch return false;
        defer allocator.free(string_to_sign);

        const calculated_sig = calculateSignature(
            allocator,
            ctx.secret_key,
            parsed.date,
            parsed.region,
            parsed.service,
            string_to_sign,
        ) catch return false;
        defer allocator.free(calculated_sig);

        return std.mem.eql(u8, calculated_sig, parsed.signature);
    }

    pub fn parseAuthHeader(header: []const u8) ?ParsedAuth {
        if (!std.mem.startsWith(u8, header, "AWS4-HMAC-SHA256 ")) return null;

        var result: ParsedAuth = undefined;

        const cred_start = std.mem.indexOf(u8, header, "Credential=") orelse return null;
        const cred_end = std.mem.indexOfPos(u8, header, cred_start, ",") orelse return null;
        const credential = header[cred_start + 11 .. cred_end];

        var cred_iter = std.mem.splitScalar(u8, credential, '/');
        result.access_key = cred_iter.next() orelse return null;
        result.date = cred_iter.next() orelse return null;
        result.region = cred_iter.next() orelse return null;
        result.service = cred_iter.next() orelse return null;

        const sh_start = std.mem.indexOf(u8, header, "SignedHeaders=") orelse return null;
        const sh_end = std.mem.indexOfPos(u8, header, sh_start, ",") orelse return null;
        result.signed_headers = header[sh_start + 14 .. sh_end];

        const sig_start = std.mem.indexOf(u8, header, "Signature=") orelse return null;
        result.signature = header[sig_start + 10 ..];

        return result;
    }

    fn buildCanonicalRequest(
        allocator: Allocator,
        req: *const Request,
        signed_headers: []const u8,
        payload_hash: []const u8,
    ) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, req.method);
        try result.append(allocator, '\n');

        const canonical_path = if (req.path.len == 0) "/" else req.path;
        const encoded_path = try uriEncode(allocator, canonical_path, false);
        defer allocator.free(encoded_path);
        try result.appendSlice(allocator, encoded_path);
        try result.append(allocator, '\n');

        const sorted_query = try sortQueryString(allocator, req.query);
        defer allocator.free(sorted_query);
        try result.appendSlice(allocator, sorted_query);
        try result.append(allocator, '\n');

        var header_iter = std.mem.splitScalar(u8, signed_headers, ';');
        while (header_iter.next()) |header_name| {
            const value = req.header(header_name) orelse "";
            try result.appendSlice(allocator, header_name);
            try result.append(allocator, ':');
            try result.appendSlice(allocator, std.mem.trim(u8, value, " \t"));
            try result.append(allocator, '\n');
        }
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, signed_headers);
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, payload_hash);

        return result.toOwnedSlice(allocator);
    }

    fn buildStringToSign(
        allocator: Allocator,
        amz_date: []const u8,
        date_stamp: []const u8,
        region: []const u8,
        service: []const u8,
        canonical_request: []const u8,
    ) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "AWS4-HMAC-SHA256\n");
        try result.appendSlice(allocator, amz_date);
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, date_stamp);
        try result.append(allocator, '/');
        try result.appendSlice(allocator, region);
        try result.append(allocator, '/');
        try result.appendSlice(allocator, service);
        try result.appendSlice(allocator, "/aws4_request\n");

        const canonical_hash = hash(canonical_request);
        var hex_buf: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x}", .{canonical_hash}) catch unreachable;
        try result.appendSlice(allocator, &hex_buf);

        return result.toOwnedSlice(allocator);
    }

    fn calculateSignature(
        allocator: Allocator,
        secret_key: []const u8,
        date_stamp: []const u8,
        region: []const u8,
        service: []const u8,
        string_to_sign: []const u8,
    ) ![]const u8 {
        var k_secret_buf: [256]u8 = undefined;
        const k_secret_len = 4 + secret_key.len;
        @memcpy(k_secret_buf[0..4], "AWS4");
        @memcpy(k_secret_buf[4..k_secret_len], secret_key);

        const k_date = hmac(k_secret_buf[0..k_secret_len], date_stamp);
        const k_region = hmac(&k_date, region);
        const k_service = hmac(&k_region, service);
        const k_signing = hmac(&k_service, "aws4_request");
        const sig = hmac(&k_signing, string_to_sign);

        const hex = try allocator.alloc(u8, 64);
        _ = std.fmt.bufPrint(hex, "{x}", .{sig}) catch unreachable;

        return hex;
    }

    pub fn hmac(key: []const u8, msg: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        HmacSha256.create(&out, msg, key);
        return out;
    }

    pub fn hash(data: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        Sha256.hash(data, &out, .{});
        return out;
    }
};

pub fn uriEncode(allocator: Allocator, input: []const u8, encode_slash: bool) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (isUnreserved(c) or (c == '/' and !encode_slash)) {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try result.append(allocator, hex[c >> 4]);
            try result.append(allocator, hex[c & 0x0F]);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

pub fn sortQueryString(allocator: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return try allocator.dupe(u8, "");

    var pairs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pairs.deinit(allocator);

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len > 0) {
            try pairs.append(allocator, pair);
        }
    }

    std.mem.sort([]const u8, pairs.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (pairs.items, 0..) |pair, i| {
        if (i > 0) try result.append(allocator, '&');
        try result.appendSlice(allocator, pair);
    }

    return result.toOwnedSlice(allocator);
}

fn handlePutObject(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    var file = std.fs.cwd().createFile(path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create file");
        return;
    };
    defer file.close();

    file.writeAll(req.body) catch {
        sendError(res, 500, "InternalError", "Cannot write file");
        return;
    };

    const etag = SigV4.hash(req.body);
    var etag_hex: [66]u8 = undefined;
    _ = std.fmt.bufPrint(&etag_hex, "\"{x}\"", .{etag}) catch unreachable;

    res.ok();
    res.setHeader("ETag", &etag_hex);
}

fn handleGetObject(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        sendError(res, 500, "InternalError", "Stat failed");
        return;
    };

    if (req.header("range")) |range_header| {
        if (parseRange(range_header, stat.size)) |range| {
            file.seekTo(range.start) catch {};
            const len = range.end - range.start + 1;

            const data = allocator.alloc(u8, len) catch {
                sendError(res, 500, "InternalError", "Alloc failed");
                return;
            };
            _ = file.read(data) catch {
                sendError(res, 500, "InternalError", "Read failed");
                return;
            };

            var range_buf: [64]u8 = undefined;
            const content_range = std.fmt.bufPrint(&range_buf, "bytes {d}-{d}/{d}", .{ range.start, range.end, stat.size }) catch unreachable;

            res.status = 206;
            res.status_text = "Partial Content";
            res.setHeader("Content-Range", content_range);
            res.setHeader("Accept-Ranges", "bytes");
            res.body = data;
            return;
        }
    }

    const data = allocator.alloc(u8, stat.size) catch {
        sendError(res, 500, "InternalError", "Alloc failed");
        return;
    };
    _ = file.readAll(data) catch {
        sendError(res, 500, "InternalError", "Read failed");
        return;
    };

    res.ok();
    res.setHeader("Accept-Ranges", "bytes");
    res.body = data;
}

fn handleDeleteObject(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("delete failed: {}", .{err}),
    };

    // Clean up empty parent directories up to bucket level
    const bucket_path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(bucket_path);

    var dir_path = std.fs.path.dirname(path);
    while (dir_path) |dp| {
        if (dp.len <= bucket_path.len) break;
        std.fs.cwd().deleteDir(dp) catch break; // stop if not empty
        dir_path = std.fs.path.dirname(dp);
    }

    res.noContent();
}

fn handleHeadObject(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        sendError(res, 500, "InternalError", "Stat failed");
        return;
    };

    var buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&buf, "{d}", .{stat.size}) catch unreachable;

    res.ok();
    res.setHeader("Content-Length", len_str);
    res.setHeader("Accept-Ranges", "bytes");
}

fn handleListObjects(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8) !void {
    const prefix = getQueryParam(req.query, "prefix") orelse "";
    const max_keys_str = getQueryParam(req.query, "max-keys") orelse "1000";
    const max_keys = std.fmt.parseInt(usize, max_keys_str, 10) catch 1000;
    const delimiter = getQueryParam(req.query, "delimiter");
    const continuation = getQueryParam(req.query, "continuation-token");

    const bucket_path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(bucket_path);

    var dir = std.fs.cwd().openDir(bucket_path, .{ .iterate = true }) catch {
        sendError(res, 404, "NoSuchBucket", "Bucket not found");
        return;
    };
    defer dir.close();

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Name>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Name><Prefix>");
    try xml.appendSlice(allocator, prefix);
    try xml.appendSlice(allocator, "</Prefix><MaxKeys>");
    try xml.appendSlice(allocator, max_keys_str);
    try xml.appendSlice(allocator, "</MaxKeys>");

    var keys: std.ArrayListUnmanaged(KeyInfo) = .empty;
    defer keys.deinit(allocator);

    try collectKeys(allocator, bucket_path, "", prefix, &keys);

    std.mem.sort(KeyInfo, keys.items, {}, struct {
        fn lessThan(_: void, a: KeyInfo, b: KeyInfo) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    var start_idx: usize = 0;
    if (continuation) |cont| {
        for (keys.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.key, cont)) {
                start_idx = i + 1;
                break;
            }
        }
    }

    var common_prefixes = std.StringHashMap(void).init(allocator);
    defer common_prefixes.deinit();

    var count: usize = 0;
    var is_truncated = false;
    var next_token: ?[]const u8 = null;

    for (keys.items[start_idx..]) |item| {
        if (count >= max_keys) {
            is_truncated = true;
            next_token = item.key;
            break;
        }

        if (delimiter) |delim| {
            const after_prefix = if (prefix.len > 0 and std.mem.startsWith(u8, item.key, prefix))
                item.key[prefix.len..]
            else
                item.key;

            if (std.mem.indexOf(u8, after_prefix, delim)) |delim_idx| {
                const common_prefix = item.key[0 .. prefix.len + delim_idx + 1];
                if (!common_prefixes.contains(common_prefix)) {
                    try common_prefixes.put(common_prefix, {});
                    try xml.appendSlice(allocator, "<CommonPrefixes><Prefix>");
                    try xml.appendSlice(allocator, common_prefix);
                    try xml.appendSlice(allocator, "</Prefix></CommonPrefixes>");
                    count += 1;
                }
                continue;
            }
        }

        try xml.appendSlice(allocator, "<Contents><Key>");
        try xmlEscape(allocator, &xml, item.key);
        try xml.appendSlice(allocator, "</Key><Size>");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{item.size}) catch "0";
        try xml.appendSlice(allocator, size_str);
        try xml.appendSlice(allocator, "</Size><StorageClass>STANDARD</StorageClass></Contents>");
        count += 1;
    }

    if (is_truncated) {
        try xml.appendSlice(allocator, "<IsTruncated>true</IsTruncated>");
        if (next_token) |token| {
            try xml.appendSlice(allocator, "<NextContinuationToken>");
            try xml.appendSlice(allocator, token);
            try xml.appendSlice(allocator, "</NextContinuationToken>");
        }
    } else {
        try xml.appendSlice(allocator, "<IsTruncated>false</IsTruncated>");
    }

    try xml.appendSlice(allocator, "</ListBucketResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

const KeyInfo = struct {
    key: []const u8,
    size: u64,
};

fn collectKeys(allocator: Allocator, base_path: []const u8, current_prefix: []const u8, filter_prefix: []const u8, keys: *std.ArrayListUnmanaged(KeyInfo)) !void {
    const full_path = if (current_prefix.len > 0)
        try std.fs.path.join(allocator, &[_][]const u8{ base_path, current_prefix })
    else
        try allocator.dupe(u8, base_path);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;

        const full_key = if (current_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.kind == .directory) {
            try collectKeys(allocator, base_path, full_key, filter_prefix, keys);
            allocator.free(full_key);
        } else if (entry.kind == .file) {
            if (filter_prefix.len == 0 or std.mem.startsWith(u8, full_key, filter_prefix)) {
                const file_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, full_key });
                defer allocator.free(file_path);

                const size = blk: {
                    var file = std.fs.cwd().openFile(file_path, .{}) catch break :blk 0;
                    defer file.close();
                    const stat = file.stat() catch break :blk 0;
                    break :blk stat.size;
                };

                try keys.append(allocator, .{ .key = full_key, .size = size });
            } else {
                allocator.free(full_key);
            }
        }
    }
}

fn handleCreateBucket(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8) !void {
    const path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(path);

    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            sendError(res, 500, "InternalError", "Cannot create bucket");
            return;
        },
    };

    res.ok();
}

fn handleDeleteBucket(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8) !void {
    const path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(path);

    std.fs.cwd().deleteDir(path) catch |err| switch (err) {
        error.DirNotEmpty => {
            sendError(res, 409, "BucketNotEmpty", "Bucket is not empty");
            return;
        },
        else => std.log.warn("delete bucket failed: {}", .{err}),
    };

    res.noContent();
}

fn handleListBuckets(ctx: *const S3Context, allocator: Allocator, res: *Response) !void {
    var dir = std.fs.cwd().openDir(ctx.data_dir, .{ .iterate = true }) catch {
        sendError(res, 500, "InternalError", "Cannot open data dir");
        return;
    };
    defer dir.close();

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Owner><ID>minioadmin</ID><DisplayName>minioadmin</DisplayName></Owner>");
    try xml.appendSlice(allocator, "<Buckets>");

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;

        try xml.appendSlice(allocator, "<Bucket><Name>");
        try xmlEscape(allocator, &xml, entry.name);
        try xml.appendSlice(allocator, "</Name><CreationDate>2024-01-01T00:00:00.000Z</CreationDate></Bucket>");
    }

    try xml.appendSlice(allocator, "</Buckets></ListAllMyBucketsResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleInitiateMultipart(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const timestamp: u64 = @intCast(std.time.timestamp());
    var upload_id_buf: [32]u8 = undefined;
    const upload_id = std.fmt.bufPrint(&upload_id_buf, "{x}", .{timestamp}) catch unreachable;

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch return;
    defer allocator.free(parts_dir);
    std.fs.cwd().makePath(parts_dir) catch {};

    const meta_path = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}/.meta", .{ ctx.data_dir, upload_id }) catch return;
    defer allocator.free(meta_path);

    var meta_file = std.fs.cwd().createFile(meta_path, .{}) catch return;
    defer meta_file.close();
    const meta_content = std.fmt.allocPrint(allocator, "{s}\n{s}", .{ bucket, key }) catch return;
    defer allocator.free(meta_content);
    meta_file.writeAll(meta_content) catch {};

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Bucket>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Bucket><Key>");
    try xmlEscape(allocator, &xml, key);
    try xml.appendSlice(allocator, "</Key><UploadId>");
    try xml.appendSlice(allocator, upload_id);
    try xml.appendSlice(allocator, "</UploadId></InitiateMultipartUploadResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleUploadPart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    _ = bucket;
    _ = key;

    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };
    const part_number = getQueryParam(req.query, "partNumber") orelse {
        sendError(res, 400, "InvalidRequest", "Missing partNumber");
        return;
    };

    const part_path = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}/{s}", .{ ctx.data_dir, upload_id, part_number }) catch return;
    defer allocator.free(part_path);

    var file = std.fs.cwd().createFile(part_path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create part file");
        return;
    };
    defer file.close();

    file.writeAll(req.body) catch {
        sendError(res, 500, "InternalError", "Cannot write part");
        return;
    };

    const etag = SigV4.hash(req.body);
    var etag_hex: [66]u8 = undefined;
    _ = std.fmt.bufPrint(&etag_hex, "\"{x}\"", .{etag}) catch unreachable;

    res.ok();
    res.setHeader("ETag", &etag_hex);
}

fn handleCompleteMultipart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch {
        sendError(res, 500, "InternalError", "Allocation failed");
        return;
    };
    defer allocator.free(parts_dir);

    const final_path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(final_path);

    if (std.fs.path.dirname(final_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            std.log.warn("makePath failed: {}", .{err});
        };
    }

    var final_file = std.fs.cwd().createFile(final_path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create final file");
        return;
    };
    defer final_file.close();

    var dir = std.fs.cwd().openDir(parts_dir, .{ .iterate = true }) catch {
        sendError(res, 404, "NoSuchUpload", "Upload not found");
        return;
    };
    defer dir.close();

    var parts: std.ArrayListUnmanaged(u32) = .empty;
    defer parts.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and entry.name[0] != '.') {
            const num = std.fmt.parseInt(u32, entry.name, 10) catch continue;
            try parts.append(allocator, num);
        }
    }

    std.mem.sort(u32, parts.items, {}, std.sort.asc(u32));

    var hasher = std.crypto.hash.Md5.init(.{});
    var parts_assembled: usize = 0;

    for (parts.items) |part_num| {
        var part_num_buf: [16]u8 = undefined;
        const part_num_str = std.fmt.bufPrint(&part_num_buf, "{d}", .{part_num}) catch continue;
        const part_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ parts_dir, part_num_str }) catch {
            std.log.warn("allocation failed for part path", .{});
            continue;
        };
        defer allocator.free(part_path);

        var part_file = std.fs.cwd().openFile(part_path, .{}) catch |err| {
            std.log.warn("failed to open part {d}: {}", .{ part_num, err });
            continue;
        };
        defer part_file.close();

        const stat = part_file.stat() catch continue;
        const data = allocator.alloc(u8, stat.size) catch continue;
        defer allocator.free(data);

        const bytes_read = part_file.readAll(data) catch continue;
        final_file.writeAll(data[0..bytes_read]) catch |err| {
            std.log.warn("failed to write part {d}: {}", .{ part_num, err });
            continue;
        };

        var part_hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data[0..bytes_read], &part_hash, .{});
        hasher.update(&part_hash);
        parts_assembled += 1;
    }

    std.fs.cwd().deleteTree(parts_dir) catch |err| {
        std.log.warn("failed to cleanup upload dir: {}", .{err});
    };

    var final_hash: [16]u8 = undefined;
    hasher.final(&final_hash);

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Bucket>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Bucket><Key>");
    try xmlEscape(allocator, &xml, key);

    var etag_buf: [48]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "</Key><ETag>\"{x}-{d}\"</ETag>", .{ final_hash, parts_assembled }) catch "</Key><ETag>\"\"</ETag>";
    try xml.appendSlice(allocator, etag);
    try xml.appendSlice(allocator, "</CompleteMultipartUploadResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleAbortMultipart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response) !void {
    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch {
        sendError(res, 500, "InternalError", "Allocation failed");
        return;
    };
    defer allocator.free(parts_dir);

    std.fs.cwd().deleteTree(parts_dir) catch |err| {
        std.log.warn("abort multipart cleanup failed: {}", .{err});
    };

    res.noContent();
}

pub const Range = struct { start: u64, end: u64 };

pub fn parseRange(header: []const u8, file_size: u64) ?Range {
    if (!std.mem.startsWith(u8, header, "bytes=")) return null;
    const range_spec = header[6..];

    const dash = std.mem.indexOf(u8, range_spec, "-") orelse return null;
    const start_str = range_spec[0..dash];
    const end_str = range_spec[dash + 1 ..];

    const start = if (start_str.len > 0) std.fmt.parseInt(u64, start_str, 10) catch return null else 0;
    const end = if (end_str.len > 0) std.fmt.parseInt(u64, end_str, 10) catch return null else file_size - 1;

    if (start > end or end >= file_size) return null;
    return .{ .start = start, .end = end };
}

pub fn hasQuery(query: []const u8, key: []const u8) bool {
    if (std.mem.indexOf(u8, query, key)) |idx| {
        if (idx == 0) return true;
        if (query[idx - 1] == '&') return true;
    }
    return false;
}

pub fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
            if (std.mem.eql(u8, pair[0..eq_idx], key)) {
                return pair[eq_idx + 1 ..];
            }
        } else {
            if (std.mem.eql(u8, pair, key)) {
                return "";
            }
        }
    }
    return null;
}

pub fn xmlEscape(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '&' => try list.appendSlice(allocator, "&amp;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&apos;"),
            else => try list.append(allocator, c),
        }
    }
}

fn sendError(res: *Response, status: u16, code: []const u8, message: []const u8) void {
    res.status = status;
    res.status_text = switch (status) {
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        else => "Error",
    };
    res.setHeader("Content-Type", "application/xml");

    res.body = std.fmt.allocPrint(res.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>{s}</Code><Message>{s}</Message></Error>", .{ code, message }) catch return;
}

