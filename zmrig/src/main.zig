//! zmrig - a RandomX miner written in Zig on top of the RandomX engine shipped
//! in this repository. 0% developer fee, nothing is mined for anyone but the
//! wallet you pass on the command line.

const std = @import("std");
const api = @import("api.zig");
const job_mod = @import("job.zig");
const log = @import("log.zig");
const miner_mod = @import("miner.zig");
const options = @import("options.zig");
const stratum = @import("stratum.zig");
const util = @import("util.zig");

pub const version = "6.26.0-mo8";

var running = std.atomic.Value(bool).init(true);

fn onSignal(_: c_int) callconv(.C) void {
    running.store(false, .release);
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.HUP, &act, null) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = options.parseArgs(allocator, args[1..]) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n\n", .{@errorName(e)});
        try stderr.writeAll(options.usage);

        // XMRig exits 1 on a bad command line; scripts (and oneclick.sh's
        // config validation) rely on that.
        std.process.exit(1);
    };
    defer opts.deinit(allocator);

    // A config file is loaded first, command line flags are applied on top.
    if (opts.config_path) |path| {
        var file_opts = options.Options{};
        try options.parseConfigFile(allocator, &file_opts, path);

        const cli = try options.parseArgs(allocator, args[1..]);
        mergeOptions(&file_opts, &cli);
        allocator.free(cli.pools.items); // pool strings now owned by file_opts
        opts.deinit(allocator);
        opts = file_opts;
    }

    if (opts.help) {
        try std.io.getStdOut().writeAll(options.usage);

        return;
    }

    log.global = log.Logger.init(opts.colors, opts.verbose);
    if (opts.log_file) |path| {
        log.global.openFile(path) catch |e| {
            log.global.warn("cannot open log file {s}: {s}", .{ path, @errorName(e) });
        };
    }
    defer log.global.deinit();

    if (opts.version) {
        var buf: [128]u8 = undefined;
        const cpu = std.fmt.bufPrint(&buf, "{d} threads, L3 {d} MB", .{
            miner_mod.cpuCount(),
            (miner_mod.l3CacheSize() orelse 0) / (1024 * 1024),
        }) catch "?";

        try std.io.getStdOut().writer().print("zmrig {s} ({s}, {s})\n", .{ version, api.xmo_engine_name(), cpu });

        return;
    }

    if (opts.self_test) {
        const ok = try selfTest(allocator, opts.self_test_light);
        std.process.exit(if (ok) 0 else 1);
    }

    if (opts.benchmark) {
        try benchmark(allocator, &opts);
        return;
    }

    options.validate(&opts) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n\n", .{@errorName(e)});
        try stderr.writeAll(options.usage);

        return;
    };

    if (opts.check) {
        try printConfigSummary(&opts);
        return;
    }

    installSignalHandlers();

    const logger = &log.global;
    logger.info("zmrig {s} starting, 0% developer fee", .{version});
    logger.info("engine: {s}", .{api.xmo_engine_name()});

    // The workers set their own nice value; this covers the main thread.
    miner_mod.applyPriority(opts.priority);

    var miner = try miner_mod.Miner.init(logger, &opts);
    defer miner.deinit();

    var monitor = Monitor{
        .miner = &miner,
        .logger = logger,
        .print_interval = @as(i64, @intCast(opts.print_time)) * 1000,
    };
    monitor.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Monitor.run, .{&monitor});
    defer {
        monitor.stop.store(true, .release);
        if (monitor.thread) |thread| thread.join();
    }

    logger.info("wallet: {s}", .{opts.pools.items[0].user});

    var pool_index: usize = 0;
    var failures: u32 = 0;

    while (running.load(.acquire)) {
        const pool = opts.pools.items[pool_index % opts.pools.items.len];

        logger.info("connecting to {s}{s}:{d}", .{
            if (pool.tls) "stratum+ssl://" else "stratum+tcp://",
            pool.host,
            pool.port,
        });

        const algo = opts.poolAlgo(&pool);
        var session = stratum.Session.open(allocator, pool, logger) catch {
            failures += 1;
            if (failures >= opts.retries) {
                failures = 0;
                pool_index += 1;
            }
            sleepInterruptible(opts.retry_pause);
            continue;
        };
        defer session.close();

        var first_job = job_mod.Job.init();
        session.login(algo, &first_job) catch |e| {
            logger.err("login failed: {s}", .{@errorName(e)});
            failures += 1;
            if (failures >= opts.retries) {
                failures = 0;
                pool_index += 1;
            }
            sleepInterruptible(opts.retry_pause);
            continue;
        };

        failures = 0;

        logger.info("login ok, job {s}, difficulty {d:.3}", .{
            first_job.idSlice(),
            first_job.diff(),
        });

        miner.submitter.attach(&session);
        monitor.socket.store(@intCast(session.conn.stream.handle), .release);
        monitor.last_message.store(std.time.milliTimestamp(), .release);

        miner.applyJob(&first_job) catch |e| {
            logger.err("cannot start mining: {s}", .{@errorName(e)});
            miner.submitter.detach();
            sleepInterruptible(opts.retry_pause);
            continue;
        };

        const result = runSession(allocator, &session, &miner, &opts, &monitor, algo, logger);
        monitor.socket.store(-1, .release);

        miner.submitter.detach();
        miner.shared.pause();

        switch (result) {
            .disconnected => |e| logger.warn("connection lost: {s}", .{@errorName(e)}),
            .shutdown => {},
            .failed => {},
        }

        if (!running.load(.acquire)) break;

        sleepInterruptible(opts.retry_pause);
    }

    logger.info("shutting down", .{});
    miner.stop();

    var buf: [32]u8 = undefined;
    logger.info("total hashes {d}, shares accepted {d}, rejected {d}, failed {d}", .{
        miner.shared.totalHashes(),
        miner.submitter.accepted.load(.monotonic),
        miner.submitter.rejected.load(.monotonic),
        miner.submitter.failed.load(.monotonic),
    });
    _ = &buf;
}

const SessionEnd = union(enum) {
    disconnected: anyerror,
    shutdown,
    failed,
};

fn runSession(
    allocator: std.mem.Allocator,
    session: *stratum.Session,
    miner: *miner_mod.Miner,
    opts: *const options.Options,
    monitor: *Monitor,
    algo: ?api.Algo,
    logger: *log.Logger,
) SessionEnd {
    _ = opts;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (running.load(.acquire)) {
        _ = arena.reset(.retain_capacity);

        const message = session.next(arena.allocator(), algo orelse .rx_0) catch |e| {
            return .{ .disconnected = e };
        };

        monitor.last_message.store(std.time.milliTimestamp(), .release);

        switch (message) {
            .job => |pool_job| {
                var next_job = pool_job;

                logger.info("new job {s} from pool, height {d}, difficulty {d:.3}", .{
                    next_job.idSlice(),
                    next_job.height,
                    next_job.diff(),
                });

                miner.applyJob(&next_job) catch |e| {
                    logger.err("cannot apply job: {s}", .{@errorName(e)});
                };
            },
            .reply => |reply| {
                if (reply.ok) {
                    if (reply.job != null) continue;

                    _ = miner.submitter.accepted.fetchAdd(1, .monotonic);
                    logger.info("share accepted ({d} total)", .{miner.submitter.accepted.load(.monotonic)});
                } else {
                    _ = miner.submitter.rejected.fetchAdd(1, .monotonic);
                    logger.warn("share rejected: {s}", .{reply.message orelse "unknown reason"});
                }
            },
            .keepalive => {},
            .other => |method| {
                logger.debug("pool method {s}", .{method});
            },
        }
    }

    return .shutdown;
}

/// Samples the hash counter once a second, prints the periodic hashrate line and
/// drops a connection that has been silent for too long. Runs in its own thread
/// so the pool read loop can stay a simple blocking reader (which keeps TLS
/// record framing correct).
const Monitor = struct {
    miner: *miner_mod.Miner,
    logger: *log.Logger,
    print_interval: i64,
    last_message: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    socket: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    const timeout_ms: i64 = 180_000;

    fn run(self: *Monitor) void {
        var last_report = std.time.milliTimestamp();
        var first_hash_ms: i64 = 0;
        var first_report = true;

        while (!self.stop.load(.acquire)) {
            std.time.sleep(1000 * std.time.ns_per_ms);

            const total = self.miner.shared.totalHashes();
            self.miner.stats.add(total);

            const now = std.time.milliTimestamp();
            if (first_hash_ms == 0 and total > 0) first_hash_ms = now;

            // One early report, 10 s after the *first hash* (not after start:
            // the dataset init takes 15 s and would produce a meaningless
            // average), so status/logs show a real number quickly.
            if (first_report and first_hash_ms != 0 and now - first_hash_ms >= 10_000) {
                first_report = false;
                last_report = now;
                self.miner.report();
                continue;
            }

            if (self.print_interval > 0 and now - last_report >= self.print_interval) {
                first_report = false;
                last_report = now;
                self.miner.report();
            }

            const last = self.last_message.load(.acquire);
            const fd = self.socket.load(.acquire);
            if (last != 0 and fd >= 0 and now - last > timeout_ms) {
                self.logger.warn("pool has been silent for {d} s, dropping the connection", .{@divTrunc(now - last, 1000)});
                std.posix.shutdown(@intCast(fd), .both) catch {};
            }
        }
    }
};

fn mergeOptions(base: *options.Options, extra: *const options.Options) void {
    if (extra.algo) |v| base.algo = v;
    if (extra.threads) |v| base.threads = v;
    if (extra.pools.items.len > 0) {
        // Command line pools replace config file pools, like xmrig does.
        base.pools.clearRetainingCapacity();
    }
    base.mode = extra.mode;
    base.huge_pages = extra.huge_pages;
    base.huge_pages_jit = extra.huge_pages_jit;
    base.jit = extra.jit;
    base.print_time = extra.print_time;
    base.retries = extra.retries;
    base.retry_pause = extra.retry_pause;
    base.colors = extra.colors;
    base.verbose = extra.verbose;
    base.affinity = extra.affinity;
    base.priority = extra.priority;
    if (extra.log_file) |v| base.log_file = v;
    if (extra.api_port != 0) base.api_port = extra.api_port;
    if (extra.check) base.check = true;
    if (extra.self_test) base.self_test = true;
    if (extra.benchmark) {
        base.benchmark = true;
        base.bench_hashes = extra.bench_hashes;
    }
}

/// --check: print what the miner would do, without touching the network.
fn printConfigSummary(opts: *const options.Options) !void {
    var out = std.io.getStdOut().writer();

    try out.print("config ok\n", .{});

    for (opts.pools.items) |pool| {
        try out.print("  pool    {s}{s}:{d} user={s} algo={s}\n", .{
            if (pool.tls) "stratum+ssl://" else "stratum+tcp://",
            pool.host,
            pool.port,
            pool.user,
            if (opts.poolAlgo(&pool)) |algo| algo.label() else "auto",
        });
    }

    try out.print("  threads {d} (default would be {d})\n", .{ opts.threads orelse miner_mod.defaultThreads(miner_mod.cpuCount()), miner_mod.defaultThreads(miner_mod.cpuCount()) });
    if (opts.priority != -1) {
        try out.print("  priority {d}\n", .{opts.priority});
    }

    try out.print("  mode    {s}, huge pages {s}, jit {s}\n", .{
        @tagName(opts.mode),
        if (opts.huge_pages) "on" else "off",
        if (opts.jit) "on" else "off",
    });
}

fn sleepInterruptible(seconds: u32) void {
    var i: u32 = 0;

    while (i < seconds * 10) : (i += 1) {
        if (!running.load(.acquire)) return;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

// --- self test -----------------------------------------------------------------

const vectors = struct {
    const seed = "xmrig-mo-check-hashes seed";
    const input_a = "xmrig-mo-check-hashes input A";
    const input_b = "xmrig-mo-check-hashes input B";
    const input_c = "xmrig-mo-check-hashes input C";
    const rx0_a = "1833ff322e60dad7d6885bcd5e0844ec8e4808a47d8d354806668f0c241a6af5";
};

fn selfTest(allocator: std.mem.Allocator, light_only: bool) !bool {
    _ = allocator;

    var failures: usize = 0;
    const out = std.io.getStdOut().writer();

    try out.print("hash engine: {s}\n", .{api.xmo_engine_name()});

    // Light mode first: 256 MiB cache, no dataset.
    {
        var engine = api.Wrapped.create(.rx_0, .{ .full_memory = false }) catch {
            try out.writeAll("FAIL cannot create the hash engine\n");

            return false;
        };
        defer engine.destroy();

        engine.seed(vectors.seed, 1) catch {
            try out.writeAll("FAIL cannot initialise the cache\n");

            return false;
        };

        const vm = engine.createVm(false) catch {
            try out.writeAll("FAIL cannot create a VM\n");

            return false;
        };
        defer api.xmo_vm_free(vm);

        var expected: [32]u8 = undefined;
        _ = try util.hexToBytes(&expected, vectors.rx0_a);

        var hash_a: [32]u8 = undefined;
        var hash_b: [32]u8 = undefined;
        api.xmo_hash(vm, vectors.input_a.ptr, vectors.input_a.len, &hash_a);

        if (std.mem.eql(u8, &hash_a, &expected)) {
            try out.writeAll("PASS rx/0 reference vector\n");
        } else {
            const got = try util.bytesToHex(std.heap.page_allocator, &hash_a);
            defer std.heap.page_allocator.free(got);

            try out.print("FAIL rx/0 reference vector\n  got  {s}\n  want {s}\n", .{ got, vectors.rx0_a });
            failures += 1;
        }

        api.xmo_hash(vm, vectors.input_b.ptr, vectors.input_b.len, &hash_b);

        var temp: [8]u64 align(64) = undefined;
        var next_a: [32]u8 = undefined;
        var next_b: [32]u8 = undefined;

        api.xmo_hash_first(vm, vectors.input_a.ptr, vectors.input_a.len, &temp);
        api.xmo_hash_next(vm, &temp, vectors.input_b.ptr, vectors.input_b.len, &next_a);
        api.xmo_hash_next(vm, &temp, vectors.input_c.ptr, vectors.input_c.len, &next_b);

        if (std.mem.eql(u8, &next_a, &hash_a) and std.mem.eql(u8, &next_b, &hash_b)) {
            try out.writeAll("PASS pipelined hashing\n");
        } else {
            try out.writeAll("FAIL pipelined hashing does not match one-shot hashing\n");
            failures += 1;
        }
    }

    // Full memory mode must produce the same hashes. It needs 2.25 GiB, so it
    // only runs when the machine can actually hold the dataset right now - a
    // running miner that already owns the pages would otherwise get OOM-killed.
    const need: u64 = 2600 * 1024 * 1024;
    if (light_only) {
        try out.writeAll("SKIP full-memory test (light mode requested)\n");
    } else if (miner_mod.totalMemory() < 3 * 1024 * 1024 * 1024 or miner_mod.memoryForDataset() < need) {
        try out.writeAll("SKIP full-memory test (not enough free RAM while the miner is running)\n");
    } else {
        var engine_full = api.Wrapped.create(.rx_0, .{ .full_memory = true }) catch null;
        if (engine_full) |*full| {
            defer full.destroy();

            full.seed(vectors.seed, miner_mod.cpuCount()) catch {
                try out.writeAll("FAIL cannot initialise the dataset\n");

                return false;
            };

            const full_vm = full.createVm(true) catch {
                try out.writeAll("FAIL cannot create a full-memory VM\n");

                return false;
            };
            defer api.xmo_vm_free(full_vm);

            var expected: [32]u8 = undefined;
            _ = try util.hexToBytes(&expected, vectors.rx0_a);

            var hash_full: [32]u8 = undefined;
            api.xmo_hash(full_vm, vectors.input_a.ptr, vectors.input_a.len, &hash_full);

            if (std.mem.eql(u8, &hash_full, &expected)) {
                try out.writeAll("PASS full-memory dataset matches the cache\n");
            } else {
                try out.writeAll("FAIL full-memory hash differs from the reference\n");
                failures += 1;
            }
        } else {
            try out.writeAll("SKIP full-memory test (not enough memory for the dataset)\n");
        }
    }

    if (failures == 0) {
        try out.writeAll("\nself test passed\n");
    } else {
        try out.print("\n{d} self test failure(s)\n", .{failures});
    }

    return failures == 0;
}

// --- benchmark -------------------------------------------------------------------

fn benchmark(allocator: std.mem.Allocator, opts: *const options.Options) !void {
    const logger = &log.global;

    // Deterministic seed so repeated runs are comparable.
    const seed_text = "zmrig benchmark seed 000000000000";
    var seed_bytes: [32]u8 = undefined;
    _ = try util.hexToBytes(&seed_bytes, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");

    var miner = try miner_mod.Miner.init(logger, opts);
    defer miner.deinit();

    try miner.engine.ensure(opts.algo orelse .rx_0);
    try miner.engine.seedNow(seed_bytes, miner.threadCount());

    var bench_job = job_mod.Job.init();
    @memset(bench_job.blob[0..76], 0);
    bench_job.blob[0] = 0x99;
    bench_job.blob_len = 76;
    bench_job.setId("bench");
    bench_job.setAlgo(opts.algo orelse .rx_0);
    bench_job.target = 1;
    bench_job.has_seed = true;
    bench_job.seed = seed_bytes;

    _ = allocator;
    _ = seed_text;

    try miner.start();
    miner.shared.bench_limit.store(opts.bench_hashes, .release);
    miner.shared.publish(&bench_job);

    const started = std.time.milliTimestamp();
    var last_report = started;
    var last_sample = started;

    while (running.load(.acquire) and miner.shared.running.load(.acquire)) {
        std.time.sleep(200 * std.time.ns_per_ms);

        const now = std.time.milliTimestamp();
        if (now - started >= 180_000) break;

        // report() reads the samples, so the benchmark has to feed them too
        // (the Monitor thread only runs while mining against a pool).
        if (now - last_sample >= 1000) {
            last_sample = now;
            miner.stats.add(miner.shared.totalHashes());
        }

        if (now - last_report >= 10_000) {
            last_report = now;
            miner.report();
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - started;
    const total = miner.shared.totalHashes();

    miner.stop();

    var buf: [32]u8 = undefined;
    const rate = @as(f64, @floatFromInt(total)) * 1000.0 / @as(f64, @floatFromInt(@max(elapsed_ms, 1)));
    const scaled = util.scaleHashrate(rate);

    logger.info("benchmark: {d} hashes in {d} ms = {s}", .{
        total,
        elapsed_ms,
        std.fmt.bufPrint(&buf, "{d:.3} {s}", .{ scaled.value, scaled.unit }) catch "?",
    });
}
