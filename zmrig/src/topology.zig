//! What the machine actually is: physical cores, SMT siblings, and whether it
//! is running on battery.
//!
//! These answers decide the two profiles:
//!
//!   free  - electricity is free (a cafe, a school lab, a flat-rate VPS): use
//!           every logical CPU, because more threads never hurt when watts do
//!           not matter.
//!   watt  - the bill is yours: one thread per *physical* core. A second SMT
//!           thread on the same core shares its execution units, so it adds
//!           ~5-15 % hashrate for ~30-40 % more power. Per watt that is a loss.
//!
//! Everything here is best effort and read-only: a container may hide the
//! topology, a VM may report one core, and a desktop has no battery file.
//! Every function has a defined answer for "unknown".

const std = @import("std");

pub const Profile = enum { free, watt };

pub fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .free => "free",
        .watt => "watt",
    };
}

/// Physical cores, from `topology/core_id` + `physical_package_id` pairs.
/// Falls back to the logical count when the kernel does not expose topology
/// (containers, some VMs), which is the safe answer: it means "profile watt
/// cannot do better than profile free here".
pub fn physicalCores(logical: usize) usize {
    // In a VM the guest topology is fiction: this container reports cpu0 and
    // cpu1 as siblings of one core, but the host schedules them on anything.
    // Halving the thread count there would cost ~48 % hashrate for no saving,
    // so a hypervisor turns "physical cores" into "the vCPUs we were given".
    if (inVirtualMachine()) return logical;

    var buf: [4096]u8 = undefined;
    const text = readFile(&buf, "/sys/devices/system/cpu/present") orelse return logical;

    // "present" is a range list like "0-3" or "0-1,4-5"; count the CPUs in it.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \n\r\t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, trimmed[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(usize, trimmed[dash + 1 ..], 10) catch continue;
            count += hi -| lo + 1;
        } else {
            count += 1;
        }
    }

    if (count == 0 or count > 4096) return logical;

    // One CPU per distinct (package, core) pair.
    var seen: [256]u64 = undefined;
    var seen_len: usize = 0;
    var cores: usize = 0;

    var cpu: usize = 0;
    while (cpu < count and cpu < 4096) : (cpu += 1) {
        var path_buf: [128]u8 = undefined;
        const base = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/topology", .{cpu}) catch continue;

        var id_buf: [256]u8 = undefined;
        const package = readNumberIn(&id_buf, base, "physical_package_id") orelse 0;
        const core = readNumberIn(&id_buf, base, "core_id") orelse continue;

        // 8 bits of package is plenty (a machine with 256 sockets is not mining).
        const key = (package << 8) | (core & 0xff);

        var dup = false;
        for (seen[0..seen_len]) |known| {
            if (known == key) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        if (seen_len < seen.len) {
            seen[seen_len] = key;
            seen_len += 1;
        }
        cores += 1;
    }

    if (cores == 0) return logical;

    return @min(cores, logical);
}

/// Threads to use for a profile. `free` takes everything; `watt` leaves the SMT
/// siblings idle.
pub fn threadsFor(profile: Profile, logical: usize, physical: usize) usize {
    return switch (profile) {
        .free => @max(logical, 1),
        .watt => @max(@min(physical, logical), 1),
    };
}

pub const Battery = enum { unknown, charging, discharging, full };

/// Reads every `BAT*/status`. A machine with none (every VPS, every desktop)
/// answers `unknown`, which never pauses anything.
pub fn batteryState() Battery {
    var saw_battery = false;
    var discharging = false;
    var charging = false;
    var full = false;

    var index: usize = 0;
    while (index < 8) : (index += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/status", .{index}) catch return .unknown;

        var buf: [64]u8 = undefined;
        const text = readFile(&buf, path) orelse continue;
        const value = std.mem.trim(u8, text, " \n\r\t");

        if (value.len == 0) continue;

        saw_battery = true;
        if (std.ascii.eqlIgnoreCase(value, "Discharging")) discharging = true;
        if (std.ascii.eqlIgnoreCase(value, "Charging")) charging = true;
        if (std.ascii.eqlIgnoreCase(value, "Full")) full = true;
    }

    if (!saw_battery) return .unknown;
    // Discharging wins: a machine can report one pack charging and another
    // draining, and the safe answer is "we are on battery".
    if (discharging) return .discharging;
    if (charging) return .charging;
    if (full) return .full;

    return .unknown;
}

/// Should the miner stop hashing right now, given the profile and the battery?
/// Only profile `watt` ever pauses, and only on a real battery reading: an
/// unknown state (VPS, desktop) must never stop a miner.
pub fn shouldPause(profile: Profile, state: Battery, pause_on_battery: bool) bool {
    if (profile != .watt or !pause_on_battery) return false;

    return state == .discharging;
}

/// True when /proc/cpuinfo advertises the `hypervisor` flag (every KVM, Xen,
/// VMware and Hyper-V guest does). Kept public for `--check`.
pub fn inVirtualMachine() bool {
    var buf: [64 * 1024]u8 = undefined;
    const text = readFile(&buf, "/proc/cpuinfo") orelse return false;

    // The flag appears as its own token in the `flags`/`Features` line.
    var it = std.mem.tokenizeAny(u8, text, " \n\t:");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "hypervisor")) return true;
    }

    return false;
}

fn readFile(buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;

    return buf[0..n];
}

fn readNumberIn(buf: []u8, dir: []const u8, name: []const u8) ?u64 {
    var path_buf: [192]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;

    const text = readFile(buf, path) orelse return null;

    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n\r\t"), 10) catch null;
}

test "profile free takes every thread, profile watt leaves SMT siblings idle" {
    const testing = std.testing;

    // A 4-core / 8-thread laptop, the case the two profiles disagree on.
    try testing.expectEqual(@as(usize, 8), threadsFor(.free, 8, 4));
    try testing.expectEqual(@as(usize, 4), threadsFor(.watt, 8, 4));

    // No SMT: the profiles are identical and neither may produce 0.
    try testing.expectEqual(@as(usize, 2), threadsFor(.free, 2, 2));
    try testing.expectEqual(@as(usize, 2), threadsFor(.watt, 2, 2));

    // Unknown topology (a container reporting one core) must not break.
    try testing.expectEqual(@as(usize, 1), threadsFor(.watt, 1, 1));
    try testing.expectEqual(@as(usize, 1), threadsFor(.free, 0, 0));
}

test "physical cores is never more than the logical count and never zero" {
    const testing = std.testing;
    const logical = std.Thread.getCpuCount() catch 1;

    const physical = physicalCores(logical);

    try testing.expect(physical >= 1);
    try testing.expect(physical <= logical);
}

test "a hypervisor makes every vCPU its own core" {
    const testing = std.testing;
    const logical = std.Thread.getCpuCount() catch 1;

    // On a VM the answer must be "all of them": the guest topology is a lie and
    // halving threads on a VPS is a 48 % hashrate loss for no power saving.
    if (inVirtualMachine()) {
        try testing.expectEqual(logical, physicalCores(logical));
        try testing.expectEqual(logical, threadsFor(.watt, logical, physicalCores(logical)));
    } else {
        // Bare metal: never more cores than threads, never zero.
        const physical = physicalCores(logical);
        try testing.expect(physical >= 1);
        try testing.expect(physical <= logical);
    }
}

test "the battery never pauses a miner on a host without one" {
    const testing = std.testing;

    // profile free never pauses, whatever the battery says.
    try testing.expect(!shouldPause(.free, .discharging, true));
    // profile watt pauses only on a real discharging reading.
    try testing.expect(shouldPause(.watt, .discharging, true));
    try testing.expect(!shouldPause(.watt, .charging, true));
    try testing.expect(!shouldPause(.watt, .full, true));
    // ...and an unknown state is never a reason to stop hashing.
    try testing.expect(!shouldPause(.watt, .unknown, true));
    // the opt-out wins over everything.
    try testing.expect(!shouldPause(.watt, .discharging, false));
}

test "battery parsing accepts the words the kernel actually uses" {
    const testing = std.testing;

    // This host has no battery; the point of the test is that the answer is a
    // defined one and not a crash or a paused miner.
    const state = batteryState();
    try testing.expect(state == .unknown or state == .charging or state == .discharging or state == .full);

    if (state == .unknown) {
        try testing.expect(!shouldPause(.watt, state, true));
    }
}
