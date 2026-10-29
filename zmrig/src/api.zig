//! Bindings for the RandomX hash engine (zmrig/capi/xmo_randomx.h).
//!
//! The engine is the RandomX implementation from this repository, compiled into
//! libxmorx.a. Everything here is a thin, allocation-explicit wrapper: the Zig
//! miner owns the threads and the pool connection, the C++ side owns the cache,
//! the dataset and one VM per thread.

const std = @import("std");

pub const Engine = opaque {};
pub const Vm = opaque {};

pub const Algo = enum(c_int) {
    rx_0 = 0,
    rx_2 = 1,
    rx_wow = 2,
    rx_arq = 3,
    rx_graft = 4,
    rx_sfx = 5,
    rx_yada = 6,
    rx_xla = 7,

    pub fn fromName(text: []const u8) ?Algo {
        const table = .{
            .{ "rx/0", Algo.rx_0 },
            .{ "rx", Algo.rx_0 },
            .{ "randomx", Algo.rx_0 },
            .{ "rx/2", Algo.rx_2 },
            .{ "rx/wow", Algo.rx_wow },
            .{ "rx/arq", Algo.rx_arq },
            .{ "rx/graft", Algo.rx_graft },
            .{ "rx/sfx", Algo.rx_sfx },
            .{ "rx/yada", Algo.rx_yada },
            .{ "panthera", Algo.rx_xla },
            .{ "rx/xla", Algo.rx_xla },
        };

        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }

        return null;
    }

    pub fn label(self: Algo) []const u8 {
        return switch (self) {
            .rx_0 => "rx/0",
            .rx_2 => "rx/2",
            .rx_wow => "rx/wow",
            .rx_arq => "rx/arq",
            .rx_graft => "rx/graft",
            .rx_sfx => "rx/sfx",
            .rx_yada => "rx/yada",
            .rx_xla => "panthera",
        };
    }
};

/// xmo_engine_new() flags.
pub const EngineFlags = struct {
    huge_pages: bool = true,
    huge_pages_jit: bool = true,
    full_memory: bool = true,
    jit: bool = true,

    pub fn bits(self: EngineFlags) c_int {
        var flags: c_int = 0;
        if (self.huge_pages) flags |= 1;
        if (self.huge_pages_jit) flags |= 2;
        if (self.full_memory) flags |= 4;
        if (self.jit) flags |= 8;

        return flags;
    }
};

pub extern fn xmo_engine_new(algo: c_int, flags: c_int, err: [*]u8, errlen: usize) ?*Engine;
pub extern fn xmo_engine_free(engine: ?*Engine) void;
pub extern fn xmo_engine_dataset_size(engine: *const Engine) usize;
pub extern fn xmo_engine_cache_size(engine: *const Engine) usize;
pub extern fn xmo_engine_seed(engine: *Engine, seed: [*]const u8, seed_len: usize, threads: c_int, err: [*]u8, errlen: usize) c_int;
pub extern fn xmo_engine_huge_pages(engine: *const Engine) usize;
pub extern fn xmo_engine_huge_pages_total(engine: *const Engine) usize;
pub extern fn xmo_engine_total_memory(engine: *const Engine) usize;
pub extern fn xmo_vm_new(engine: *Engine, flags: c_int, numa_node: u32, err: [*]u8, errlen: usize) ?*Vm;
pub extern fn xmo_vm_free(vm: ?*Vm) void;
pub extern fn xmo_hash(vm: *Vm, blob: [*]const u8, len: usize, out: *[32]u8) void;
pub extern fn xmo_hash_first(vm: *Vm, blob: [*]const u8, len: usize, temp: *align(64) [8]u64) void;
pub extern fn xmo_hash_next(vm: *Vm, temp: *align(64) [8]u64, blob: [*]const u8, len: usize, out: *[32]u8) void;
pub extern fn xmo_commitment(blob: [*]const u8, len: usize, hash_in: *const [32]u8, out: *[32]u8) void;
pub extern fn xmo_set_scratchpad_prefetch(mode: c_int) void;
pub extern fn xmo_set_huge_pages_jit(enabled: c_int) void;
pub extern fn xmo_msr_apply(save: c_int, report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_msr_restore(report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_msr_probe(report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_set_optimized_dataset_init(value: c_int) void;
pub extern fn xmo_engine_name() [*:0]const u8;

/// Zig-side wrapper that keeps the "did it work" bookkeeping out of the miner.
pub const Wrapped = struct {
    handle: *Engine,
    algo: Algo,
    full_memory: bool,
    huge_pages: bool,

    pub fn create(algo: Algo, flags: EngineFlags) !Wrapped {
        var buf: [256]u8 = undefined;

        const handle = xmo_engine_new(@intFromEnum(algo), flags.bits(), &buf, buf.len) orelse {
            return error.EngineInitFailed;
        };

        return .{
            .handle = handle,
            .algo = algo,
            .full_memory = flags.full_memory,
            .huge_pages = flags.huge_pages,
        };
    }

    pub fn destroy(self: *Wrapped) void {
        xmo_engine_free(self.handle);
        self.handle = undefined;
    }

    pub fn seed(self: *Wrapped, seed_bytes: []const u8, threads: usize) !void {
        var buf: [256]u8 = undefined;

        if (xmo_engine_seed(self.handle, seed_bytes.ptr, seed_bytes.len, @intCast(@max(threads, 1)), &buf, buf.len) != 0) {
            return error.SeedFailed;
        }
    }

    pub fn datasetSize(self: *const Wrapped) usize {
        return xmo_engine_dataset_size(self.handle);
    }

    pub fn cacheSize(self: *const Wrapped) usize {
        return xmo_engine_cache_size(self.handle);
    }

    /// Bytes really backed by explicit huge pages (0 when the kernel had none
    /// reserved and the engine fell back to ordinary pages).
    pub fn hugePageBytes(self: *const Wrapped) usize {
        return xmo_engine_huge_pages(self.handle);
    }

    /// Bytes that asked for huge pages, granted or not.
    pub fn hugePageBytesTotal(self: *const Wrapped) usize {
        return xmo_engine_huge_pages_total(self.handle);
    }

    pub fn totalMemory(self: *const Wrapped) usize {
        return xmo_engine_total_memory(self.handle);
    }

    pub fn createVm(self: *Wrapped, huge_pages: bool) !*Vm {
        var buf: [256]u8 = undefined;
        var flags: c_int = 0;
        if (huge_pages) flags |= 1;

        return xmo_vm_new(self.handle, flags, 0, &buf, buf.len) orelse error.VmInitFailed;
    }
};
