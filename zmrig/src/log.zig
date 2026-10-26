//! Logger. Same shape as XMRig's output (time prefix, coloured level tags) so
//! existing tooling and human habits keep working.

const std = @import("std");
const util = @import("util.zig");

pub const Level = enum {
    info,
    warn,
    err,
    debug,

    fn tag(self: Level) []const u8 {
        return switch (self) {
            .info => "info",
            .warn => "warning",
            .err => "error",
            .debug => "debug",
        };
    }

    fn color(self: Level) []const u8 {
        return switch (self) {
            .info => "\x1b[1;32m",
            .warn => "\x1b[1;33m",
            .err => "\x1b[1;31m",
            .debug => "\x1b[1;35m",
        };
    }
};

pub const Logger = struct {
    mutex: std.Thread.Mutex = .{},
    file: ?std.fs.File = null,
    colors: bool = true,
    verbose: bool = false,
    /// Console lines go to stderr instead of stdout. Set by `--report`, where
    /// stdout carries exactly one machine readable line.
    stderr_sink: bool = false,

    const Self = @This();

    pub fn init(colors: bool, verbose: bool) Self {
        return .{ .colors = colors, .verbose = verbose };
    }

    pub fn openFile(self: *Self, path: []const u8) !void {
        self.file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = false });
        try self.file.?.seekFromEnd(0);
    }

    pub fn deinit(self: *Self) void {
        if (self.file) |f| f.close();
        self.file = null;
    }

    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.write(.info, fmt, args);
    }

    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.write(.warn, fmt, args);
    }

    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.write(.err, fmt, args);
    }

    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (self.verbose) self.write(.debug, fmt, args);
    }

    pub fn write(self: *Self, level: Level, comptime fmt: []const u8, args: anytype) void {
        var time_buf: [16]u8 = undefined;
        const time = util.logTime(&time_buf);

        var line_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const writer = stream.writer();

        writer.print("[{s}] ", .{time}) catch return;
        if (self.colors) {
            writer.print("{s}{s}\x1b[0m ", .{ level.color(), level.tag() }) catch return;
        } else {
            writer.print("{s} ", .{level.tag()}) catch return;
        }
        writer.print(fmt ++ "\n", args) catch return;

        const line = line_buf[0..stream.pos];

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stderr_sink) {
            _ = std.io.getStdErr().write(line) catch {};
        } else {
            _ = std.io.getStdOut().write(line) catch {};
        }

        if (self.file) |f| {
            // The file gets a plain line: escape codes in a log file are noise
            // for grep, journalctl and every log shipper.
            if (self.colors and std.mem.indexOfScalar(u8, line, 0x1b) != null) {
                var plain_buf: [4096]u8 = undefined;
                var plain_stream = std.io.fixedBufferStream(&plain_buf);
                const plain_writer = plain_stream.writer();

                plain_writer.print("[{s}] {s} ", .{ time, level.tag() }) catch {
                    f.writeAll(line) catch {};

                    return;
                };
                plain_writer.print(fmt ++ "\n", args) catch {
                    f.writeAll(line) catch {};

                    return;
                };

                f.writeAll(plain_buf[0..plain_stream.pos]) catch {};

                return;
            }

            f.writeAll(line) catch {};
        }
    }
};

/// Global logger, replaced by the instance configured in main().
pub var global: Logger = .{};
