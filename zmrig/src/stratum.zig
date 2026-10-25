//! Stratum client: pool connection, login, job parsing, share submission.
//!
//! Speaks the same dialect XMRig uses (line delimited JSON, `login` / `job` /
//! `submit` / `keepalived`), including the MoneroOcean `algo` extension that
//! lets a pool switch the miner between RandomX forks.

const std = @import("std");
const api = @import("api.zig");
const job = @import("job.zig");
const log = @import("log.zig");
const options = @import("options.zig");
const transport = @import("transport.zig");
const util = @import("util.zig");

pub const agent = "zmrig/6.26.0-mo9";

pub const ConnectError = error{
    ConnectFailed,
    TlsInitFailed,
    NoCertificateBundle,
    OutOfMemory,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    conn: *transport.Conn,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, pool: *const options.Pool, logger: *log.Logger) ConnectError!*Self {
        const target = transport.Target{
            .kind = pool.transport,
            .host = pool.host,
            .port = pool.port,
            .path = pool.ws_path orelse "/",
            .host_header = pool.host_header,
            .origin = pool.ws_origin,
            .connect_host = pool.connect_host,
            .connect_port = pool.connect_port,
            .tls_ca = pool.tls_ca,
            .proxy = pool.proxy(),
            .user_agent = agent,
        };

        const conn = transport.Conn.open(allocator, target, logger) catch |e| {
            logger.warn("connect to {s}://{s}:{d} failed: {s}", .{ pool.transport.label(), pool.host, pool.port, @errorName(e) });

            return error.ConnectFailed;
        };

        const self = allocator.create(Self) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        self.* = .{ .allocator = allocator, .conn = conn };

        return self;
    }

    pub fn close(self: *Self) void {
        self.conn.destroy();
    }

    pub fn destroy(self: *Self) void {
        self.close();
        self.allocator.destroy(self);
    }

    fn fill(self: *Self) !void {
        if (self.start > 0 and self.start < self.end) {
            std.mem.copyForwards(u8, self.buf[0..], self.buf[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        } else if (self.start >= self.end) {
            self.start = 0;
            self.end = 0;
        }

        const n = self.conn.read(self.buf[self.end..]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConnectionClosed,
        };

        if (n == 0) return error.ConnectionClosed;

        self.end += n;
    }

    /// Returns one line without the trailing newline. The slice stays valid
    /// until the next call.
    pub fn readLine(self: *Self, max_len: usize) ![]const u8 {
        while (true) {
            // Always search from `start`: fill() compacts the buffer and shifts
            // every index, so a cached scan offset would look past the data and
            // hand out the wrong bytes (that is how replies got lost before).
            if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], '\n')) |offset| {
                const pos = self.start + offset;
                var line = self.buf[self.start..pos];
                self.start = pos + 1;

                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

                return line;
            }

            if (self.end - self.start >= max_len) return error.LineTooLong;
            if (self.end == self.buf.len) return error.LineTooLong;

            try self.fill();
        }
    }

    pub fn writeLine(self: *Self, line: []const u8) !void {
        self.conn.writeMessage(line) catch return error.ConnectionClosed;
    }

    /// File descriptor of the underlying socket, used by the silence watchdog.
    pub fn handle(self: *Self) std.posix.socket_t {
        return self.conn.stream.handle;
    }
};

fn setKeepAlive(fd: std.posix.socket_t) void {
    const on: c_int = 1;

    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&on)) catch {};
}

/// `{"id":N,"jsonrpc":"2.0","method":"submit","params":{...}}`
pub const Session = struct {
    allocator: std.mem.Allocator,
    conn: *Connection,
    pool: options.Pool,
    next_id: u64 = 1,
    logger: *log.Logger,
    supports_algo_extension: bool = false,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, pool: options.Pool, logger: *log.Logger) !Self {
        const conn = try Connection.open(allocator, &pool, logger);

        return .{ .allocator = allocator, .conn = conn, .pool = pool, .logger = logger };
    }

    pub fn close(self: *Self) void {
        self.conn.destroy();
    }

    fn allocId(self: *Self) u64 {
        const id = self.next_id;
        self.next_id += 1;

        return id;
    }

    /// Sends the login request and waits for the first job.
    pub fn login(self: *Self, algo: ?api.Algo, out_job: *job.Job) !void {
        var params: std.ArrayListUnmanaged(u8) = .{};
        defer params.deinit(self.allocator);

        const w = params.writer(self.allocator);

        try w.print("{{\"login\":\"{s}\",\"pass\":\"{s}\",\"agent\":\"{s}\"", .{ self.pool.user, self.pool.password, agent });
        if (self.pool.rig_id) |rig| try w.print(",\"rigid\":\"{s}\"", .{rig});
        if (algo) |a| try w.print(",\"algo\":[\"{s}\"]", .{a.label()});
        try w.writeAll(",\"extensions\":[\"algo\",\"keepalive\"]}");

        const line = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"login\",\"params\":{s}}}", .{ self.allocId(), params.items });
        defer self.allocator.free(line);

        try self.conn.writeLine(line);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // The pool may push a keepalived before the login result, so loop.
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            const text = try self.conn.readLine(64 * 1024);
            if (text.len == 0) continue;

            const message = parseMessage(arena.allocator(), text, self.logger) catch |e| {
                self.logger.debug("unparsable login reply ({s}): {s}", .{ @errorName(e), text });
                continue;
            };

            switch (message) {
                .reply => |reply| {
                    if (!reply.ok) {
                        self.logger.err("login rejected: {s}", .{reply.message orelse "unknown error"});
                        return error.LoginRejected;
                    }
                    if (reply.job) |pool_job| {
                        out_job.* = pool_job;
                        return;
                    }
                },
                .job => |pool_job| {
                    out_job.* = pool_job;
                    return;
                },
                .keepalive, .other => continue,
            }
        }

        return error.LoginRejected;
    }

    pub const Message = union(enum) {
        job: job.Job,
        reply: Reply,
        keepalive,
        other: []const u8,
    };

    pub const Reply = struct {
        id: u64,
        ok: bool,
        message: ?[]const u8 = null,
        job: ?job.Job = null,
    };

    pub fn next(self: *Self, arena: std.mem.Allocator, default_algo: api.Algo) !Message {
        while (true) {
            const text = try self.conn.readLine(64 * 1024);
            if (text.len == 0) continue;

            const message = parseMessage(arena, text, self.logger) catch |e| {
                self.logger.debug("ignoring unparsable message ({s}): {s}", .{ @errorName(e), text });
                continue;
            };

            switch (message) {
                .reply => |reply| {
                    if (reply.job) |_| {
                        // A login-style reply that also carries a job.
                        return message;
                    }
                    if (reply.ok and reply.message == null) return message;
                },
                else => {},
            }

            _ = default_algo;

            return message;
        }
    }

    pub fn submit(self: *Self, job_id: []const u8, nonce: u32, hash: *const [32]u8, height: u64, algo: api.Algo) !u64 {
        const nonce_hex = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{nonce});
        defer self.allocator.free(nonce_hex);

        const hash_hex = try util.bytesToHex(self.allocator, hash);
        defer self.allocator.free(hash_hex);

        const id = self.allocId();
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"submit\",\"params\":{{\"id\":\"{s}\",\"job_id\":\"{s}\",\"nonce\":\"{s}\",\"result\":\"{s}\",\"algo\":\"{s}\",\"height\":{d}}}}}",
            .{ id, self.pool.rig_id orelse self.pool.user, job_id, nonce_hex, hash_hex, algo.label(), height },
        );
        defer self.allocator.free(line);

        try self.conn.writeLine(line);

        return id;
    }

    pub fn keepalive(self: *Self) !void {
        const line = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"keepalived\",\"params\":{{\"id\":\"{s}\"}}}}", .{ self.allocId(), self.pool.rig_id orelse self.pool.user });
        defer self.allocator.free(line);

        try self.conn.writeLine(line);
    }
};

fn parseJobObject(obj: std.json.ObjectMap, default_algo: api.Algo) !job.Job {
    var result = job.Job.init();
    result.setAlgo(default_algo);

    if (obj.get("algo")) |algo_value| {
        if (algo_value == .string) {
            if (api.Algo.fromName(algo_value.string)) |algo| result.setAlgo(algo);
        }
    }

    const blob_value = obj.get("blob") orelse return error.MissingBlob;
    if (blob_value != .string) return error.MissingBlob;
    try result.setBlob(blob_value.string);

    const target_value = obj.get("target") orelse return error.MissingTarget;
    if (target_value != .string) return error.MissingTarget;
    try result.setTarget(target_value.string);

    if (obj.get("job_id")) |id_value| {
        if (id_value == .string) result.setId(id_value.string);
    }

    if (obj.get("height")) |height_value| {
        if (height_value == .integer) result.height = @intCast(@max(height_value.integer, 0));
    }

    if (obj.get("seed_hash")) |seed_value| {
        if (seed_value == .string) {
            result.setSeed(seed_value.string) catch return error.InvalidSeed;
        }
    }

    if (obj.get("next_seed_hash")) |seed_value| {
        if (seed_value == .string) {
            result.setNextSeed(seed_value.string) catch return error.InvalidSeed;
        }
    }

    if (result.blob_len <= result.nonce_offset + result.nonce_size) return error.ShortBlob;

    return result;
}

fn parseMessage(arena: std.mem.Allocator, text: []const u8, logger: *log.Logger) !Session.Message {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    _ = &parsed;

    const root = switch (parsed) {
        .object => |obj| obj,
        else => return error.NotAnObject,
    };

    if (root.get("method")) |method_value| {
        if (method_value == .string) {
            const method = method_value.string;

            if (std.mem.eql(u8, method, "job")) {
                const params = root.get("params") orelse return error.MissingParams;
                if (params != .object) return error.MissingParams;

                const default_algo = if (root.get("algo")) |a| blk: {
                    if (a == .string) {
                        if (api.Algo.fromName(a.string)) |algo| break :blk algo;
                    }
                    break :blk api.Algo.rx_0;
                } else api.Algo.rx_0;

                return .{ .job = try parseJobObject(params.object, default_algo) };
            }

            if (std.mem.eql(u8, method, "keepalived")) return .keepalive;

            logger.debug("pool sent method {s}", .{method});

            return .{ .other = try arena.dupe(u8, method) };
        }
    }

    // Reply to one of our requests.
    var reply = Session.Reply{ .id = 0, .ok = true };

    if (root.get("id")) |id_value| {
        reply.id = switch (id_value) {
            .integer => |v| @intCast(@max(v, 0)),
            .string => |v| std.fmt.parseInt(u64, v, 10) catch 0,
            else => 0,
        };
    }

    if (root.get("error")) |error_value| {
        if (error_value != .null) {
            reply.ok = false;
            reply.message = switch (error_value) {
                .object => |obj| blk: {
                    if (obj.get("message")) |m| {
                        if (m == .string) break :blk try arena.dupe(u8, m.string);
                    }
                    break :blk try arena.dupe(u8, "unknown pool error");
                },
                .string => |s| try arena.dupe(u8, s),
                else => try arena.dupe(u8, "unknown pool error"),
            };
        }
    }

    if (root.get("result")) |result_value| {
        if (result_value == .object) {
            const result = result_value.object;

            if (result.get("status")) |status| {
                if (status == .string and !std.mem.eql(u8, status.string, "OK") and !std.mem.eql(u8, status.string, "KEEPALIVED")) {
                    reply.ok = false;
                    if (reply.message == null) reply.message = try arena.dupe(u8, status.string);
                }
            }

            if (result.get("job")) |job_value| {
                if (job_value == .object) {
                    reply.job = parseJobObject(job_value.object, api.Algo.rx_0) catch null;
                }
            }
        }
    }

    return .{ .reply = reply };
}
