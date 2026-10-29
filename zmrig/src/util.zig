//! Small helpers shared by the miner: hex, numbers, human readable sizes and
//! time formatting. Kept allocation free so the hot paths stay predictable.

const std = @import("std");

pub fn hexToBytes(out: []u8, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const n = text.len / 2;
    if (out.len < n) return error.NoSpaceLeft;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = (try hexVal(text[i * 2])) << 4 | try hexVal(text[i * 2 + 1]);
    }

    return out[0..n];
}

pub fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

pub fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const table = "0123456789abcdef";

    for (bytes, 0..) |byte, i| {
        out[i * 2] = table[byte >> 4];
        out[i * 2 + 1] = table[byte & 0x0f];
    }

    return out;
}

/// Reads a little-endian u32/u64 from a byte slice, like XMRig casts its
/// buffers on x86.
pub fn readLe(comptime T: type, bytes: []const u8, offset: usize) T {
    var value: T = 0;

    inline for (0..@sizeOf(T)) |i| {
        value |= @as(T, bytes[offset + i]) << (8 * @as(T, i));
    }

    return value;
}

pub fn writeLe(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    inline for (0..@sizeOf(T)) |i| {
        bytes[offset + i] = @truncate(value >> (8 * @as(T, i)));
    }
}

pub const HashrateFormat = struct {
    value: f64,
    unit: []const u8,
};

pub fn scaleHashrate(hps: f64) HashrateFormat {
    const units = [_][]const u8{ "H/s", "kH/s", "MH/s", "GH/s", "TH/s" };
    var value = hps;
    var unit: usize = 0;

    while (value >= 1000.0 and unit + 1 < units.len) : (unit += 1) {
        value /= 1000.0;
    }

    return .{ .value = value, .unit = units[unit] };
}

/// Human readable byte size, e.g. "2336 MB".
pub fn formatBytes(buf: []u8, bytes: usize) []const u8 {
    const mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "{d} MB", .{mb}) catch buf[0..0];
}

/// "12:34:56" style runtime clock used by the log line prefix.
pub fn logTime(buf: []u8) []const u8 {
    const now = std.time.timestamp();
    const seconds_of_day: u64 = @intCast(@mod(now, 86400));

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        seconds_of_day / 3600,
        (seconds_of_day / 60) % 60,
        seconds_of_day % 60,
    }) catch buf[0..0];
}

/// Elapsed time as "3m 42s" / "12s".
pub fn formatElapsed(buf: []u8, seconds_in: u64) []const u8 {
    const hours = seconds_in / 3600;
    const minutes = (seconds_in % 3600) / 60;
    const seconds = seconds_in % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, minutes, seconds }) catch buf[0..0];
    }
    if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch buf[0..0];
}

test "hex roundtrip" {
    var buf: [4]u8 = undefined;
    const bytes = try hexToBytes(&buf, "deadBEEF");
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, bytes);
    try std.testing.expectError(error.InvalidHex, hexToBytes(&buf, "abc"));
}

test "little endian" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    try std.testing.expectEqual(@as(u32, 0x04030201), readLe(u32, &bytes, 0));
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), readLe(u64, &bytes, 0));
}

/// Writes `text` as the body of a JSON string (without the quotes), escaping
/// everything the JSON grammar requires. A password or rig id is user input:
/// pasting one containing a quote must not turn a login into malformed JSON.
pub fn writeJsonString(writer: anytype, text: []const u8) !void {
    for (text) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            }
        },
    };
}

test "json string escaping" {
    const testing = std.testing;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    try writeJsonString(buf.writer(testing.allocator), "pa\"ss\\w\nrd\t\x01");
    try testing.expectEqualStrings("pa\\\"ss\\\\w\\nrd\\t\\u0001", buf.items);
}
