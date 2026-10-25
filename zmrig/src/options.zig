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
    allocator.free(pool.password);
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

pub const Options = struct {
    pools: std.ArrayListUnmanaged(Pool) = .{},
    algo: ?api.Algo = null,
    threads: ?usize = null,
    mode: Mode = .auto,
    huge_pages: bool = true,
    huge_pages_jit: bool = true,
    jit: bool = true,
    priority: i32 = -1,
    affinity: bool = true,
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
    \\      --no-huge-pages      disable huge pages
    \\      --no-huge-pages-jit  disable huge pages for the JIT code
    \\      --no-jit             disable the JIT compiler (slow, ~6x lower hashrate)
    \\      --no-affinity        do not pin threads to cores
    \\      --priority=N         1..5 (XMRig scale) or a raw nice value like -10
    \\
    \\Logging:
    \\      --no-color           disable colours
    \\      --verbose            verbose output
    \\      --print-time=N       hashrate report interval in seconds (default: 60, 0 = off)
    \\      --log-file=FILE      append the log to FILE
    \\
    \\Other:
    \\  -c, --config=FILE        JSON config file
      \\      --self-test[=light]  verify the hash engine against known vectors and exit
  \\                           (light skips the 2 GiB dataset check)
  \\      --check              validate the configuration and exit
    \\      --bench[=HASHES]     benchmark the hash rate and exit
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
            pending.transport = .tls;
            pending.tls_insecure = true;
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
            } else if (std.mem.eql(u8, value, "fast")) {
                opts.mode = .fast;
            } else if (std.mem.eql(u8, value, "light")) {
                opts.mode = .light;
            } else {
                return error.UnknownOption;
            }
        } else if (std.mem.eql(u8, name, "--no-huge-pages")) {
            opts.huge_pages = false;
        } else if (std.mem.eql(u8, name, "--no-huge-pages-jit")) {
            opts.huge_pages_jit = false;
        } else if (std.mem.eql(u8, name, "--no-jit")) {
            opts.jit = false;
        } else if (std.mem.eql(u8, name, "--no-affinity")) {
            opts.affinity = false;
        } else if (std.mem.eql(u8, name, "--priority")) {
            opts.priority = try parseNumber(i32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--no-color")) {
            opts.colors = false;
        } else if (std.mem.eql(u8, name, "--verbose") or std.mem.eql(u8, name, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, name, "--print-time")) {
            opts.print_time = try parseNumber(u32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--retries")) {
            opts.retries = try parseNumber(u32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--scratchpad-prefetch")) {
            opts.scratchpad_prefetch = try parseNumber(i32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--no-optimized-init")) {
            opts.optimized_init = false;
        } else if (std.mem.eql(u8, name, "--idle-timeout")) {
            opts.idle_timeout = try parseNumber(u32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--keepalive-interval")) {
            opts.keepalive_interval = try parseNumber(u32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--retry-pause")) {
            opts.retry_pause = try parseNumber(u32, try needValue(args, &i, inline_value));
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
        } else if (std.mem.eql(u8, name, "--background")) {
            opts.background = true;
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
    if (opts.help or opts.version or opts.self_test or opts.benchmark) return;
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
    const text = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return error.InvalidConfig;
    defer allocator.free(text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidConfig;
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
    if (jsonString(root, "log-file")) |v| opts.log_file = allocator.dupe(u8, v) catch return error.OutOfMemory;

    if (root.get("cpu")) |cpu_value| {
        if (cpu_value == .object) {
            const cpu = cpu_value.object;
            if (jsonInt(i32, cpu, "priority")) |v| opts.priority = v;
            if (jsonBool(cpu, "yield")) |_| {}

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
                    // An array means "explicit affinity", which we translate to
                    // "one thread per entry".
                    .array => |arr| opts.threads = arr.items.len,
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
