// Flags, defaults and validation.
//
// Two rules shape this file:
//
//   1. every feature is one flag, spelled the way someone would guess
//      (`--tunnel=tailscale`, not `--enable-tunnel --tunnel-type tailscale`),
//   2. the defaults are the safe and *fast* ones: bind to localhost, port 3333,
//      no tunnel, and a difficulty that forwards every share.
//
// A wrong flag is refused with the reason, never silently ignored: a proxy that
// starts while ignoring `--token` is a proxy that will be found by a scanner.

'use strict';

const os = require('node:os');

const VERSION = '1.0.0';

const DEFAULTS = {
  bind: '127.0.0.1',
  port: 3333,
  wsPort: null,          // `--ws` picks port+1 when this is null
  wsPath: '/stratum',
  tlsPort: null,
  statusPort: 3334,
  statusBind: '127.0.0.1',
  allow: [],             // CIDR list; empty means "loopback and RFC1918 only"
  token: '',
  localFactor: 1,
  targetShare: 15,
  forwardWorkers: true,
  keepAliveMs: 60_000,
  retryPauseMs: 5000,
  maxRigs: 255,
  logLevel: 'info',
  tunnel: 'none',
  tunnelToken: '',
  tunnelHost: '',
  tunnelPort: 0,
  pool: [],
  user: '',
  password: 'x',
  agent: `zmrig-proxy/${VERSION}`,
  // Algorithms the proxy tells the pool it can serve. `auto` is the RandomX
  // family, which every miner behind this proxy implements; a pin (`--algo=rx/0`)
  // is for a farm that must stay on one coin.
  algo: 'auto',
  algos: [],
  verify: false,
  rigs: 1,          // `tunnel wireguard --rigs=<n>`
  dir: '',         // where tunnel files are written
  // Network figures used for the `XMR/day` column in /status. Both are
  // optional: without them the proxy still reports hashrate and shares/hour,
  // and says "unknown" instead of inventing a number.
  networkDifficulty: 0,
  networkUrl: '',
  networkIntervalMs: 600_000,
  blockReward: 0.6,   // Monero tail emission, XMR per block
};

const TUNNELS = ['none', 'wireguard', 'tailscale', 'cf', 'cf-quick'];
const LOG_LEVELS = ['debug', 'info', 'warn', 'error', 'silent'];

class ConfigError extends Error {}

/** Field name -> the canonical spelling, so `--wsPort` and `--ws-port` are the
 *  same flag. Operators type both. */
const ALIASES = {
  'ws-port': 'wsPort',
  'ws-path': 'wsPath',
  'tls-port': 'tlsPort',
  'status-port': 'statusPort',
  'status-bind': 'statusBind',
  'local-difficulty': 'localFactor',
  'target-share': 'targetShare',
  'forward-workers': 'forwardWorkers',
  'keepalive': 'keepAliveMs',
  'retry-pause': 'retryPauseMs',
  'max-rigs': 'maxRigs',
  'log-level': 'logLevel',
  'tunnel-token': 'tunnelToken',
  'tunnel-host': 'tunnelHost',
  'tunnel-port': 'tunnelPort',
  'tls-cert': 'tlsCert',
  'tls-key': 'tlsKey',
  'tunnel-dir': 'dir',
  'network-difficulty': 'networkDifficulty',
  'network-url': 'networkUrl',
  'network-interval': 'networkIntervalMs',
  'block-reward': 'blockReward',
};

const BOOLEAN_FLAGS = new Set([
  'ws', 'wss', 'tls', 'help', 'version', 'no-workers', 'quiet', 'verbose', 'verify', 'json',
]);

function parseArgs(argv) {
  const flags = {};
  const positional = [];

  for (const argument of argv) {
    if (!argument.startsWith('--')) {
      positional.push(argument);
      continue;
    }

    const body = argument.slice(2);
    const eq = body.indexOf('=');

    if (eq === -1) {
      flags[body] = true;
      continue;
    }

    flags[body.slice(0, eq)] = body.slice(eq + 1);
  }

  // Booleans were stored as `true`; everything else must be a string, so
  // `--port 3333` (two tokens) is reported as the mistake it is instead of
  // becoming a pool named "3333".
  for (const key of Object.keys(flags)) {
    if (flags[key] === true && !BOOLEAN_FLAGS.has(key)) {
      throw new ConfigError(`--${key} needs a value: use --${key}=<value>`);
    }
  }

  return { flags, positional };
}

function build(argv = [], env = process.env) {
  const { flags, positional } = parseArgs(argv);
  const config = { ...DEFAULTS, allow: [], pool: [] };

  if (flags.help) return { help: true, config, positional };
  if (flags.version) return { version: true, config, positional };

  const value = (name) => {
    const key = ALIASES[name] || name;

    return flags[name] !== undefined ? flags[name] : flags[key];
  };

  if (value('user')) config.user = String(value('user')).trim();
  if (value('password')) config.password = String(value('password'));
  if (value('bind')) config.bind = String(value('bind')).trim();
  if (value('allow')) config.allow = String(value('allow')).split(',').map((s) => s.trim()).filter(Boolean);
  if (value('token')) config.token = String(value('token')).trim();
  if (value('log-level')) config.logLevel = String(value('log-level')).trim();
  if (flags.quiet) config.logLevel = 'warn';
  if (flags.verbose) config.logLevel = 'debug';
  if (flags['no-workers']) config.forwardWorkers = false;
  if (flags.verify) config.verify = true;
  if (value('algo')) config.algo = String(value('algo')).trim();
  config.rigs = number(value('rigs'), 'rigs', config.rigs, 1, 250);
  if (value('dir')) config.dir = String(value('dir'));
  if (value('tunnel-dir')) config.dir = String(value('tunnel-dir'));

  config.port = number(value('port'), 'port', config.port, 1, 65535);
  config.statusPort = number(value('status-port'), 'status-port', config.statusPort, 1, 65535);
  config.statusBind = String(value('status-bind') || config.statusBind);
  config.targetShare = number(value('target-share'), 'target-share', config.targetShare, 2, 3600);
  config.localFactor = number(value('local-difficulty'), 'local-difficulty', config.localFactor, 0.125, 8);
  config.maxRigs = number(value('max-rigs'), 'max-rigs', config.maxRigs, 1, 255);
  config.keepAliveMs = number(value('keepalive'), 'keepalive', config.keepAliveMs, 10_000, 600_000);
  config.retryPauseMs = number(value('retry-pause'), 'retry-pause', config.retryPauseMs, 100, 60_000);
  config.networkDifficulty = number(value('network-difficulty'), 'network-difficulty', config.networkDifficulty, 1, 1e16);
  config.networkUrl = String(value('network-url') || env.OCEAN_PROXY_NETWORK_URL || '').trim();
  // Seconds on the command line (`--network-interval=600`), milliseconds in
  // the object: nobody types 600000 by hand, and a 10 ms poll would hammer a
  // public API.
  config.networkIntervalMs = number(value('network-interval'), 'network-interval', config.networkIntervalMs / 1000, 60, 6 * 3600) * 1000;
  config.blockReward = number(value('block-reward'), 'block-reward', config.blockReward, 0.0001, 100);

  if (value('pool')) {
    config.pool = String(value('pool')).split(',').map((s) => s.trim()).filter(Boolean);
  }

  // Environment fallbacks: a service file with a secret in it is a secret in
  // `git status` if someone commits the wrong directory.
  if (!config.user && env.OCEAN_PROXY_USER) config.user = env.OCEAN_PROXY_USER;
  if (!config.pool.length && env.OCEAN_PROXY_POOL) config.pool = String(env.OCEAN_PROXY_POOL).split(',').map((s) => s.trim()).filter(Boolean);
  if (!config.token && env.OCEAN_PROXY_TOKEN) config.token = env.OCEAN_PROXY_TOKEN;
  if (!config.tunnelToken && env.OCEAN_PROXY_TUNNEL_TOKEN) config.tunnelToken = env.OCEAN_PROXY_TUNNEL_TOKEN;

  // TLS: a cert without a key (or the reverse) is a half-configured listener.
  config.tlsCert = value('tls-cert') || env.OCEAN_PROXY_TLS_CERT || '';
  config.tlsKey = value('tls-key') || env.OCEAN_PROXY_TLS_KEY || '';
  if (Boolean(flags.tls || flags.wss) && !(config.tlsCert && config.tlsKey)) {
    throw new ConfigError('--tls and --wss need --tls-cert=<file> and --tls-key=<file>');
  }
  config.tls = Boolean(flags.tls);
  config.ws = Boolean(flags.ws || flags.wss);
  config.wss = Boolean(flags.wss);
  config.tlsPort = flags['tls-port'] ? number(value('tls-port'), 'tls-port', config.port + 2, 1, 65535) : config.port + 2;
  config.wsPort = flags['ws-port'] ? number(value('ws-port'), 'ws-port', config.port + 1, 1, 65535) : config.port + 1;

  if (value('tunnel')) config.tunnel = String(value('tunnel')).trim();
  if (!TUNNELS.includes(config.tunnel)) {
    throw new ConfigError(`--tunnel=${config.tunnel} is not one of ${TUNNELS.join('|')}`);
  }
  if (value('tunnel-token')) config.tunnelToken = String(value('tunnel-token')).trim();
  if (value('tunnel-host')) config.tunnelHost = String(value('tunnel-host')).trim();
  if (value('tunnel-port')) config.tunnelPort = number(value('tunnel-port'), 'tunnel-port', 0, 1, 65535);

  // Resolve the algorithm list once, where a typo is still an error the
  // operator sees, instead of at login time on a live farm.
  config.algos = resolveAlgos(config.algo);

  if (!LOG_LEVELS.includes(config.logLevel)) {
    throw new ConfigError(`--log-level=${config.logLevel} is not one of ${LOG_LEVELS.join('|')}`);
  }

  validate(config);

  return { config, positional, help: false };
}

/// The RandomX variants `--algo=auto` advertises, in the order a pool reads
/// them. Mirrors `zmrig/src/api.zig` (`auto_algos`) and the C++ side's named
/// configurations (`src/crypto/rx/RxAlgo.cpp`). `rx/2` is absent on purpose:
/// its parameters differ per pool fork, and advertising a variant the rig cannot
/// reproduce means every share is rejected.
const RANDOMX_FAMILY = ['rx/0', 'rx/wow', 'rx/arq', 'rx/graft', 'rx/sfx', 'rx/yada', 'panthera'];

function resolveAlgos(value) {
  const text = String(value || '').trim();
  if (!text || text.toLowerCase() === 'none') return [];
  if (text.toLowerCase() === 'auto') return [...RANDOMX_FAMILY];

  const names = text.split(',').map((name) => name.trim().toLowerCase()).filter(Boolean);

  for (const name of names) {
    if (!RANDOMX_FAMILY.includes(name)) {
      throw new ConfigError(`--algo=${name} is not one of auto, none, ${RANDOMX_FAMILY.join(', ')}`);
    }
  }

  return names;
}

function validate(config) {
  if (!config.user) {
    // Not fatal: the first rig's wallet is adopted, which is what a
    // single-wallet operator expects. Said out loud once in start(), though.
    config.userFromRig = true;
  } else if (!/^[48][0-9A-Za-z]{94,105}$/.test(config.user.split('.')[0])) {
    // A typo in a 95-character address is invisible and costs every payout.
    throw new ConfigError(`--user does not look like a Monero address: ${config.user.slice(0, 16)}…`);
  }

  if (!config.pool.length) {
    throw new ConfigError('--pool=<host:port> is required (e.g. --pool=gulf.moneroocean.stream:10001 or --pool=127.0.0.1:3333)');
  }

  for (const entry of config.pool) {
    if (!/^(tls|ssl|stratum\+ssl|stratum\+tcp|stratum)?:?\/?\/?[A-Za-z0-9._-]+:\d{1,5}$/.test(entry)) {
      throw new ConfigError(`--pool entry "${entry}" is not host:port (an optional tls:// prefix is allowed)`);
    }
  }

  if (config.bind === '0.0.0.0' && !config.allow.length && !config.token) {
    throw new ConfigError('--bind=0.0.0.0 exposes the proxy to the internet; add --allow=<cidr> or --token=<secret>');
  }

  if (config.tunnel === 'cf' && !config.ws) {
    // Cloudflare carries HTTP/WebSocket, not raw stratum. Saying this now is
    // cheaper than an operator staring at a client that cannot connect.
    throw new ConfigError('--tunnel=cf needs --ws: Cloudflare tunnels carry WebSocket, not raw stratum');
  }

  if (config.tls && config.tlsCert && !saneFiles(config)) {
    throw new ConfigError('--tls-cert or --tls-key is not readable');
  }

  if (config.localFactor < 1 && config.token === '' && config.bind !== '127.0.0.1' && config.bind !== '::1') {
    // A local difficulty below the pool's means shares are accepted and thrown
    // away; on a shared link someone could read that as free credit.
    throw new ConfigError('--local-difficulty<1 with a public --bind needs --token, or every share is absorbed');
  }
}

function number(raw, name, fallback, min, max) {
  if (raw === undefined || raw === null || raw === '') return fallback;

  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new ConfigError(`--${name}=${raw} is out of range (${min}..${max})`);
  }

  return value;
}

/** Binaries a chosen tunnel needs. Kept out of `build()` so parsing flags stays
 *  pure and testable on a machine that has none of them installed; `start` and
 *  `doctor` report the answer instead. */
function missingBinaries(config) {
  const needs = {
    wireguard: { binary: 'wg', hint: 'apt install wireguard-tools' },
    tailscale: { binary: 'tailscale', hint: 'https://tailscale.com/download' },
    cf: { binary: 'cloudflared', hint: 'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/' },
    'cf-quick': { binary: 'cloudflared', hint: 'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/' },
  };

  const need = needs[config.tunnel];
  if (!need) return [];

  return hasBinary(need.binary) ? [] : [{ ...need, tunnel: config.tunnel }];
}

function hasBinary(name) {
  const { execFileSync } = require('node:child_process');

  try {
    execFileSync(name === 'wg' ? 'wg' : name, name === 'wg' ? ['--version'] : ['version'], { stdio: 'ignore', timeout: 3000 });

    return true;
  } catch (_) {
    return false;
  }
}

function saneFiles(config) {
  const fs = require('node:fs');

  try {
    fs.accessSync(config.tlsCert, fs.constants.R_OK);
    fs.accessSync(config.tlsKey, fs.constants.R_OK);

    return true;
  } catch (_) {
    return false;
  }
}

/** The address a rig on the LAN can actually use. `127.0.0.1` is useless to a
 *  second machine, and printing it anyway is how a setup guide becomes wrong. */
function lanAddress() {
  for (const [, list] of Object.entries(os.networkInterfaces())) {
    for (const item of list || []) {
      if (item.family === 'IPv4' && !item.internal && !item.address.startsWith('169.254.')) return item.address;
    }
  }

  return null;
}

module.exports = {
  ALIASES,
  ConfigError,
  DEFAULTS,
  RANDOMX_FAMILY,
  TUNNELS,
  VERSION,
  build,
  hasBinary,
  lanAddress,
  missingBinaries,
  parseArgs,
  resolveAlgos,
};
