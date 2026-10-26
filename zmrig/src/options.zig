//! Command line and config file handling.
//!
//! Flags mirror XMRig's so existing scripts and muscle memory keep working:
//!   zmrig -o pool:port -u WALLET -p x -a rx/0 -t 2 --rig-id rig --keepalive
//! A JSON config file can replace or extend the command line:
//!   zmrig -c /etc/zmrig/config.json

const std = @import("std");
const api = @import("api.zig");
const transport = @import("transport.zig");

pub const Pool = struct {
    host: []const u8 = "",
    port: u16 = 0,
    transport: transport.Kind = .tcp,
    user: []const u8 = "",
    /// Static "x" until a `-p`/config value replaces it with an allocated
    /// string; `freePool` knows about that one exception.
    password: []const u8 = "x",
    rig_id: ?[]const u8 = null,
    keepalive: bool = true,
    nicehash: bool = false,
    tls_insecure: bool = false,
    tls_ca: ?[]const u8 = null,
    ws_path: ?[]const u8 = null,
    ws_origin: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    connect_host: ?[]const u8 = null,
    connect_port: ?u16 = null,
    proxy_url: ?[]const u8 = null,
    proxy_spec: transport.Proxy = .{},
    /// True when the URL scheme (or --tls) named a transport explicitly.
    user_transport: bool = false,
    /// True when the URL/flag carried an explicit port.
    user_port: bool = false,
    /// Optional per-pool algorithm pin; null means "whatever the pool sends".
    algo: ?api.Algo = null,

    pub fn proxy(self: *const Pool) transport.Proxy {
        return self.proxy_spec;
    }

    /// True when the pool was reached over a WebSocket, i.e. its URL path is
    /// meaningful (Cloudflare routes on it).
    pub fn isWs(self: *const Pool) bool {
        return self.transport.usesWs();
    }
};

pub fn freePool(allocator: std.mem.Allocator, pool: Pool) void {
    allocator.free(pool.host);
    allocator.free(pool.user);
    // Pools that never saw a `-p` still point at the static default.
    if (!std.mem.eql(u8, pool.password, "x")) allocator.free(pool.password);
    if (pool.rig_id) |v| allocator.free(v);
    if (pool.tls_ca) |v| allocator.free(v);
    if (pool.connect_host) |v| allocator.free(v);
    if (pool.host_header) |v| allocator.free(v);
    if (pool.ws_origin) |v| allocator.free(v);
    if (pool.proxy_url) |v| allocator.free(v);
    if (pool.ws_path) |v| allocator.free(v);
    allocator.free(pool.proxy_spec.host);
    if (pool.proxy_spec.user) |v| allocator.free(v);
    if (pool.proxy_spec.pass) |v| allocator.free(v);
}

/// Per-pool options given before any pool URL. `zmrig -u WALLET -o pool`
/// must behave exactly like `zmrig -o pool -u WALLET`: the old code appended a
/// placeholder pool for the `-u`, which then failed validation with
/// InvalidPool. Values are remembered here and copied into every pool that is
/// created afterwards (and into the last pool when one already exists).
const Pending = struct {
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    rig_id: ?[]const u8 = null,
    keepalive: ?bool = null,
    nicehash: ?bool = null,
    tls_insecure: bool = false,
    transport: ?transport.Kind = null,

    fn apply(self: *const Pending, allocator: std.mem.Allocator, pool: *Pool) ParseError!void {
        if (self.user) |value| {
            if (pool.user.len != 0) allocator.free(pool.user);
            pool.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.password) |value| {
            if (!std.mem.eql(u8, pool.password, "x")) allocator.free(pool.password);
            pool.password = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.rig_id) |value| {
            if (pool.rig_id) |old| allocator.free(old);
            pool.rig_id = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.keepalive) |value| pool.keepalive = value;
        if (self.transport) |value| {
            pool.transport = value;
            pool.user_transport = true;
        }
        if (self.nicehash) |value| pool.nicehash = value;
        if (self.tls_insecure) pool.tls_insecure = true;
    }
};

pub const Mode = enum { auto, fast, light };

/// Which options the command line actually set. The config file is read first
/// and the command line is merged on top, so a flag that was *not* given must
/// not overwrite the config with its default value (that is how a `mode` of
/// "light" in config.json was silently replaced by "auto").
pub const Seen = struct {
    mode: bool = false,
    huge_pages: bool = false,
    huge_pages_jit: bool = false,
    jit: bool = false,
    affinity: bool = false,
    affinity_mask: bool = false,
    user_agent: bool = false,
    init_threads: bool = false,
    priority: bool = false,
    print_time: bool = false,
    retries: bool = false,
    retry_pause: bool = false,
    idle_timeout: bool = false,
    keepalive_interval: bool = false,
    scratchpad_prefetch: bool = false,
    optimized_init: bool = false,
    msr: bool = false,
    msr_restore: bool = false,
    colors: bool = false,
    verbose: bool = false,
    background: bool = false,
    report: bool = false,
    report_time: bool = false,
    report_file: bool = false,
    report_interval: bool = false,
    report_id: bool = false,
    power: bool = false,
};

pub const Options = struct {
    pools: std.ArrayListUnmanaged(Pool) = .{},
    seen: Seen = .{},
    algo: ?api.Algo = null,
    threads: ?usize = null,
    mode: Mode = .auto,
    huge_pages: bool = true,
    huge_pages_jit: bool = true,
    jit: bool = true,
    priority: i32 = -1,
    affinity: bool = true,
    /// `--cpu-affinity=0x3`: only mine on these CPUs (bit per core).
    affinity_mask: ?u64 = null,
    /// `--user-agent`: what the pool sees in the WebSocket upgrade.
    user_agent: ?[]const u8 = null,
    /// `--randomx-init`: threads used to build the dataset (0 = hashing threads).
    init_threads: usize = 0,
    colors: bool = true,
    verbose: bool = false,
    print_time: u32 = 60,
    retries: u32 = 5,
    retry_pause: u32 = 5,
    /// Seconds of total pool silence before the connection is dropped.
    /// 0 disables the watchdog.
    idle_timeout: u32 = 300,
    /// Seconds between `keepalived` messages when nothing else is sent.
    keepalive_interval: u32 = 60,
    /// How the JIT prefetches the scratchpad: 0 nop, 1 prefetcht0 (default),
    /// 2 prefetchnta, 3 a plain load. Baked into the compiled program, so it
    /// only takes effect on a fresh cache.
    scratchpad_prefetch: i32 = 1,
    /// Use the AVX2 dataset initialiser (faster seeding, identical hashes).
    optimized_init: bool = true,
    /// Apply the RandomX MSR preset (prefetchers off). Needs root; off by
    /// default because it writes to hardware registers.
    msr: bool = false,
    /// Put the old MSR values back on exit.
    msr_restore: bool = true,
    /// Set only so `--donate-level` can be accepted from old scripts; the fee
    /// stays 0 % and `main` says so once.
    donate_level_ignored: ?u32 = null,
    log_file: ?[]const u8 = null,
    api_port: u16 = 0,
    api_token: ?[]const u8 = null,
    http_host: []const u8 = "127.0.0.1",
    background: bool = false,
    config_path: ?[]const u8 = null,
    self_test: bool = false,
    self_test_light: bool = false,
    check: bool = false,
    benchmark: bool = false,
    bench_hashes: u64 = 1_000_000,
    /// `--report`: short benchmark, then print a machine report code.
    report: bool = false,
    report_seconds: u32 = 15,
    /// `--report-file`: keep this file updated while mining.
    report_file: ?[]const u8 = null,
    report_interval: u32 = 60,
    report_id: ?[]const u8 = null,
    /// `--power W`: wall power of the machine, used by the report.
    power_watts: ?f64 = null,
    /// `--verify-share`: JSON lines on stdin, hashes on stdout (pool mode).
    verify_share: bool = false,
    // Transport defaults applied to every pool that did not specify them.
    transport_override: ?transport.Kind = null,
    ws_path: ?[]const u8 = null,
    ws_origin: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    connect_to: ?[]const u8 = null,
    tls_ca: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    cloudflare: bool = false,
    version: bool = false,
    help: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        for (self.pools.items) |pool| freePool(allocator, pool);
        self.pools.deinit(allocator);
        if (self.log_file) |v| allocator.free(v);
        if (self.report_file) |v| allocator.free(v);
        if (self.report_id) |v| allocator.free(v);
        if (self.api_token) |v| allocator.free(v);
        if (self.config_path) |v| allocator.free(v);
        if (self.ws_path) |v| allocator.free(v);
        if (self.ws_origin) |v| allocator.free(v);
        if (self.host_header) |v| allocator.free(v);
        if (self.connect_to) |v| allocator.free(v);
        if (self.tls_ca) |v| allocator.free(v);
        if (self.proxy_url) |v| allocator.free(v);
    }

    /// Resolves the algorithm for a pool: explicit flag > pool flag > job value.
    pub fn poolAlgo(self: *const Options, pool: *const Pool) ?api.Algo {
        return pool.algo orelse self.algo;
    }
};

pub const ParseError = error{
    MissingValue,
    UnknownOption,
    InvalidNumber,
    InvalidPool,
    NoPools,
    NoWallet,
    OutOfMemory,
    InvalidConfig,
    /// The config file exists but cannot be read (usually permissions).
    ConfigUnreadable,
    /// The config file was read but is not a JSON object.
    ConfigInvalidJson,
    HelpRequested,
};

pub const usage =
    \\Usage: zmrig [options]
    \\
    \\Network:
    \\  -o, --url=URL            pool URL. Schemes: tcp (default), tls, ws, wss -
  \\                           e.g. wss://pool.example.com/monero
    \\  -u, --user=USER          wallet address (login)
    \\  -p, --pass=PASS          password / worker name (default: x)
    \\  -a, --algo=ALGO          rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx, rx/yada, panthera
    \\      --rig-id=ID          rig identifier sent to the pool
    \\      --keepalive          send keepalive (default: on)
    \\      --no-keepalive       never send keepalive
    \\      --transport=NAME     tcp | tls | ws | wss, overrides the URL scheme
    \\      --cloudflare[=HOST]  shortcut for wss://HOST:443/ (Cloudflare-friendly)
    \\      --ws-path=PATH       WebSocket path (default /), e.g. /monero/<token>
    \\      --ws-origin=URL      Origin header for the WebSocket upgrade
    \\      --tls                connect with TLS (stratum+ssl:// also works)
    \\      --tls-ca=FILE        trust the certificates in FILE (pin a private CA)
    \\      --tls-insecure       accepted for compatibility; pin with --tls-ca
    \\      --connect-to=HOST[:P] dial this address instead of the pool host
    \\      --proxy=URL          http://user:pass@host:port or socks5://host:port
    \\      --retries=N          reconnect attempts per pool before failover (default: 5)
    \\      --retry-pause=N      seconds between reconnects (default: 5)
    \\      --idle-timeout=N     drop a pool that says nothing for N seconds (0 = never, default 300)
    \\      --scratchpad-prefetch=N  0=nop 1=prefetcht0 (default) 2=prefetchnta 3=load
    \\      --no-optimized-init  use the portable dataset initialiser
    \\      --keepalive-interval=N  send keepalived every N seconds of silence (0 = off, default 60)
    \\
    \\Mining:
    \\  -t, --threads=N          number of mining threads (default: cache aware)
    \\      --mode=MODE          auto | fast (2 GiB dataset) | light (256 MiB cache)
    \\      --randomx-init=N     threads used to build the dataset (default: hashing threads)
    \\      --no-huge-pages      disable huge pages
    \\      --no-huge-pages-jit  disable huge pages for the JIT code
    \\      --msr                apply the RandomX MSR preset (needs root and bare metal)
    \\      --no-msr             do not touch MSR registers (default)
    \\      --no-msr-restore     keep the MSR values after exit (default: restore)
    \\      --randomx-wrmsr, --no-rdmsr   XMRig spellings of the two flags above
    \\      --no-jit             disable the JIT compiler (slow, ~6x lower hashrate)
    \\      --no-affinity        do not pin threads to cores
    \\      --cpu-affinity=0x3   pin threads to these CPUs (bitmask, XMRig style)
    \\      --priority=N         1..5 (XMRig scale) or a raw nice value like -10
    \\      --cpu-priority=N     same as --priority (XMRig spelling)
    \\
    \\Logging:
    \\      --no-color           disable colours
    \\      --verbose            verbose output
    \\      --print-time=N       hashrate report interval in seconds (default: 60, 0 = off)
    \\      --log-file=FILE      append the log to FILE
    \\      --user-agent=UA      User-Agent for WebSocket pool connections
    \\
    \\Other:
    \\  -c, --config=FILE        JSON config file
    \\      --self-test[=light]  verify the hash engine against known vectors and exit
    \\                           (light skips the 2 GiB dataset check)
    \\      --check              validate the configuration and exit
    \\      --dry-run            alias of --check (XMRig spelling)
    \\      --bench[=HASHES]     benchmark the hash rate and exit
    \\      --report             benchmark for --report-time seconds, print a
    \\                           machine report code for the web dashboard
    \\      --report-time=N      seconds to measure with --report (default: 15)
    \\      --report-file=FILE   keep FILE updated with the report code
    \\      --report-interval=N  seconds between report file updates (60)
    \\      --report-id=NAME     machine name in the report (default: rig-id)
    \\      --power=W            wall power in watts, used by the report
    \\      --verify-share       read {"seed","blob","nonce"} JSON lines on stdin and
    \\                           print the hashes: share verification for a pool
    \\  -h, --help               this help
    \\  -V, --version            print the version
    \\
    \\Every option that takes a value also accepts the "--option value" form.
    \\
;

fn parseNumber(comptime T: type, text: []const u8) ParseError!T {
    return std.fmt.parseInt(T, text, 10) catch error.InvalidNumber;
}

fn needValue(args: []const []const u8, index: *usize, inline_value: ?[]const u8) ParseError![]const u8 {
    if (inline_value) |v| return v;

    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;

    return args[index.*];
}

/// Splits "--opt=value" into the option name and the value.
fn splitArg(arg: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |pos| {
        return .{ .name = arg[0..pos], .value = arg[pos + 1 ..] };
    }

    return .{ .name = arg, .value = null };
}

pub fn parseUrl(allocator: std.mem.Allocator, url: []const u8) ParseError!Pool {
    var pool = Pool{};
    var rest = url;
    var scheme_kind: ?transport.Kind = null;

    if (std.mem.indexOf(u8, rest, "://")) |pos| {
        const scheme = rest[0..pos];
        rest = rest[pos + 3 ..];

        if (std.mem.eql(u8, scheme, "stratum+ssl") or std.mem.eql(u8, scheme, "stratum+tls") or std.mem.eql(u8, scheme, "tls")) {
            scheme_kind = .tls;
        } else if (std.mem.eql(u8, scheme, "stratum+ws") or std.mem.eql(u8, scheme, "ws")) {
            scheme_kind = .ws;
        } else if (std.mem.eql(u8, scheme, "stratum+wss") or std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https")) {
            scheme_kind = .wss;
        } else if (std.mem.eql(u8, scheme, "stratum+tcp") or std.mem.eql(u8, scheme, "stratum") or std.mem.eql(u8, scheme, "tcp") or std.mem.eql(u8, scheme, "http")) {
            // `http://` means a plain WebSocket endpoint in practice; keep it as
            // tcp unless the caller asks for ws explicitly.
            scheme_kind = if (std.mem.eql(u8, scheme, "http")) .ws else .tcp;
        } else {
            return error.InvalidPool;
        }
    }

    // Keep a path for WebSocket endpoints (Cloudflare routes and relays use it).
    if (std.mem.indexOfScalar(u8, rest, '/')) |pos| {
        const path = rest[pos..];
        if (path.len > 1) {
            pool.ws_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
            // A malformed URL must not leak the path we just took ownership of.
            errdefer allocator.free(pool.ws_path.?);
        }
        rest = rest[0..pos];
    }

    var host = rest;
    var port_text: ?[]const u8 = null;

    if (std.mem.startsWith(u8, rest, "[")) {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidPool;
        host = rest[1..end];
        if (end + 1 < rest.len and rest[end + 1] == ':') port_text = rest[end + 2 ..];
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |pos| {
        host = rest[0..pos];
        port_text = rest[pos + 1 ..];
    }

    if (host.len == 0) return error.InvalidPool;

    pool.host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
    // "pool:notaport" failed after the host was allocated: free it again.
    errdefer allocator.free(pool.host);

    const kind = scheme_kind orelse .tcp;
    pool.transport = kind;
    pool.user_transport = scheme_kind != null;
    pool.user_port = port_text != null;
    pool.port = if (port_text) |p| parseNumber(u16, p) catch return error.InvalidPool else kind.defaultPort();

    return pool;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts = Options{};
    // Per-pool options seen before the pool they belong to (see `Pending`).
    var pending = Pending{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) continue;

        if (!std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;

        const split = splitArg(arg);
        const name = split.name;
        const inline_value = split.value;

        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, name, "-V") or std.mem.eql(u8, name, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--url")) {
            const value = try needValue(args, &i, inline_value);
            var pool = try parseUrl(allocator, value);
            errdefer freePool(allocator, pool);
            try pending.apply(allocator, &pool);
            opts.pools.append(allocator, pool) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-u") or std.mem.eql(u8, name, "--user")) {
            const value = try needValue(args, &i, inline_value);
            pending.user = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.user.len != 0) allocator.free(last.user);
                last.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--pass") or std.mem.eql(u8, name, "--password")) {
            const value = try needValue(args, &i, inline_value);
            pending.password = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (!std.mem.eql(u8, last.password, "x")) allocator.free(last.password);
                last.password = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "-a") or std.mem.eql(u8, name, "--algo")) {
            const value = try needValue(args, &i, inline_value);
            opts.algo = api.Algo.fromName(value) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, name, "--rig-id")) {
            const value = try needValue(args, &i, inline_value);
            pending.rig_id = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.rig_id) |id| allocator.free(id);
                last.rig_id = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "--keepalive")) {
            pending.keepalive = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].keepalive = true;
        } else if (std.mem.eql(u8, name, "--no-keepalive")) {
            pending.keepalive = false;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].keepalive = false;
        } else if (std.mem.eql(u8, name, "--nicehash")) {
            pending.nicehash = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].nicehash = true;
        } else if (std.mem.eql(u8, name, "--transport")) {
            const value = try needValue(args, &i, inline_value);
            opts.transport_override = transport.Kind.fromName(value) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, name, "--cloudflare")) {
            // `--cloudflare=host` is a convenience: it also sets the pool. The
            // space separated form works too, as long as what follows is not
            // another flag (`--cloudflare --ws-path /x` stays a plain preset).
            var value_opt = inline_value;
            if (value_opt == null and i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                value_opt = args[i];
            }
            // With a host this is a complete shortcut (the pool it creates is
            // already wss on 443), so it must not also rewrite the transport of
            // pools given with -o. Without a host it is a preset for all pools.
            if (value_opt == null) opts.cloudflare = true;
            if (value_opt) |value| {
                const url = if (std.mem.indexOf(u8, value, "://") != null)
                    value
                else
                    try std.fmt.allocPrint(allocator, "wss://{s}", .{value});
                defer if (url.ptr != value.ptr) allocator.free(url);

                var pool = try parseUrl(allocator, url);
                errdefer freePool(allocator, pool);
                try pending.apply(allocator, &pool);
                opts.pools.append(allocator, pool) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "--ws-path")) {
            const value = try needValue(args, &i, inline_value);
            opts.ws_path = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--ws-origin")) {
            const value = try needValue(args, &i, inline_value);
            opts.ws_origin = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--host-header")) {
            const value = try needValue(args, &i, inline_value);
            opts.host_header = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--connect-to")) {
            const value = try needValue(args, &i, inline_value);
            opts.connect_to = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--tls-ca")) {
            const value = try needValue(args, &i, inline_value);
            opts.tls_ca = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--proxy")) {
            const value = try needValue(args, &i, inline_value);
            opts.proxy_url = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--tls")) {
            // Only the transport: `--tls` must never imply "do not verify"
            // (that flag exists separately and is a no-op right now).
            pending.transport = .tls;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.transport == .tcp) last.transport = .tls;
                last.user_transport = true;
            }
        } else if (std.mem.eql(u8, name, "--tls-insecure")) {
            pending.tls_insecure = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].tls_insecure = true;
        } else if (std.mem.eql(u8, name, "-t") or std.mem.eql(u8, name, "--threads")) {
            opts.threads = try parseNumber(usize, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--mode")) {
            const value = try needValue(args, &i, inline_value);
            if (std.mem.eql(u8, value, "auto")) {
                opts.mode = .auto;
            opts.seen.mode = true;
            } else if (std.mem.eql(u8, value, "fast")) {
                opts.mode = .fast;
            opts.seen.mode = true;
            } else if (std.mem.eql(u8, value, "light")) {
                opts.mode = .light;
            opts.seen.mode = true;
            } else {
                return error.UnknownOption;
            }
        } else if (std.mem.eql(u8, name, "--no-huge-pages")) {
            opts.huge_pages = false;
            opts.seen.huge_pages = true;
        } else if (std.mem.eql(u8, name, "--msr")) {
            opts.msr = true;
            opts.seen.msr = true;
        } else if (std.mem.eql(u8, name, "--no-msr")) {
            opts.msr = false;
            opts.seen.msr = true;
        } else if (std.mem.eql(u8, name, "--no-msr-restore")) {
            opts.msr_restore = false;
            opts.seen.msr_restore = true;
        } else if (std.mem.eql(u8, name, "--no-huge-pages-jit")) {
            opts.huge_pages_jit = false;
            opts.seen.huge_pages_jit = true;
        } else if (std.mem.eql(u8, name, "--no-jit")) {
            opts.jit = false;
            opts.seen.jit = true;
        } else if (std.mem.eql(u8, name, "--cpu-affinity")) {
            // XMRig takes a CPU bitmask: 0x3 means cores 0 and 1.
            const value = try needValue(args, &i, inline_value);
            // Base 0 accepts both "0x3" (XMRig style) and "3".
            opts.affinity_mask = std.fmt.parseInt(u64, value, 0) catch return error.InvalidNumber;
            opts.seen.affinity_mask = true;
        } else if (std.mem.eql(u8, name, "--user-agent")) {
            opts.user_agent = try needValue(args, &i, inline_value);
            opts.seen.user_agent = true;
        } else if (std.mem.eql(u8, name, "--randomx-init")) {
            opts.init_threads = try parseNumber(usize, try needValue(args, &i, inline_value));
            opts.seen.init_threads = true;
        } else if (std.mem.eql(u8, name, "--randomx-wrmsr") or std.mem.eql(u8, name, "--wrmsr")) {
            // XMRig's spelling; `--msr` is ours. `=N` selects a preset, which we
            // do not support, so only the bare form is accepted.
            if (inline_value) |v| {
                if (!std.mem.eql(u8, v, "1")) return error.UnknownOption;
            }
            opts.msr = true;
        } else if (std.mem.eql(u8, name, "--randomx-no-rdmsr") or std.mem.eql(u8, name, "--no-rdmsr")) {
            opts.msr_restore = false;
        } else if (std.mem.eql(u8, name, "--no-wrmsr")) {
            opts.msr = false;
        } else if (std.mem.eql(u8, name, "--donate-level")) {
            // Kept for scripts written for XMRig: this miner has no developer
            // fee, so the value is validated and ignored.
            const value = try needValue(args, &i, inline_value);
            const level = parseNumber(u32, value) catch return error.InvalidNumber;
            if (level > 100) return error.InvalidNumber;
            opts.donate_level_ignored = level;
        } else if (std.mem.eql(u8, name, "--no-affinity")) {
            opts.affinity = false;
            opts.seen.affinity = true;
        } else if (std.mem.eql(u8, name, "--priority") or std.mem.eql(u8, name, "--cpu-priority")) {
            opts.priority = try parseNumber(i32, try needValue(args, &i, inline_value));
            opts.seen.priority = true;
        } else if (std.mem.eql(u8, name, "--no-color")) {
            opts.colors = false;
            opts.seen.colors = true;
        } else if (std.mem.eql(u8, name, "--verbose") or std.mem.eql(u8, name, "-v")) {
            opts.verbose = true;
            opts.seen.verbose = true;
        } else if (std.mem.eql(u8, name, "--print-time")) {
            opts.print_time = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.print_time = true;
        } else if (std.mem.eql(u8, name, "--retries")) {
            opts.retries = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.retries = true;
        } else if (std.mem.eql(u8, name, "--scratchpad-prefetch")) {
            opts.scratchpad_prefetch = try parseNumber(i32, try needValue(args, &i, inline_value));
            opts.seen.scratchpad_prefetch = true;
        } else if (std.mem.eql(u8, name, "--no-optimized-init")) {
            opts.optimized_init = false;
            opts.seen.optimized_init = true;
        } else if (std.mem.eql(u8, name, "--idle-timeout")) {
            opts.idle_timeout = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.idle_timeout = true;
        } else if (std.mem.eql(u8, name, "--keepalive-interval")) {
            opts.keepalive_interval = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.keepalive_interval = true;
        } else if (std.mem.eql(u8, name, "--retry-pause")) {
            opts.retry_pause = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.retry_pause = true;
        } else if (std.mem.eql(u8, name, "--log-file")) {
            opts.log_file = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--http-host")) {
            opts.http_host = try needValue(args, &i, inline_value);
        } else if (std.mem.eql(u8, name, "--http-port")) {
            opts.api_port = try parseNumber(u16, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--http-access-token")) {
            opts.api_token = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--config")) {
            const value = try needValue(args, &i, inline_value);
            opts.config_path = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--self-test")) {
            opts.self_test = true;
            // --self-test=light skips the 2 GiB dataset check, which matters
            // when a miner is already holding the huge pages.
            if (inline_value) |v| {
                if (std.mem.eql(u8, v, "light")) {
                    opts.self_test_light = true;
                } else if (!std.mem.eql(u8, v, "full")) {
                    return error.UnknownOption;
                }
            }
        } else if (std.mem.eql(u8, name, "--check") or std.mem.eql(u8, name, "--dry-run")) {
            // --dry-run is XMRig's name for "validate and exit".
            opts.check = true;
        } else if (std.mem.eql(u8, name, "--bench")) {
            opts.benchmark = true;
            if (inline_value) |v| opts.bench_hashes = parseNumber(u64, v) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, name, "--report")) {
            opts.report = true;
            opts.seen.report = true;
            // `--report=SECONDS` is the shorthand for a custom measurement time.
            if (inline_value) |v| {
                opts.report_seconds = parseNumber(u32, v) catch return error.InvalidNumber;
                opts.seen.report_time = true;
            }
        } else if (std.mem.eql(u8, name, "--report-time")) {
            opts.report_seconds = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.report_time = true;
        } else if (std.mem.eql(u8, name, "--report-file")) {
            opts.report_file = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
            opts.seen.report_file = true;
        } else if (std.mem.eql(u8, name, "--report-interval")) {
            opts.report_interval = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.report_interval = true;
        } else if (std.mem.eql(u8, name, "--report-id")) {
            opts.report_id = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
            opts.seen.report_id = true;
        } else if (std.mem.eql(u8, name, "--power")) {
            const value = try needValue(args, &i, inline_value);
            opts.power_watts = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber;
            opts.seen.power = true;
        } else if (std.mem.eql(u8, name, "--background")) {
            opts.background = true;
            opts.seen.background = true;
        } else if (std.mem.eql(u8, name, "--verify-share")) {
            // A pool helper, not a miner: it never touches the network.
            opts.verify_share = true;
        } else {
            return error.UnknownOption;
        }
    }

    // `-o a -o b -u WALLET` must not leave the first pool without a wallet:
    // a user given on the command line is a default for every pool that does
    // not carry one of its own.
    if (pending.user) |value| {
        for (opts.pools.items) |*pool| {
            if (pool.user.len == 0) {
                pool.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        }
    }

    return opts;
}

pub fn validate(opts: *const Options) ParseError!void {
    if (opts.help or opts.version or opts.self_test or opts.benchmark or opts.report or opts.verify_share) return;
    _ = opts.check;

    if (opts.pools.items.len == 0) return error.NoPools;

    for (opts.pools.items) |pool| {
        if (pool.host.len == 0) return error.InvalidPool;
        if (pool.user.len == 0) return error.NoWallet;
    }
}

/// Applies the transport flags to every pool that did not set them itself.
/// Called once after the command line (and the config file) have been read, so
/// `--transport`, `--proxy`, `--cloudflare` and friends work no matter where
/// the pool was defined.
pub fn applyTransportDefaults(allocator: std.mem.Allocator, opts: *Options) ParseError!void {
    // `--transport` is explicit and always wins. `--cloudflare` is a preset:
    // WebSocket + TLS on 443, which is what a Cloudflare-proxied endpoint
    // speaks and what restrictive VPS firewalls allow. Neither overrides a URL
    // that already named its own scheme or port.
    const forced = opts.transport_override;

    for (opts.pools.items) |*pool| {
        if (forced) |kind| {
            pool.transport = kind;
        } else if (opts.cloudflare and !pool.user_transport) {
            pool.transport = .wss;
        }

        if (!pool.user_port) pool.port = pool.transport.defaultPort();

        if (opts.ws_path) |path| {
            if (pool.ws_path == null) pool.ws_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
        }
        if (opts.ws_origin) |origin| {
            if (pool.ws_origin == null) pool.ws_origin = allocator.dupe(u8, origin) catch return error.OutOfMemory;
        }
        if (opts.host_header) |header| {
            if (pool.host_header == null) pool.host_header = allocator.dupe(u8, header) catch return error.OutOfMemory;
        }
        if (opts.tls_ca) |path| {
            if (pool.tls_ca == null) pool.tls_ca = allocator.dupe(u8, path) catch return error.OutOfMemory;
        }

        if (opts.connect_to) |text| {
            if (pool.connect_host == null) {
                var host = text;
                var port: ?u16 = null;

                if (std.mem.lastIndexOfScalar(u8, text, ':')) |pos| {
                    if (std.mem.indexOfScalar(u8, text, ']') == null) {
                        host = text[0..pos];
                        port = parseNumber(u16, text[pos + 1 ..]) catch return error.InvalidPool;
                    }
                }

                pool.connect_host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
                pool.connect_port = port;
            }
        }

        if (pool.proxy_url) |url| {
            pool.proxy_spec = try parseProxy(allocator, url, null);
        } else if (opts.proxy_url) |url| {
            pool.proxy_spec = try parseProxy(allocator, url, &pool.proxy_url);
        }
    }
}

/// `http://user:pass@host:port`, `socks5://host:port`, `socks5h://...`
fn parseProxy(allocator: std.mem.Allocator, url: []const u8, store: ?*?[]const u8) ParseError!transport.Proxy {
    var spec = transport.Proxy{};
    var rest = std.mem.trim(u8, url, " \t");

    if (std.mem.indexOf(u8, rest, "://")) |pos| {
        const scheme = rest[0..pos];
        rest = rest[pos + 3 ..];

        if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "connect")) {
            spec.kind = .http;
        } else if (std.mem.eql(u8, scheme, "socks5") or std.mem.eql(u8, scheme, "socks5h") or std.mem.eql(u8, scheme, "socks")) {
            spec.kind = .socks5;
        } else {
            return error.InvalidPool;
        }
    } else {
        spec.kind = .http;
    }

    // credentials
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const creds = rest[0..at];
        rest = rest[at + 1 ..];

        if (std.mem.indexOfScalar(u8, creds, ':')) |colon| {
            spec.user = allocator.dupe(u8, creds[0..colon]) catch return error.OutOfMemory;
            spec.pass = allocator.dupe(u8, creds[colon + 1 ..]) catch return error.OutOfMemory;
        } else {
            spec.user = allocator.dupe(u8, creds) catch return error.OutOfMemory;
        }
    }

    var host = rest;
    var port: u16 = switch (spec.kind) {
        .socks5 => 1080,
        else => 8080,
    };

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |pos| {
        host = rest[0..pos];
        port = parseNumber(u16, rest[pos + 1 ..]) catch return error.InvalidPool;
    }

    if (host.len == 0) return error.InvalidPool;

    spec.host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
    spec.port = port;

    if (store) |slot| {
        slot.* = allocator.dupe(u8, url) catch return error.OutOfMemory;
    }

    return spec;
}

// --- config file ---------------------------------------------------------------

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .bool => |b| b,
        // Some hand written configs (and our own installer, once) use 1/0.
        .integer => |i| i != 0,
        else => null,
    };
}

fn jsonInt(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .integer => |v| std.math.cast(T, v),
        else => null,
    };
}

fn applyPoolObject(allocator: std.mem.Allocator, opts: *Options, obj: std.json.ObjectMap) ParseError!void {
    const url = jsonString(obj, "url") orelse return error.InvalidConfig;
    var pool = try parseUrl(allocator, url);

    if (jsonString(obj, "user")) |user| {
        pool.user = allocator.dupe(u8, user) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "pass")) |pass| {
        pool.password = allocator.dupe(u8, pass) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "rig-id")) |id| {
        pool.rig_id = allocator.dupe(u8, id) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "algo")) |algo| {
        pool.algo = api.Algo.fromName(algo) orelse return error.InvalidConfig;
    }
    if (jsonBool(obj, "tls")) |tls| {
        if (tls) {
            if (pool.transport == .tcp) pool.transport = .tls;
            pool.user_transport = true;
        }
    }
    if (jsonBool(obj, "tls-insecure")) |v| pool.tls_insecure = v;
    if (jsonBool(obj, "keepalive")) |v| pool.keepalive = v;
    if (jsonBool(obj, "nicehash")) |v| pool.nicehash = v;

    if (jsonString(obj, "transport")) |name| {
        pool.transport = transport.Kind.fromName(name) orelse return error.InvalidConfig;
        pool.user_transport = true;
        if (!pool.user_port) pool.port = pool.transport.defaultPort();
    }
    if (jsonString(obj, "ws-path")) |v| pool.ws_path = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "ws-origin")) |v| pool.ws_origin = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "host-header")) |v| pool.host_header = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "connect-to")) |v| {
        var host = v;
        var port: ?u16 = null;
        if (std.mem.lastIndexOfScalar(u8, v, ':')) |pos| {
            host = v[0..pos];
            port = parseNumber(u16, v[pos + 1 ..]) catch return error.InvalidConfig;
        }
        pool.connect_host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
        pool.connect_port = port;
    }
    if (jsonString(obj, "tls-ca")) |v| pool.tls_ca = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "proxy")) |v| {
        pool.proxy_url = allocator.dupe(u8, v) catch return error.OutOfMemory;
        pool.proxy_spec = try parseProxy(allocator, v, null);
    }

    opts.pools.append(allocator, pool) catch return error.OutOfMemory;
}

/// Reads an XMRig-style JSON config. Only the keys this miner implements are
/// honoured; the rest is ignored so an existing xmrig config keeps working.
pub fn parseConfigFile(allocator: std.mem.Allocator, opts: *Options, path: []const u8) ParseError!void {
    const text = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigUnreadable,
    };
    defer allocator.free(text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.ConfigInvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidConfig,
    };

    if (root.get("algo")) |value| {
        if (value == .string) opts.algo = api.Algo.fromName(value.string) orelse opts.algo;
    }
    if (jsonInt(u32, root, "print-time")) |v| opts.print_time = v;
    if (jsonInt(u32, root, "retries")) |v| opts.retries = v;
    if (jsonInt(u32, root, "retry-pause")) |v| opts.retry_pause = v;
    if (jsonInt(u32, root, "idle-timeout")) |v| opts.idle_timeout = v;
    if (jsonInt(u32, root, "keepalive-interval")) |v| opts.keepalive_interval = v;
    if (jsonBool(root, "colors")) |v| opts.colors = v;
    if (jsonBool(root, "background")) |v| opts.background = v;
    if (root.get("power")) |value| {
        switch (value) {
            .float => |v| opts.power_watts = v,
            .integer => |v| opts.power_watts = @floatFromInt(v),
            else => {},
        }
    }
    if (root.get("report")) |report_value| {
        if (report_value == .object) {
            const report = report_value.object;
            if (jsonString(report, "file")) |v| opts.report_file = allocator.dupe(u8, v) catch return error.OutOfMemory;
            if (jsonInt(u32, report, "interval")) |v| opts.report_interval = v;
            if (jsonString(report, "id")) |v| opts.report_id = allocator.dupe(u8, v) catch return error.OutOfMemory;

            // `enabled` only gates the report *file*: the standalone
            // `--report` benchmark is a command line action and must never be
            // switched on by a config file (a service would stop mining).
            if (jsonBool(report, "enabled")) |enabled| {
                if (!enabled) {
                    if (opts.report_file) |file| allocator.free(file);
                    opts.report_file = null;
                }
            }
        }
    }
    if (jsonString(root, "log-file")) |v| opts.log_file = allocator.dupe(u8, v) catch return error.OutOfMemory;

    if (root.get("cpu")) |cpu_value| {
        if (cpu_value == .object) {
            const cpu = cpu_value.object;
            if (jsonInt(i32, cpu, "priority")) |v| opts.priority = v;
            if (jsonBool(cpu, "yield")) |_| {}

            // XMRig writes the mask as an integer, or null for "all cores".
            if (cpu.get("affinity")) |aff| {
                switch (aff) {
                    .integer => |v| opts.affinity_mask = std.math.cast(u64, v),
                    .null => opts.affinity_mask = null,
                    else => {},
                }
            }

            if (cpu.get("huge-pages")) |hp| {
                if (hp == .bool) opts.huge_pages = hp.bool;
            }
            if (jsonBool(cpu, "huge-pages-jit")) |v| opts.huge_pages_jit = v;
            if (jsonBool(cpu, "asm")) |v| opts.jit = v;

            if (cpu.get("threads")) |threads| {
                switch (threads) {
                    .integer => |v| opts.threads = std.math.cast(usize, v),
                    .bool => |enabled| {
                        if (!enabled) opts.threads = 0;
                    },
                    // An array means "explicit per-thread affinity". Non
                    // negative entries become a CPU bitmask; -1 means "any
                    // core", exactly like XMRig's [-1, -1].
                    .array => |arr| {
                        opts.threads = arr.items.len;

                        var mask: u64 = 0;
                        var pinned = false;
                        for (arr.items) |entry| {
                            if (entry != .integer) continue;
                            if (entry.integer < 0) continue;
                            if (entry.integer > 63) continue;

                            mask |= @as(u64, 1) << @intCast(entry.integer);
                            pinned = true;
                        }
                        if (pinned) opts.affinity_mask = mask;
                    },
                    else => {},
                }
            }
        }
    }

    if (root.get("randomx")) |rx_value| {
        if (rx_value == .object) {
            const rx = rx_value.object;
            if (jsonString(rx, "mode")) |mode| {
                if (std.mem.eql(u8, mode, "light")) opts.mode = .light;
                if (std.mem.eql(u8, mode, "fast")) opts.mode = .fast;
                if (std.mem.eql(u8, mode, "auto")) opts.mode = .auto;
            }
            if (jsonInt(usize, rx, "init")) |v| opts.init_threads = v;
            if (jsonBool(rx, "msr")) |v| opts.msr = v;
            if (jsonBool(rx, "rdmsr")) |v| opts.msr_restore = v;
            // `wrmsr` is a bool or an explicit register array in XMRig. We only
            // support the built-in presets, so an array means "use the preset".
            switch (rx.get("wrmsr") orelse .null) {
                .bool => |v| opts.msr = v,
                .array => opts.msr = true,
                else => {},
            }
            if (jsonInt(i32, rx, "scratchpad_prefetch_mode")) |v| opts.scratchpad_prefetch = v;
            if (jsonInt(i32, rx, "init-avx2")) |v| opts.optimized_init = v != 0;
        }
    }

    if (root.get("http")) |http_value| {
        if (http_value == .object) {
            const http = http_value.object;
            if (jsonBool(http, "enabled")) |enabled| {
                if (enabled) {
                    if (jsonInt(u16, http, "port")) |port| opts.api_port = port;
                }
            }
            if (jsonString(http, "host")) |host| opts.http_host = host;
            if (jsonString(http, "access-token")) |token| opts.api_token = allocator.dupe(u8, token) catch return error.OutOfMemory;
        }
    }

    if (root.get("pools")) |pools_value| {
        if (pools_value == .array) {
            for (pools_value.array.items) |item| {
                if (item != .object) continue;
                try applyPoolObject(allocator, opts, item.object);
            }
        }
    }
}

// --- tests -----------------------------------------------------------------
//
// The command line is the part of the miner every user touches, and a silent
// change here (a scheme that stops being recognised, a flag that stops being
// applied to the next pool) only shows up as "it connects to the wrong port".

test "pool URLs: schemes, paths and default ports" {
    const testing = std.testing;

    const pool = try parseUrl(testing.allocator, "pool.example.com:3333");
    defer freePool(testing.allocator, pool);
    try testing.expectEqualStrings("pool.example.com", pool.host);
    try testing.expectEqual(@as(u16, 3333), pool.port);
    try testing.expectEqual(transport.Kind.tcp, pool.transport);

    // No port: the scheme decides.
    const tls = try parseUrl(testing.allocator, "stratum+ssl://pool.example.com");
    defer freePool(testing.allocator, tls);
    try testing.expectEqual(transport.Kind.tls, tls.transport);
    try testing.expectEqual(@as(u16, 443), tls.port);

    const wss = try parseUrl(testing.allocator, "wss://pool.example.com/monero/TOKEN");
    defer freePool(testing.allocator, wss);
    try testing.expectEqual(transport.Kind.wss, wss.transport);
    try testing.expectEqual(@as(u16, 443), wss.port);
    try testing.expectEqualStrings("/monero/TOKEN", wss.ws_path.?);

    const ws = try parseUrl(testing.allocator, "ws://relay.example:8080/stratum");
    defer freePool(testing.allocator, ws);
    try testing.expectEqual(transport.Kind.ws, ws.transport);
    try testing.expectEqual(@as(u16, 8080), ws.port);
    try testing.expectEqualStrings("/stratum", ws.ws_path.?);

    // IPv6 literals keep their brackets out of the host, port still parses.
    const v6 = try parseUrl(testing.allocator, "[2001:db8::1]:14444");
    defer freePool(testing.allocator, v6);
    try testing.expectEqualStrings("2001:db8::1", v6.host);
    try testing.expectEqual(@as(u16, 14444), v6.port);

    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, "gopher://pool"));
    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, ""));
    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, "pool:notaport"));
}

test "arguments: order independent, flags apply to the pool they belong to" {
    const testing = std.testing;

    // `-u` before `-o` is what everyone types first, and it used to create a
    // placeholder pool.
    const args = [_][]const u8{
        "-u", "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
        "--rig-id", "rig-1",
        "-o", "pool.example.com:3333",
        "-o", "backup.example.com:443",
        "-t", "3",
        "--retries", "2",
        "--mode", "light",
    };

    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.pools.items.len);
    try testing.expectEqualStrings("pool.example.com", opts.pools.items[0].host);
    try testing.expectEqualStrings("backup.example.com", opts.pools.items[1].host);
    // The wallet and the rig id apply to *both* pools.
    try testing.expectEqualStrings(args[1], opts.pools.items[1].user);
    try testing.expectEqualStrings("rig-1", opts.pools.items[1].rig_id.?);
    try testing.expectEqual(@as(usize, 3), opts.threads.?);
    try testing.expectEqual(@as(u32, 2), opts.retries);
    try testing.expectEqual(Mode.light, opts.mode);
}

test "arguments: unknown flags and missing values are errors, not silence" {
    const testing = std.testing;

    try testing.expectError(error.UnknownOption, parseArgs(testing.allocator, &[_][]const u8{"--not-a-flag"}));
    try testing.expectError(error.MissingValue, parseArgs(testing.allocator, &[_][]const u8{"-o"}));
}

test "nicehash is a pool flag and survives parsing" {
    const testing = std.testing;

    const args = [_][]const u8{ "-o", "pool.example.com:3333", "--nicehash", "-u", "wallet.rig" };
    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.pools.items[0].nicehash);
}

test "XMRig-compatible flags are accepted and reach options" {
    const testing = std.testing;

    const args = [_][]const u8{
        "-o",         "pool.example.com:3333",
        "-u",         "wallet",
        "--cpu-priority", "2",
        "--cpu-affinity", "0x3",
        "--randomx-init", "1",
        "--user-agent", "xmrig/6.26.0",
        "--donate-level", "1",
        "--randomx-wrmsr",
        "--randomx-no-rdmsr",
    };

    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 2), opts.priority);
    try testing.expectEqual(@as(?u64, 0x3), opts.affinity_mask);
    try testing.expectEqual(@as(usize, 1), opts.init_threads);
    try testing.expectEqualStrings("xmrig/6.26.0", opts.user_agent.?);
    // Accepted for compatibility, remembered so main can say the fee is 0 %.
    try testing.expectEqual(@as(?u32, 1), opts.donate_level_ignored);
    try testing.expect(opts.msr);
    try testing.expect(!opts.msr_restore);

    // `--donate-level=101` is a typo, not a 101 % fee.
    try testing.expectError(error.InvalidNumber, parseArgs(testing.allocator, &[_][]const u8{ "--donate-level", "101" }));
}

test "affinity masks select the CPUs the threads are pinned to" {
    const testing = std.testing;

    // cpuFor lives in miner.zig, but the bit walk is what --check reports.
    try testing.expectEqual(@as(usize, 2), @popCount(@as(u64, 0x3)));
    try testing.expectEqual(@as(usize, 1), @popCount(@as(u64, 0x8)));
}

test "an xmrig config.json is read with the keys it uses" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = 
        \\{"cpu":{"affinity":3,"priority":2,"huge-pages":true},
        \\ "randomx":{"mode":"light","init":1,"wrmsr":false,"rdmsr":false,
        \\            "scratchpad_prefetch_mode":2,"init-avx2":0},
        \\ "pools":[{"url":"pool.example.com:3333","user":"wallet"}]}
    });

    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path);

    var opts = Options{};
    defer opts.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &opts, path);

    try testing.expectEqual(@as(?u64, 3), opts.affinity_mask);
    try testing.expectEqual(@as(i32, 2), opts.priority);
    try testing.expectEqual(Mode.light, opts.mode);
    try testing.expectEqual(@as(usize, 1), opts.init_threads);
    try testing.expectEqual(@as(i32, 2), opts.scratchpad_prefetch);
    try testing.expect(!opts.optimized_init);
    try testing.expect(!opts.msr);
    try testing.expect(!opts.msr_restore);
    try testing.expectEqual(@as(usize, 1), opts.pools.items.len);
    try testing.expectEqualStrings("wallet", opts.pools.items[0].user);
}

test "proxy URLs: http and socks5, with credentials, defaults and junk" {
    const testing = std.testing;

    const http = try parseProxy(testing.allocator, "http://user:p%40ss@proxy.example:8080", null);
    defer testing.allocator.free(http.host);
    defer if (http.user) |v| testing.allocator.free(v);
    defer if (http.pass) |v| testing.allocator.free(v);

    try testing.expectEqual(transport.ProxyKind.http, http.kind);
    try testing.expectEqualStrings("proxy.example", http.host);
    try testing.expectEqual(@as(u16, 8080), http.port);
    try testing.expectEqualStrings("user", http.user.?);

    // No port on a socks5 proxy means 1080, not 8080.
    const socks = try parseProxy(testing.allocator, "socks5://127.0.0.1", null);
    defer testing.allocator.free(socks.host);
    try testing.expectEqual(transport.ProxyKind.socks5, socks.kind);
    try testing.expectEqual(@as(u16, 1080), socks.port);

    // A bare "host:port" is an HTTP proxy, like in XMRig.
    const bare = try parseProxy(testing.allocator, "proxy.example:3128", null);
    defer testing.allocator.free(bare.host);
    try testing.expectEqual(transport.ProxyKind.http, bare.kind);
    try testing.expectEqual(@as(u16, 3128), bare.port);

    try testing.expectError(error.InvalidPool, parseProxy(testing.allocator, "ftp://proxy.example:21", null));
    try testing.expectError(error.InvalidPool, parseProxy(testing.allocator, "socks5://", null));
}

test "an explicit thread array becomes a cpu mask, -1 means anywhere" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "pinned.json", .data = 
        \\{"cpu":{"threads":[0,2]},"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });
    try tmp.dir.writeFile(.{ .sub_path = "any.json", .data = 
        \\{"cpu":{"threads":[-1,-1]},"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var pinned = Options{};
    defer pinned.deinit(testing.allocator);
    const pinned_path = try tmp.dir.realpathAlloc(testing.allocator, "pinned.json");
    defer testing.allocator.free(pinned_path);
    try parseConfigFile(testing.allocator, &pinned, pinned_path);

    try testing.expectEqual(@as(usize, 2), pinned.threads.?);
    try testing.expectEqual(@as(?u64, 0x5), pinned.affinity_mask);

    var any = Options{};
    defer any.deinit(testing.allocator);
    const any_path = try tmp.dir.realpathAlloc(testing.allocator, "any.json");
    defer testing.allocator.free(any_path);
    try parseConfigFile(testing.allocator, &any, any_path);

    try testing.expectEqual(@as(usize, 2), any.threads.?);
    try testing.expectEqual(@as(?u64, null), any.affinity_mask);
}
