//! Command line and config file handling.
//!
//! Flags mirror XMRig's so existing scripts and muscle memory keep working:
//!   zmrig -o pool:port -u WALLET -p x -a rx/0 -t 2 --rig-id rig --keepalive
//! A JSON config file can replace or extend the command line:
//!   zmrig -c /etc/zmrig/config.json

const std = @import("std");
const api = @import("api.zig");

pub const Pool = struct {
    host: []const u8 = "",
    port: u16 = 0,
    tls: bool = false,
    user: []const u8 = "",
    password: []const u8 = "x",
    rig_id: ?[]const u8 = null,
    keepalive: bool = true,
    nicehash: bool = false,
    tls_insecure: bool = false,
    /// Optional per-pool algorithm pin; null means "whatever the pool sends".
    algo: ?api.Algo = null,
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
    version: bool = false,
    help: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        for (self.pools.items) |pool| {
            allocator.free(pool.host);
            allocator.free(pool.user);
            allocator.free(pool.password);
            if (pool.rig_id) |id| allocator.free(id);
        }
        self.pools.deinit(allocator);
        if (self.log_file) |v| allocator.free(v);
        if (self.api_token) |v| allocator.free(v);
        if (self.config_path) |v| allocator.free(v);
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
    \\  -o, --url=URL            pool URL, e.g. pool.example.com:3333 or stratum+tcp://host:port
    \\  -u, --user=USER          wallet address (login)
    \\  -p, --pass=PASS          password / worker name (default: x)
    \\  -a, --algo=ALGO          rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx, rx/yada, panthera
    \\      --rig-id=ID          rig identifier sent to the pool
    \\      --keepalive          send keepalive (default: on)
    \\      --no-keepalive       never send keepalive
    \\      --tls                connect with TLS (stratum+ssl:// also works)
    \\      --tls-insecure       do not verify the pool certificate
    \\      --retries=N          reconnect attempts per pool before failover (default: 5)
    \\      --retry-pause=N      seconds between reconnects (default: 5)
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

    if (std.mem.indexOf(u8, rest, "://")) |pos| {
        const scheme = rest[0..pos];
        rest = rest[pos + 3 ..];

        if (std.mem.eql(u8, scheme, "stratum+ssl") or std.mem.eql(u8, scheme, "stratum+tls") or std.mem.eql(u8, scheme, "tls")) {
            pool.tls = true;
        } else if (!(std.mem.eql(u8, scheme, "stratum+tcp") or std.mem.eql(u8, scheme, "stratum") or std.mem.eql(u8, scheme, "tcp") or std.mem.eql(u8, scheme, "http"))) {
            return error.InvalidPool;
        }
    }

    // Strip any trailing path, e.g. host:port/extra
    if (std.mem.indexOfScalar(u8, rest, '/')) |pos| rest = rest[0..pos];

    var host = rest;
    var port_text: ?[]const u8 = null;

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |pos| {
        // Keep IPv6 literals such as [::1]:3333 working.
        if (!std.mem.startsWith(u8, rest, "[")) {
            host = rest[0..pos];
            port_text = rest[pos + 1 ..];
        }
    } else if (std.mem.startsWith(u8, rest, "[")) {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidPool;
        host = rest[1..end];
        if (end + 1 < rest.len and rest[end + 1] == ':') port_text = rest[end + 2 ..];
    }

    if (host.len == 0) return error.InvalidPool;

    pool.host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
    pool.port = if (port_text) |p| parseNumber(u16, p) catch return error.InvalidPool else if (pool.tls) 443 else 3333;

    return pool;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts = Options{};
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
            const pool = try parseUrl(allocator, value);
            opts.pools.append(allocator, pool) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-u") or std.mem.eql(u8, name, "--user")) {
            const value = try needValue(args, &i, inline_value);
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            const last = &opts.pools.items[opts.pools.items.len - 1];
            if (last.user.len != 0) allocator.free(last.user);
            last.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--pass") or std.mem.eql(u8, name, "--password")) {
            const value = try needValue(args, &i, inline_value);
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            const last = &opts.pools.items[opts.pools.items.len - 1];
            if (!std.mem.eql(u8, last.password, "x")) allocator.free(last.password);
            last.password = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-a") or std.mem.eql(u8, name, "--algo")) {
            const value = try needValue(args, &i, inline_value);
            opts.algo = api.Algo.fromName(value) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, name, "--rig-id")) {
            const value = try needValue(args, &i, inline_value);
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            const last = &opts.pools.items[opts.pools.items.len - 1];
            if (last.rig_id) |id| allocator.free(id);
            last.rig_id = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--keepalive")) {
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            opts.pools.items[opts.pools.items.len - 1].keepalive = true;
        } else if (std.mem.eql(u8, name, "--no-keepalive")) {
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            opts.pools.items[opts.pools.items.len - 1].keepalive = false;
        } else if (std.mem.eql(u8, name, "--nicehash")) {
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            opts.pools.items[opts.pools.items.len - 1].nicehash = true;
        } else if (std.mem.eql(u8, name, "--tls")) {
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            opts.pools.items[opts.pools.items.len - 1].tls = true;
        } else if (std.mem.eql(u8, name, "--tls-insecure")) {
            if (opts.pools.items.len == 0) opts.pools.append(allocator, .{}) catch return error.OutOfMemory;
            opts.pools.items[opts.pools.items.len - 1].tls_insecure = true;
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
    if (jsonBool(obj, "tls")) |tls| pool.tls = tls;
    if (jsonBool(obj, "tls-insecure")) |v| pool.tls_insecure = v;
    if (jsonBool(obj, "keepalive")) |v| pool.keepalive = v;
    if (jsonBool(obj, "nicehash")) |v| pool.nicehash = v;

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
