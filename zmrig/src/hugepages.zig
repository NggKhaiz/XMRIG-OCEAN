// Reserved huge pages, and reserving them when nobody did.
//
// RandomX reads its 2 GiB dataset in random 64-byte stripes. With 4 KiB pages
// every read is a TLB miss and two page-table walks; with 2 MiB pages one TLB
// entry covers 32 768 times as much memory. That is not a micro-optimisation:
// measured on a 2 vCPU Xeon at 2.6 GHz, `--mode fast` gives
//
//     0 pages reserved (THP fallback)   855.7 H/s
//     1200 pages reserved             1033.0 H/s   (+20.7%)
//
// Every fresh install starts at zero, because reserving pages is a root action
// nobody documents. XMRig prints a warning and mines 20% slower forever; this
// miner reserves what the current mode needs and says so. Failure is never
// fatal: an unprivileged miner, a container without CAP_SYS_ADMIN and a kernel
// without hugetlbfs all keep mining on THP.

const std = @import("std");

pub const State = struct {
    /// /proc/sys/vm/nr_hugepages, as the kernel reports it.
    reserved: u64,
    free: u64,
    /// 2 MiB, or 1 GiB on kernels that expose only two sizes; 0 when unknown.
    page_kb: u64,

    pub fn reservedMb(self: State) u64 {
        return self.reserved * self.page_kb / 1024;
    }
};

/// How many pages of `page_kb` are needed to hold `need_mb`.
pub fn pagesFor(need_mb: u64, page_kb: u64) u64 {
    if (page_kb == 0) return 0;

    const need_kb = need_mb * 1024;

    return (need_kb + page_kb - 1) / page_kb;
}

/// Should we try to reserve? Only when the kernel supports huge pages, the
/// pool is short of what this run needs, and the caller asked for huge pages.
pub fn shouldReserve(need_mb: u64, wanted: bool, state: State) enum { enough, reserve, unsupported } {
    if (!wanted) return .enough;
    if (state.page_kb == 0) return .unsupported;
    if (state.reserved >= pagesFor(need_mb, state.page_kb)) return .enough;

    return .reserve;
}

/// Reads the four numbers from /proc/meminfo and /proc/sys/vm/nr_hugepages.
/// Anything unreadable is reported as zero support rather than an error: this
/// is a best-effort optimisation, never a reason to refuse to mine.
pub fn read() State {
    var state = State{ .reserved = 0, .free = 0, .page_kb = 0 };

    if (readNumber("/proc/sys/vm/nr_hugepages")) |n| state.reserved = n;

    var buf: [4096]u8 = undefined;
    const text = readFile(&buf, "/proc/meminfo") orelse return state;

    state.free = parseField(text, "HugePages_Free:");
    state.page_kb = parseField(text, "Hugepagesize:");

    return state;
}

/// Value of a `Label:   number unit` line. Split out of `read()` so the parsing
/// is testable: reading the label instead of the value made this module think
/// the kernel had no huge pages at all, which silently disabled the whole
/// feature (the miner kept mining at 855 H/s while 2 GiB of pages sat unused).
pub fn parseField(text: []const u8, label: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, label)) continue;

        var it = std.mem.tokenizeAny(u8, line[label.len..], " \t:");
        const value = it.next() orelse return 0;

        return std.fmt.parseInt(u64, value, 10) catch 0;
    }

    return 0;
}

/// Asks the kernel for at least `pages`. Returns what the pool holds afterwards,
/// or null when the write failed (not root, read-only /proc, no permission).
pub fn reserve(pages: u64) ?u64 {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{pages}) catch return null;

    const file = std.fs.openFileAbsolute("/proc/sys/vm/nr_hugepages", .{ .mode = .write_only }) catch return null;
    defer file.close();

    file.writeAll(text) catch return null;

    // The kernel allocates lazily and may refuse part of the request (fragmented
    // memory); report what is really there, never what we asked for.
    return readNumber("/proc/sys/vm/nr_hugepages");
}

fn readFile(buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;

    return buf[0..n];
}

fn readNumber(path: []const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const text = readFile(&buf, path) orelse return null;

    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n\r\t"), 10) catch null;
}

test "pages are rounded up, so a rest of 1 MB still gets a page" {
    const testing = std.testing;

    // 2336 MB, what rx/0 needs (256 cache + 2080 dataset), in 2 MiB pages.
    try testing.expectEqual(@as(u64, 1168), pagesFor(2336, 2048));
    // Panthera/Scala needs 192 MB, and asking for Monero's pages would be 12x
    // more than the box has to give.
    try testing.expectEqual(@as(u64, 96), pagesFor(192, 2048));
    try testing.expectEqual(@as(u64, 0), pagesFor(0, 2048));
    // A remainder must round up or the dataset will not fit.
    try testing.expectEqual(@as(u64, 2), pagesFor(3, 2048));
    // An unknown page size cannot be turned into a page count.
    try testing.expectEqual(@as(u64, 0), pagesFor(2336, 0));
}

test "reserving only when the pool is short and huge pages are wanted" {
    const testing = std.testing;

    const empty = State{ .reserved = 0, .free = 0, .page_kb = 2048 };
    // 1168 pages is exactly 2336 MB in 2 MiB pages; 1160 is eight short.
    const full = State{ .reserved = 1168, .free = 900, .page_kb = 2048 };
    const short = State{ .reserved = 1160, .free = 900, .page_kb = 2048 };
    const unknown = State{ .reserved = 0, .free = 0, .page_kb = 0 };

    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, empty)), .reserve), shouldReserve(2336, true, empty));
    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, full)), .enough), shouldReserve(2336, true, full));

    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, short)), .reserve), shouldReserve(2336, true, short));

    // --no-huge-pages must not touch a root-only sysctl.
    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, empty)), .enough), shouldReserve(2336, false, empty));

    // A kernel without hugetlbfs is not a reason to try (or to fail).
    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, empty)), .unsupported), shouldReserve(2336, true, unknown));

    // Light mode needs far less, and a small pool may already cover it.
    const small = State{ .reserved = 200, .free = 200, .page_kb = 2048 };
    try testing.expectEqual(@as(@TypeOf(shouldReserve(1, true, small)), .enough), shouldReserve(320, true, small));
}

test "a real /proc/meminfo is parsed value-first, not label-first" {
    const testing = std.testing;

    // Verbatim from a 2 vCPU container, tab-free and label-aligned like the kernel.
    const meminfo =
        \\MemTotal:        4030332 kB
        \\HugePages_Total:    1200
        \\HugePages_Free:     1156
        \\Hugepagesize:       2048 kB
    ;

    try testing.expectEqual(@as(u64, 1156), parseField(meminfo, "HugePages_Free:"));
    try testing.expectEqual(@as(u64, 2048), parseField(meminfo, "Hugepagesize:"));

    // A missing label is 0, not a crash and not the label text.
    try testing.expectEqual(@as(u64, 0), parseField(meminfo, "HugePages_Rsvd:"));

    // Zero pages must parse as zero; an empty value must not become garbage.
    try testing.expectEqual(@as(u64, 0), parseField("HugePages_Free:        0\n", "HugePages_Free:"));
    try testing.expectEqual(@as(u64, 0), parseField("Hugepagesize:\n", "Hugepagesize:"));
}

test "the host really reports a page size we can divide by" {
    const testing = std.testing;
    const state = read();

    // On any Linux with hugetlbfs this is 2048 or 1048576; in a kernel built
    // without it, zero. Both are handled, so only sanity is checked here.
    if (state.page_kb != 0) {
        try testing.expect(state.page_kb >= 64);
        try testing.expectEqual(@as(u64, state.reserved * state.page_kb / 1024), state.reservedMb());
    }
}
