//! Mining job: the blob the pool wants hashed plus the difficulty target.
//!
//! Semantics are copied 1:1 from src/base/net/stratum/Job.cpp so shares are
//! accepted by the pool exactly as they are with XMRig.

const std = @import("std");
const api = @import("api.zig");
const util = @import("util.zig");

pub const max_blob_size = 512;

pub const Job = struct {
    const Self = @This();

    blob: [max_blob_size]u8 = undefined,
    blob_len: usize = 0,
    target: u64 = 0,
    id: [96]u8 = undefined,
    id_len: usize = 0,
    algo: api.Algo = .rx_0,
    height: u64 = 0,
    seed: [32]u8 = [_]u8{0} ** 32,
    has_seed: bool = false,
    next_seed: [32]u8 = [_]u8{0} ** 32,
    has_next_seed: bool = false,
    nonce_offset: usize = 39,
    nonce_size: usize = 4,
    /// Bumped every time a new job is published, workers poll this.
    generation: u64 = 0,

    pub fn init() Self {
        return .{};
    }

    pub fn idSlice(self: *const Self) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn blobSlice(self: *const Self) []const u8 {
        return self.blob[0..self.blob_len];
    }

    pub fn setBlob(self: *Self, text: []const u8) !void {
        const bytes = try util.hexToBytes(&self.blob, text);
        self.blob_len = bytes.len;
    }

    /// Exact port of Job::setTarget():
    ///   * 8 hex chars are a 32 bit target, converted to a 64 bit one,
    ///   * 16 hex chars are a 64 bit target,
    ///   * RX_YADA (panthera) sends the number itself.
    pub fn setTarget(self: *Self, text: []const u8) !void {
        if (text.len == 0 or text.len < 4) return error.InvalidTarget;

        if (self.algo == .rx_xla) {
            self.target = std.fmt.parseInt(u64, text, 16) catch return error.InvalidTarget;

            return;
        }

        var raw: [8]u8 = undefined;
        if (text.len > raw.len * 2) return error.InvalidTarget;

        const bytes = try util.hexToBytes(&raw, text);

        self.target = switch (bytes.len) {
            4 => blk: {
                const target32 = util.readLe(u32, bytes, 0);
                if (target32 == 0) return error.InvalidTarget;

                const max32: u32 = 0xFFFFFFFF;
                const max64: u64 = 0xFFFFFFFFFFFFFFFF;

                break :blk max64 / (max32 / target32);
            },
            8 => util.readLe(u64, bytes, 0),
            else => return error.InvalidTarget,
        };

        if (self.target == 0) return error.InvalidTarget;
    }

    pub fn setAlgo(self: *Self, algo: api.Algo) void {
        self.algo = algo;
        // Same offsets as Job::nonceOffset().
        self.nonce_offset = if (algo == .rx_xla) 147 else 39;
    }

    pub fn setSeed(self: *Self, text: []const u8) !void {
        const bytes = try util.hexToBytes(&self.seed, text);
        if (bytes.len != 32) return error.InvalidSeed;

        self.has_seed = true;
    }

    pub fn setNextSeed(self: *Self, text: []const u8) !void {
        const bytes = try util.hexToBytes(&self.next_seed, text);
        if (bytes.len != 32) return error.InvalidSeed;

        self.has_next_seed = true;
    }

    pub fn setId(self: *Self, text: []const u8) void {
        self.id_len = @min(text.len, self.id.len);
        @memcpy(self.id[0..self.id_len], text[0..self.id_len]);
    }

    /// The pool accepts a share when the top 64 bits of the hash, read little
    /// endian, are below the target (CpuWorker.cpp does the same comparison).
    pub fn hashMeetsTarget(self: *const Self, hash: *const [32]u8) bool {
        return util.readLe(u64, hash, 24) < self.target;
    }

    pub fn nonce(self: *const Self) u32 {
        return util.readLe(u32, self.blobSlice(), self.nonce_offset);
    }

    pub fn setNonce(self: *Self, value: u32) void {
        util.writeLe(u32, self.blob[0..self.blob_len], self.nonce_offset, value);
    }

    /// Difficulty for display, mirroring Job::toDiff().
    pub fn diff(self: *const Self) f64 {
        return 18446744073709551615.0 / @as(f64, @floatFromInt(self.target));
    }
};

test "target parsing matches xmrig" {
    var job = Job.init();

    // 4 byte target: bytes 0xFFFFFFFF written as a hex string with a 32 bit
    // value of 0x000000FF -> 0xFFFFFFFF / 0xFF.
    try job.setTarget("ff000000");
    const t32: u32 = 0x000000ff;
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF / (0xFFFFFFFF / t32)), job.target);

    // 8 byte target: little endian read of ff ff ff ff ff ff ff 20.
    try job.setTarget("ffffffffffffff20");
    try std.testing.expectEqual(@as(u64, 0x20ffffffffffffff), job.target);
}
