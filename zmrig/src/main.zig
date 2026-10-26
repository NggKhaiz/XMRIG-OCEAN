//! zmrig - a RandomX miner written in Zig on top of the RandomX engine shipped
//! in this repository. 0% developer fee, nothing is mined for anyone but the
//! wallet you pass on the command line.

const std = @import("std");
const api = @import("api.zig");
const job_mod = @import("job.zig");
const log = @import("log.zig");
const miner_mod = @import("miner.zig");
const api_http = @import("api_http.zig");
const options = @import("options.zig");
const report = @import("report.zig");
const stratum = @import("stratum.zig");
const verify = @import("verify.zig");
const util = @import("util.zig");

pub const version = "6.26.0-mo9";

var running = std.atomic.Value(bool).init(true);

fn onSignal(_: c_int) callconv(.C) void {
    running.store(false, .release);
    // Also wake any thread parked in a socket read (login, keepalive reply,
    // a pool that never answers) so shutdown is immediate.
    @import("transport.zig").stop_requested.store(true, .release);
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
        options.parseConfigFile(allocator, &file_opts, path) catch |e| {
            var stderr = std.io.getStdErr().writer();

            // Say what is wrong instead of leaking an error name: an
            // unreadable config is by far the most common failure (the
            // installer writes it root-only, so a plain user cannot read it).
            switch (e) {
                error.ConfigUnreadable => stderr.print("zmrig: cannot read {s}: check the path or run as root\n", .{path}) catch {},
                error.ConfigInvalidJson => stderr.print("zmrig: {s} is not valid JSON\n", .{path}) catch {},
                else => stderr.print("zmrig: cannot load {s}: {s}\n", .{ path, @errorName(e) }) catch {},
            }

            std.process.exit(1);
        };

        var cli = try options.parseArgs(allocator, args[1..]);
        mergeOptions(allocator, &file_opts, &cli);
        allocator.free(cli.pools.items); // strings were moved, the array goes away
        opts.deinit(allocator);
        opts = file_opts;
    }

    options.applyTransportDefaults(allocator, &opts) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n", .{@errorName(e)});

        std.process.exit(1);
    };

    if (opts.help) {
        // `zmrig --help | head` closes the pipe early: that is not an error.
        std.io.getStdOut().writeAll(options.usage) catch {};

        return;
    }

    log.global = log.Logger.init(opts.colors, opts.verbose);
    stratum.user_agent = opts.user_agent;
    if (opts.donate_level_ignored) |level| {
        // Do not silently accept `--donate-level=1` and then take 1 %: the fee
        // is 0 % by construction (see doc/ZERO_FEE.md).
        log.global.info("--donate-level={d} ignored: this miner has a 0% developer fee", .{level});
    }
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

        std.io.getStdOut().writer().print("zmrig {s} ({s}, {s})\n", .{ version, api.xmo_engine_name(), cpu }) catch {};

        return;
    }

    if (opts.self_test) {
        const ok = try selfTest(allocator, opts.self_test_light);
        std.process.exit(if (ok) 0 else 1);
    }

    // Both of these build their own dataset. If the machine cannot hold it
    // (another miner owns the huge pages), say so instead of being OOM-killed.
    const dataset_mb: u64 = if (opts.mode == .light) 400 else 2400;

    if (opts.benchmark) {
        try requireMemory(dataset_mb);
        _ = try benchmark(allocator, &opts, 180, 0);
        return;
    }

    if (opts.report) {
        // stdout carries one line: the code. Everything else goes to stderr so
        // `zmrig --report > rig.txt` produces a file the dashboard accepts.
        log.global.stderr_sink = true;

        try requireMemory(dataset_mb);

        // A report is a steady state number: the first seconds after the
        // dataset is built are slower (JIT warm-up, page faults), so measure a
        // 10 s window after a 10 s warm-up instead of averaging the ramp in.
        const measure = try benchmark(allocator, &opts, @max(opts.report_seconds, 5), 10);
        const power = report.measurePower(opts.power_watts);

        var cpu_buf: [256]u8 = undefined;
        var code_buf: [1400]u8 = undefined;

        const threads = if (opts.threads) |t| @max(t, 1) else miner_mod.defaultThreads(miner_mod.cpuCount());
        // `--report` also works without a pool: it measures the machine, not a
        // session, so there is nothing to validate against.
        const rig_id: ?[]const u8 = if (opts.pools.items.len > 0) opts.pools.items[0].rig_id else null;

        const code = report.encode(&code_buf, .{
            .id = opts.report_id orelse (rig_id orelse "zmrig"),
            .version = version,
            .cpu = report.cpuModel(&cpu_buf),
            .threads = threads,
            .cores = report.physicalCores(miner_mod.cpuCount()),
            .algo = if (opts.algo) |a| a.label() else "rx/0",
            .mode = @tagName(opts.mode),
            .rates = .{ measure.steady_rate, measure.steady_rate, measure.steady_rate, measure.steady_rate },
            .huge_pages = .{ measure.huge_pages, measure.huge_pages },
            .shares = .{ 0, 0, 0 },
            .hashes = measure.hashes,
            .uptime_s = 0,
            .power_watts = power.watts,
            .power_source = power.source,
            .pool = "benchmark",
            .timestamp = std.time.timestamp(),
        }) catch |e| {
            log.global.err("cannot build the report: {s}", .{@errorName(e)});

            return;
        };

        log.global.info("measured {d} hashes in {d} ms, power source {s}", .{
            measure.hashes,
            measure.elapsed_ms,
            power.source,
        });
        try std.io.getStdOut().writer().print("{s}\n", .{code});

        return;
    }

    options.validate(&opts) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n\n", .{@errorName(e)});
        try stderr.writeAll(options.usage);

        return;
    };

    if (opts.check) {
        // A closed pipe (`--check | head`) is not a failure.
        printConfigSummary(&opts) catch {};
        return;
    }

    if (opts.verify_share) {
        // stdout is a protocol here: one JSON line per share, nothing else.
        log.global.stderr_sink = true;
        try verify.run(allocator, &log.global);

        return;
    }

    if (opts.background) {
        // XMRig's --background: detach from the terminal, keep mining. The log
        // file (if any) was opened before this point, so it survives.
        daemonise() catch |e| {
            log.global.err("cannot go to the background: {s}", .{@errorName(e)});

            return;
        };
    }

    installSignalHandlers();

    const logger = &log.global;
    logger.info("zmrig {s} starting, 0% developer fee", .{version});
    logger.info("engine: {s}", .{api.xmo_engine_name()});

    // The workers set their own nice value; this covers the main thread.
    miner_mod.applyPriority(opts.priority);

    var miner = try miner_mod.Miner.init(logger, &opts);
    defer miner.deinit();

    // The RandomX memory-latency fix, applied before the dataset is built.
    // It is opt-in because it writes hardware registers, and it is allowed to
    // fail: a VM without MSR passthrough is a normal place to run a miner.
    const msr_applied = applyMsr(&opts, logger);
    defer if (msr_applied and opts.msr_restore) {
        var report_buf: [192]u8 = undefined;
        @memset(&report_buf, 0);
        _ = api.xmo_msr_restore(&report_buf, report_buf.len);
        logger.debug("msr: {s}", .{report_buf[0..std.mem.indexOfScalar(u8, &report_buf, 0) orelse report_buf.len]});
    };

    // "host:port" for the report, owned by main for the whole run.
    var pool_label_buf: [256]u8 = undefined;
    const pool_label = std.fmt.bufPrint(&pool_label_buf, "{s}:{d}", .{
        opts.pools.items[0].host,
        opts.pools.items[0].port,
    }) catch opts.pools.items[0].host;

    var monitor = Monitor{
        .miner = &miner,
        .logger = logger,
        .report_file = opts.report_file,
        .report_interval_ms = @as(i64, @intCast(@max(opts.report_interval, 1))) * 1000,
        .report_id = opts.report_id orelse (opts.pools.items[0].rig_id orelse "zmrig"),
        .report_pool = pool_label,
        .report_user_power = opts.power_watts,
        .report_mode = @tagName(opts.mode),
        .report_started_ms = std.time.milliTimestamp(),
        .print_interval = @as(i64, @intCast(opts.print_time)) * 1000,
        .idle_timeout_ms = @as(i64, @intCast(opts.idle_timeout)) * 1000,
        .keepalive_ms = @as(i64, @intCast(opts.keepalive_interval)) * 1000,
        .keepalive_enabled = opts.keepalive_interval > 0,
    };
    monitor.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Monitor.run, .{&monitor});
    defer {
        monitor.stop.store(true, .release);
        if (monitor.thread) |thread| thread.join();
    }

    logger.info("wallet: {s}", .{opts.pools.items[0].user});

    // Optional read-only monitoring API (--http-port). It reads atomics only,
    // so an open dashboard cannot slow the miner down.
    var http_api: ?api_http.Server = null;
    if (opts.api_port != 0) {
        const first_pool = opts.pools.items[0];
        var url_buf: [256]u8 = undefined;
        const pool_url = std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}", .{
            first_pool.transport.label(),
            first_pool.host,
            first_pool.port,
        }) catch first_pool.host;

        http_api = api_http.Server{
            .allocator = allocator,
            .logger = logger,
            .host = opts.http_host,
            .port = opts.api_port,
            .token = opts.api_token,
            .info = .{
                .version = version,
                .pool_url = pool_url,
                .worker_id = first_pool.rig_id orelse "zmrig",
                .miner = &miner,
                .threads = miner.threadCount(),
                .started_ms = std.time.milliTimestamp(),
                .accepted = &miner.submitter.accepted,
                .rejected = &miner.submitter.rejected,
                .failed = &miner.submitter.failed,
                .view = &monitor.view,
            },
        };

        http_api.?.start() catch |e| {
            logger.warn("http api disabled: {s}", .{@errorName(e)});
            http_api = null;
        };
    }
    defer if (http_api) |*server| server.stopServer();

    var pool_index: usize = 0;
    var failures: u32 = 0;
    // Consecutive failures since the last successful login, used only to
    // shape the retry delay. It is not reset when the pool list wraps around,
    // otherwise a dead pool would be hammered every few seconds forever.
    var attempts: u32 = 0;

    while (running.load(.acquire)) {
        const pool = opts.pools.items[pool_index % opts.pools.items.len];

        logger.info("connecting to {s}://{s}:{d}{s}", .{
            pool.transport.label(),
            pool.host,
            pool.port,
            if (pool.transport.usesWs()) (pool.ws_path orelse "/") else "",
        });

        const algo = opts.poolAlgo(&pool);
        var session = stratum.Session.open(allocator, pool, logger) catch {
            failures += 1;
            if (failures >= opts.retries) {
                failures = 0;
                pool_index += 1;
            }
            attempts +|= 1;
            sleepInterruptibleMs(retryDelayMs(opts.retry_pause, attempts));
            continue;
        };
        defer session.close();

        // From here on the monitor owns a kick handle: a Ctrl-C while waiting
        // for the login reply must not wait for the pool to answer. The handle
        // is cleared as soon as this session ends, so a stale descriptor can
        // never be shut down after it was closed (and possibly reused).
        monitor.socket.store(@intCast(session.conn.handle()), .release);
        defer monitor.socket.store(-1, .release);

        var first_job = job_mod.Job.init();
        session.login(algo, &first_job) catch |e| {
            logger.err("login failed: {s}", .{@errorName(e)});
            failures += 1;
            if (failures >= opts.retries) {
                failures = 0;
                pool_index += 1;
            }
            attempts +|= 1;
            sleepInterruptibleMs(retryDelayMs(opts.retry_pause, attempts));
            continue;
        };

        failures = 0;
        attempts = 0;

        logger.info("login ok, job {s}, difficulty {d:.3}", .{
            first_job.idSlice(),
            first_job.diff(),
        });

        miner.submitter.attach(&session);
        monitor.last_message.store(std.time.milliTimestamp(), .release);
        monitor.view.markConnected(std.time.milliTimestamp());

        miner.applyJob(&first_job) catch |e| {
            logger.err("cannot start mining: {s}", .{@errorName(e)});
            miner.submitter.detach();
            attempts +|= 1;
            sleepInterruptibleMs(retryDelayMs(opts.retry_pause, attempts));
            continue;
        };

        const result = runSession(allocator, &session, &miner, &opts, &monitor, algo, logger);
        monitor.view.markDisconnected();

        if (session.conn.skipped > 0) {
            logger.warn("ignored {d} over-long line(s) from the pool", .{session.conn.skipped});
        }

        miner.submitter.detach();
        // Keep the workers running on the last job while we reconnect: a pool
        // that drops a socket for a second must not cost a minute of hashing.
        // Shares found in the gap are dropped by the submitter with a warning.

        switch (result) {
            .disconnected => |e| logger.warn("connection lost: {s}", .{@errorName(e)}),
            .shutdown => {},
            .failed => {},
        }

        if (!running.load(.acquire)) break;

        // A session that worked and then dropped is retried almost at once.
        sleepInterruptibleMs(retryDelayMs(opts.retry_pause, 0));
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
    /// Live report file (`--report-file`), written from this thread so the
    /// pool loop stays untouched.
    report_file: ?[]const u8 = null,
    report_interval_ms: i64 = 60_000,
    report_id: []const u8 = "zmrig",
    report_pool: []const u8 = "",
    report_mode: []const u8 = "auto",
    report_power: ?f64 = null,
    report_power_source: []const u8 = "none",
    /// Measurement is deferred until the CPU has been hashing for a while: a
    /// RAPL reading taken at startup would be idle power, not mining power.
    report_power_measured: bool = false,
    report_user_power: ?f64 = null,
    report_started_ms: i64 = 0,
    last_report_write: i64 = 0,
    report_error_logged: bool = false,
    print_interval: i64,
    idle_timeout_ms: i64 = 300_000,
    keepalive_ms: i64 = 60_000,
    keepalive_enabled: bool = true,
    last_message: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Hashrates published to the HTTP API once a second.
    view: api_http.View = .{},
    socket: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Closes the active socket so a blocking read returns and the main thread
    /// can notice `running == false`. Called from the monitor thread, which is
    /// the only one allowed to touch the descriptor besides the main loop.
    pub fn kick(self: *Monitor) void {
        const fd = self.socket.load(.acquire);
        if (fd >= 0) std.posix.shutdown(@intCast(fd), .both) catch {};
    }

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

            self.view.store(
                self.miner.hashrate(10),
                self.miner.hashrate(60),
                self.miner.hashrate(900),
                self.miner.stats.max_rate,
                self.miner.shared.totalHashes(),
            );

            if (self.report_file) |path| {
                if (now - self.last_report_write >= self.report_interval_ms) {
                    self.last_report_write = now;
                    self.writeReport(path, now);
                }
            }

            // A SIGTERM must not wait for the pool to say something: the main
            // thread is parked in a blocking read, so nudge it here.
            if (!running.load(.acquire)) self.kick();

            // A Cloudflare-fronted WebSocket (and any NAT/firewall in between)
            // drops a connection that carries no traffic. Sending keepalived
            // from this thread keeps the same socket alive for hours.
            if (self.keepalive_enabled) self.miner.submitter.keepaliveIfIdle(self.keepalive_ms, self.logger);

            const last = self.last_message.load(.acquire);
            const fd = self.socket.load(.acquire);
            if (self.idle_timeout_ms > 0 and last != 0 and fd >= 0 and now - last > self.idle_timeout_ms) {
                self.logger.warn("pool has been silent for {d} s, dropping the connection", .{@divTrunc(now - last, 1000)});
                std.posix.shutdown(@intCast(fd), .both) catch {};
            }
        }
    }

    /// Writes `ZMRIG1.<...>` to the report file. A failure is logged once and
    /// never stops the miner: a read-only /run must not kill a good session.
    fn writeReport(self: *Monitor, path: []const u8, now_ms: i64) void {
        if (self.report_file == null) return;

        const uptime_ms = now_ms - self.report_started_ms;

        if (!self.report_power_measured) {
            // Give the workers time to reach full load first; a 250 ms sample
            // of an idle package would understate the electricity badly.
            if (uptime_ms < 30_000) return;

            self.report_power_measured = true;
            const power = report.measurePower(self.report_user_power);
            self.report_power = power.watts;
            self.report_power_source = power.source;
        }

        var cpu_buf: [256]u8 = undefined;
        var code_buf: [1400]u8 = undefined;

        const huge_pages = self.miner.hugePages();
        const power = self.report_power;

        const code = report.encode(&code_buf, .{
            .id = self.report_id,
            .version = version,
            .cpu = report.cpuModel(&cpu_buf),
            .threads = self.miner.threadCount(),
            .cores = report.physicalCores(miner_mod.cpuCount()),
            .algo = if (self.miner.engine.algo) |algo| algo.label() else "auto",
            .mode = self.report_mode,
            .rates = .{
                self.miner.hashrate(10),
                self.miner.hashrate(60),
                self.miner.hashrate(900),
                self.miner.stats.max_rate,
            },
            .huge_pages = huge_pages,
            .shares = .{
                self.miner.submitter.accepted.load(.monotonic),
                self.miner.submitter.rejected.load(.monotonic),
                self.miner.submitter.failed.load(.monotonic),
            },
            .hashes = self.miner.shared.totalHashes(),
            .uptime_s = @divTrunc(uptime_ms, 1000),
            .power_watts = power,
            .power_source = self.report_power_source,
            .pool = self.report_pool,
            .timestamp = std.time.timestamp(),
        }) catch return;

        // The directory may not exist yet (a fresh unit, a custom --report-file):
        // create it instead of skipping the report for the whole run.
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};

        var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |e| {
            if (!self.report_error_logged) {
                self.report_error_logged = true;
                self.logger.warn("cannot write the report file {s}: {s}", .{ path, @errorName(e) });
            }

            return;
        };
        defer file.close();

        file.writeAll(code) catch {};
        file.writeAll("\n") catch {};
    }
};

fn mergeOptions(allocator: std.mem.Allocator, base: *options.Options, extra: *options.Options) void {
    if (extra.algo) |v| base.algo = v;
    if (extra.threads) |v| base.threads = v;
    if (extra.pools.items.len > 0) {
        // Command line pools replace config file pools, like xmrig does. Take
        // ownership of the CLI buffers instead of copying: `extra` is discarded
        // right after the merge and a copy would leak on every start.
        for (base.pools.items) |pool| options.freePool(allocator, pool);

        base.pools.clearRetainingCapacity();
        base.pools.appendSlice(allocator, extra.pools.items) catch {
            // Out of memory here means we cannot mine anyway; keep the config
            // pools rather than dying inside a void function.
            return;
        };
        extra.pools.clearRetainingCapacity();
    }
    // Only what the command line set: a plain `-c config.json --verbose` must
    // not reset mode, threads, retries or huge pages to their defaults.
    if (extra.seen.mode) base.mode = extra.mode;
    if (extra.seen.huge_pages) base.huge_pages = extra.huge_pages;
    if (extra.seen.huge_pages_jit) base.huge_pages_jit = extra.huge_pages_jit;
    if (extra.seen.jit) base.jit = extra.jit;
    if (extra.seen.print_time) base.print_time = extra.print_time;
    if (extra.seen.retries) base.retries = extra.retries;
    if (extra.seen.retry_pause) base.retry_pause = extra.retry_pause;
    if (extra.seen.colors) base.colors = extra.colors;
    if (extra.seen.verbose) base.verbose = extra.verbose;
    if (extra.seen.affinity) base.affinity = extra.affinity;
    if (extra.seen.affinity_mask) base.affinity_mask = extra.affinity_mask;
    if (extra.seen.user_agent) base.user_agent = extra.user_agent;
    if (extra.seen.init_threads) base.init_threads = extra.init_threads;
    // MSR is opt-in, and "opt-in on the command line" has to work too.
    if (extra.seen.msr) base.msr = extra.msr;
    if (extra.seen.msr_restore) base.msr_restore = extra.msr_restore;
    if (extra.seen.priority) base.priority = extra.priority;
    if (extra.seen.idle_timeout) base.idle_timeout = extra.idle_timeout;
    if (extra.seen.keepalive_interval) base.keepalive_interval = extra.keepalive_interval;
    if (extra.seen.scratchpad_prefetch) base.scratchpad_prefetch = extra.scratchpad_prefetch;
    if (extra.seen.optimized_init) base.optimized_init = extra.optimized_init;
    if (extra.log_file) |v| base.log_file = v;
    if (extra.api_port != 0) base.api_port = extra.api_port;
    if (extra.check) base.check = true;
    if (extra.self_test) base.self_test = true;
    if (extra.benchmark) {
        base.benchmark = true;
        base.bench_hashes = extra.bench_hashes;
    }

    // These short-circuit the run, so they must survive the merge: dropping
    // them turned `zmrig -c config.json --check` into a live miner.
    if (extra.check) base.check = true;
    if (extra.self_test) base.self_test = true;
    if (extra.self_test_light) base.self_test_light = true;
    if (extra.help) base.help = true;
    if (extra.version) base.version = true;
    if (extra.verbose) base.verbose = true;
    if (extra.seen.background) base.background = extra.background;
    // The report flags follow the same rule: a config file may already carry a
    // report file, an interval, an id and a power figure, and a command line
    // that does not mention them must leave those values alone.
    if (extra.seen.report) base.report = true;
    if (extra.seen.report_time) base.report_seconds = extra.report_seconds;
    if (extra.seen.report_file) {
        if (base.report_file) |old| allocator.free(old);
        base.report_file = extra.report_file;
    }
    if (extra.seen.report_interval) base.report_interval = extra.report_interval;
    if (extra.seen.report_id) {
        if (base.report_id) |old| allocator.free(old);
        base.report_id = extra.report_id;
    }
    if (extra.seen.power) base.power_watts = extra.power_watts;
    if (extra.http_host.len > 0) base.http_host = extra.http_host;

    if (extra.transport_override) |v| base.transport_override = v;
    if (extra.ws_path) |v| base.ws_path = v;
    if (extra.ws_origin) |v| base.ws_origin = v;
    if (extra.host_header) |v| base.host_header = v;
    if (extra.connect_to) |v| base.connect_to = v;
    if (extra.tls_ca) |v| base.tls_ca = v;
    if (extra.proxy_url) |v| base.proxy_url = v;
    if (extra.cloudflare) base.cloudflare = true;
}

/// --check: print what the miner would do, without touching the network.
/// Applies the RandomX MSR preset when the user asked for it. Returns true when
/// the values were written (so the caller knows there is something to restore).
fn applyMsr(opts: *const options.Options, logger: *log.Logger) bool {
    if (!opts.msr) return false;

    var report_buf: [192]u8 = undefined;
    @memset(&report_buf, 0);
    const rc = api.xmo_msr_apply(@intFromBool(opts.msr_restore), &report_buf, report_buf.len);
    const text = report_buf[0..std.mem.indexOfScalar(u8, &report_buf, 0) orelse report_buf.len];

    switch (rc) {
        0 => {
            logger.info("msr: {s}", .{text});

            return true;
        },
        2 => {
            logger.warn("msr: {s}", .{text});

            return true;
        },
        else => {
            logger.warn("msr not applied: {s}", .{text});

            return false;
        },
    }
}

fn printConfigSummary(opts: *const options.Options) !void {
    var out = std.io.getStdOut().writer();

    try out.print("config ok\n", .{});

    for (opts.pools.items) |pool| {
        try out.print("  pool    {s}://{s}:{d}{s} user={s} algo={s}\n", .{
            pool.transport.label(),
            pool.host,
            pool.port,
            if (pool.transport.usesWs()) (pool.ws_path orelse "/") else "",
            pool.user,
            if (opts.poolAlgo(&pool)) |algo| algo.label() else "auto",
        });

        if (pool.connect_host) |host| {
            try out.print("  route   connect {s}:{d}, Host: {s}\n", .{
                host,
                pool.connect_port orelse pool.port,
                pool.host_header orelse pool.host,
            });
        }
        if (pool.proxy_spec.kind != .none) {
            try out.print("  proxy   {s} {s}:{d}\n", .{ @tagName(pool.proxy_spec.kind), pool.proxy_spec.host, pool.proxy_spec.port });
        }
    }

    try out.print("  threads {d} (default would be {d})\n", .{ opts.threads orelse miner_mod.defaultThreads(miner_mod.cpuCount()), miner_mod.defaultThreads(miner_mod.cpuCount()) });
    if (opts.priority != -1) {
        try out.print("  priority {d}\n", .{opts.priority});
    }
    if (opts.affinity_mask) |mask| {
        const cpus = miner_mod.Miner.affinityCpus(mask);
        if (cpus == 0) {
            // An empty mask silently means "no pinning" otherwise.
            try out.print("  affinity 0x{x} selects no CPU; it will be ignored\n", .{mask});
        } else {
            try out.print("  affinity 0x{x} ({d} cpu(s))\n", .{ mask, cpus });
        }
    }
    if (opts.init_threads > 0) {
        try out.print("  dataset  built with {d} thread(s)\n", .{opts.init_threads});
    }
    if (opts.user_agent) |ua| {
        try out.print("  agent   {s}\n", .{ua});
    }

    try out.print("  mode    {s}, huge pages {s}, jit {s}\n", .{
        @tagName(opts.mode),
        if (opts.huge_pages) "on" else "off",
        if (opts.jit) "on" else "off",
    });

    // The single most common reason a VPS mines 25% slower than it should is
    // that nobody reserved huge pages. Say it during --check, before the user
    // spends a night comparing screenshots of hashrate.
    if (opts.huge_pages) {
        try out.print("  memory  {s}\n", .{hugePageStatus(opts.mode)});
    }

    // MSR is read-only here: probe the first CPU, never write during --check.
    var msr_buf: [192]u8 = undefined;
    _ = api.xmo_msr_probe(&msr_buf, msr_buf.len);
    try out.print("  msr     {s} ({s})\n", .{
        msr_buf[0..std.mem.indexOfScalar(u8, &msr_buf, 0) orelse msr_buf.len],
        if (opts.msr) "on" else "off, enable with --msr",
    });
}

/// Reads the kernel's huge page pool and turns it into one sentence a human can
/// act on. Kept separate so --check and the warning in miner.zig agree.
fn hugePageStatus(mode: options.Mode) []const u8 {
    const needed_mb: u64 = switch (mode) {
        .light => 320,
        .fast => 2416,
        .auto => 2416,
    };
    const pages_needed = (needed_mb + 1) / 2;

    var buf: [32]u8 = undefined;
    const file = std.fs.openFileAbsolute("/proc/sys/vm/nr_hugepages", .{}) catch return "huge pages: not supported by this kernel";
    defer file.close();

    const n = file.readAll(&buf) catch return "huge pages: cannot read /proc/sys/vm/nr_hugepages";
    const total = std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n\r"), 10) catch 0;

    if (total >= pages_needed) return "huge pages reserved, RandomX will use 2 MiB pages";

    // Returning a slice of a thread-local buffer is not possible here, so the
    // caller gets one of two static messages and the command in the usage text.
    return if (total == 0)
        "huge pages: 0 reserved -> falling back to 4 KiB (up to 25% slower); see --help"
    else
        "huge pages: fewer reserved than this mode needs; see --help";
}

/// Detaches from the controlling terminal: the parent returns and the child
/// keeps running with stdin/stdout/stderr on /dev/null.
fn daemonise() !void {
    const pid = try std.posix.fork();
    if (pid != 0) std.process.exit(0);

    _ = std.os.linux.setsid();

    const devnull = try std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(devnull);

    try std.posix.dup2(devnull, std.posix.STDIN_FILENO);
    try std.posix.dup2(devnull, std.posix.STDOUT_FILENO);
    try std.posix.dup2(devnull, std.posix.STDERR_FILENO);
}

/// How long to wait before the next connection attempt. A dropped connection
/// comes back in 200 ms instead of `--retry-pause` seconds, and repeated
/// failures back off to the configured pause instead of hammering a dead pool.
fn retryDelayMs(configured_seconds: u32, failures: u32) u64 {
    const configured: u64 = @as(u64, configured_seconds) * 1000;

    if (configured == 0) return 0;

    const backoff: u64 = switch (failures) {
        0, 1 => 200,
        2 => 500,
        3 => 1000,
        else => configured,
    };

    return @min(configured, backoff);
}

fn sleepInterruptibleMs(ms: u64) void {
    var slept: u64 = 0;

    while (slept < ms) : (slept += 100) {
        if (!running.load(.acquire)) return;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
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

/// Exits with a readable message when the dataset cannot fit.
fn requireMemory(needed_mb: u64) !void {
    const memory = report.checkMemory(needed_mb);
    if (memory.ok) return;

    var stderr = std.io.getStdErr().writer();
    try stderr.print(
        "zmrig: not enough memory for the {d} MB dataset: {d} MB free in huge pages, {d} MB available\n" ++
            "       stop other miners (or lower vm.nr_hugepages) and try again, or use --mode light\n",
        .{ needed_mb, memory.huge_free_mb, memory.available_mb },
    );

    std.process.exit(2);
}

// --- benchmark -------------------------------------------------------------------

const Measure = struct {
    hashes: u64 = 0,
    elapsed_ms: i64 = 0,
    /// Hashes / wall time, the number XMRig prints for `--bench`.
    rate: f64 = 0,
    /// The last 10 s window: excludes the ramp after the dataset is built, so
    /// it is the number a dashboard should use for profit estimates.
    steady_rate: f64 = 0,
    huge_pages: usize = 0,
};

fn benchmark(allocator: std.mem.Allocator, opts: *const options.Options, cap_seconds: u64, warmup_seconds: u64) !Measure {
    const logger = &log.global;
    // A benchmark is where the MSR preset matters most: it is the number the
    // user compares against another miner.
    const msr_applied = applyMsr(opts, logger);
    defer if (msr_applied and opts.msr_restore) {
        var buf: [192]u8 = undefined;
        @memset(&buf, 0);
        _ = api.xmo_msr_restore(&buf, buf.len);
    };

    // Deterministic seed so repeated runs are comparable.
    const seed_text = "zmrig benchmark seed 000000000000";
    var seed_bytes: [32]u8 = undefined;
    _ = try util.hexToBytes(&seed_bytes, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");

    var miner = try miner_mod.Miner.init(logger, opts);
    defer miner.deinit();

    try miner.engine.ensure(opts.algo orelse .rx_0);
    try miner.engine.seedNow(seed_bytes, miner.shared.initThreads());

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
        const limit_s = @max(cap_seconds, 1) + warmup_seconds;
        if (now - started >= @as(i64, @intCast(limit_s)) * 1000) break;

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
    // Read the counters that live in the engine *before* stopping it: after
    // stop() the huge page bookkeeping is gone (and touching it crashed).
    const huge_pages = miner.hugePages()[0];
    const steady_rate = miner.hashrate(10);

    miner.stop();

    var buf: [32]u8 = undefined;
    const rate = @as(f64, @floatFromInt(total)) * 1000.0 / @as(f64, @floatFromInt(@max(elapsed_ms, 1)));
    const scaled = util.scaleHashrate(rate);

    logger.info("benchmark: {d} hashes in {d} ms = {s}", .{
        total,
        elapsed_ms,
        std.fmt.bufPrint(&buf, "{d:.3} {s}", .{ scaled.value, scaled.unit }) catch "?",
    });

    return .{
        .hashes = total,
        .elapsed_ms = elapsed_ms,
        .rate = rate,
        .steady_rate = steady_rate,
        .huge_pages = huge_pages,
    };
}

test "reconnect backoff: quick first tries, then the configured pause" {
    const testing = std.testing;

    // A pool that refuses immediately must not be hammered every 200 ms
    // forever, and a configured pause of 0 must stay 0.
    try testing.expectEqual(@as(u64, 200), retryDelayMs(5, 1));
    try testing.expectEqual(@as(u64, 500), retryDelayMs(5, 2));
    try testing.expectEqual(@as(u64, 1000), retryDelayMs(5, 3));
    try testing.expectEqual(@as(u64, 5000), retryDelayMs(5, 4));
    try testing.expectEqual(@as(u64, 5000), retryDelayMs(5, 99));
    try testing.expectEqual(@as(u64, 0), retryDelayMs(0, 9));

    // retry-pause is in whole seconds, so the shortest non-zero pause is 1 s;
    // the backoff still starts at 200 ms under that cap.
    try testing.expectEqual(@as(u64, 200), retryDelayMs(1, 1));
}
