// Flags, access control and generated tunnel config. These are the parts an
// operator touches with their hands, so they are tested the way they use them:
// by typing flags and reading the error.

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { ConfigError, build, parseArgs } = require('../src/config');
const { AccessList, RateLimiter, parseCidr, plainAddress } = require('../src/access');
const { wireguardConfig } = require('../src/tunnel');

const WALLET = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
const POOL = 'gulf.moneroocean.stream:10001';

const base = (extra = []) => ['start', `--user=${WALLET}`, `--pool=${POOL}`, ...extra];

test('the short command works and the defaults are safe', () => {
  const { config } = build(base());

  assert.strictEqual(config.bind, '127.0.0.1', 'the proxy must not listen publicly by default');
  assert.strictEqual(config.port, 3333);
  assert.strictEqual(config.localFactor, 1, 'default forwards every accepted share');
  assert.strictEqual(config.tunnel, 'none');
  assert.deepStrictEqual(config.pool, [POOL]);
});

test('one flag turns on each feature, and the kebab and camel spellings agree', () => {
  const { config } = build(base([
    '--ws',
    '--status-port=4444',
    '--statusPort=4444',
    '--local-difficulty=0.5',
    '--target-share=20',
    '--no-workers',
    '--allow=10.0.0.0/8,192.168.0.0/16',
  ]));

  assert.strictEqual(config.ws, true);
  assert.strictEqual(config.wsPort, 3334);
  assert.strictEqual(config.statusPort, 4444);
  assert.strictEqual(config.localFactor, 0.5);
  assert.strictEqual(config.targetShare, 20);
  assert.strictEqual(config.forwardWorkers, false);
  assert.deepStrictEqual(config.allow, ['10.0.0.0/8', '192.168.0.0/16']);
});

test('a tunnel is chosen with one flag and its token comes from the flag or the environment', () => {
  const { config } = build(base(['--tunnel=cf', '--ws', '--tunnel-token=abc123', '--tunnel-host=proxy.example.com']));
  assert.strictEqual(config.tunnel, 'cf');
  assert.strictEqual(config.tunnelToken, 'abc123');
  assert.strictEqual(config.tunnelHost, 'proxy.example.com');

  const env = build(base(['--tunnel=tailscale']), { OCEAN_PROXY_TUNNEL_TOKEN: 'tskey-xyz' }).config;
  assert.strictEqual(env.tunnelToken, 'tskey-xyz');
});

test('the money column is off by default and switched on with one flag', () => {
  const off = build(base()).config;
  assert.strictEqual(off.networkDifficulty, 0);
  assert.strictEqual(off.networkUrl, '');
  assert.strictEqual(off.blockReward, 0.6, 'Monero tail emission');

  const on = build(base(['--network-difficulty=3.01e11'])).config;
  assert.strictEqual(on.networkDifficulty, 3.01e11);

  const feed = build(base(['--network-url=https://example.com/stats', '--network-interval=120'])).config;
  assert.strictEqual(feed.networkUrl, 'https://example.com/stats');
  assert.strictEqual(feed.networkIntervalMs, 120_000);

  const env = build(base(), { OCEAN_PROXY_NETWORK_URL: 'https://example.com/stats' }).config;
  assert.strictEqual(env.networkUrl, 'https://example.com/stats');

  assert.throws(() => build(base(['--network-difficulty=0'])), ConfigError);
  assert.throws(() => build(base(['--network-interval=5'])), ConfigError);
  assert.throws(() => build(base(['--block-reward=0'])), ConfigError);
});

test('dangerous combinations are refused, with the reason', () => {
  const cases = [
    [[`--user=${WALLET}`], /--pool=.* is required/],
    [['start', '--pool=' + POOL], null], // no wallet: allowed, the first rig supplies it
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--tunnel=cf'], /needs --ws/],
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--tunnel=nonsense'], /not one of/],
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--bind=0.0.0.0'], /exposes the proxy/],
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--port=99999'], /out of range/],
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--port'], /needs a value/],
    [[`--user=nope`, `--pool=${POOL}`], /look like a Monero address/],
    [[`--user=${WALLET}`, '--pool=nonsense'], /not host:port/],
    [[`--user=${WALLET}`, `--pool=${POOL}`, '--tls'], /--tls-cert/],
  ];

  for (const [argv, pattern] of cases) {
    if (pattern === null) {
      assert.doesNotThrow(() => build(argv), 'a missing --user must be allowed');
      continue;
    }

    assert.throws(() => build(argv), (error) => {
      assert.ok(error instanceof ConfigError, `${argv.join(' ')} threw ${error.name}`);
      assert.match(error.message, pattern);

      return true;
    }, argv.join(' '));
  }
});

test('--bind=0.0.0.0 is allowed once there is a token or an allow list', () => {
  const token = build(base(['--bind=0.0.0.0', '--token=s3cret'])).config;
  assert.strictEqual(token.bind, '0.0.0.0');

  const allowed = build(base(['--bind=0.0.0.0', '--allow=203.0.113.0/24'])).config;
  assert.strictEqual(allowed.bind, '0.0.0.0');
});

test('a flag that needs a value says so instead of eating the next word', () => {
  assert.deepStrictEqual(parseArgs(['--ws', '--port=3333']).flags, { ws: true, port: '3333' });
  assert.throws(
    () => build(['start', '--port', '3333', `--pool=${POOL}`, `--user=${WALLET}`]),
    /--port needs a value/,
    '`--port 3333` must be an error, not a pool named 3333',
  );
});

test('the pool is told which coins the farm can mine, and a typo is an error', () => {
  const { config } = build(base());
  assert.deepStrictEqual(config.algos, ['rx/0', 'rx/wow', 'rx/arq', 'rx/graft', 'rx/sfx', 'rx/yada', 'panthera'],
    'auto is the default: every miner behind this proxy implements the family');

  assert.deepStrictEqual(build(base(['--algo=none'])).config.algos, []);
  assert.deepStrictEqual(build(base(['--algo=rx/wow'])).config.algos, ['rx/wow']);
  assert.deepStrictEqual(build(base(['--algo=rx/0,rx/wow'])).config.algos, ['rx/0', 'rx/wow']);

  assert.throws(() => build(base(['--algo=rx/typo'])), /is not one of/);
  assert.throws(() => build(base(['--algo=rx/2'])), /is not one of/,
    'rx/2 means different parameters on different pool forks; advertising it risks 100% rejects');
});

// --- access ---------------------------------------------------------------

test('the default access list is the LAN, never the internet', () => {
  const access = new AccessList();

  assert.ok(access.allows('192.168.1.50:40000'));
  assert.ok(access.allows('10.1.2.3:1'));
  assert.ok(access.allows('172.16.9.9:1'));
  assert.ok(access.allows('[::1]:1'));
  assert.ok(access.allows('::ffff:192.168.0.7:1'), 'dual-stack sockets report IPv4 as ::ffff:');

  assert.ok(!access.allows('8.8.8.8:1'));
  assert.ok(!access.allows('172.32.0.1:1'), '172.32 is public, 172.16/12 ends at 172.31');
  assert.ok(!access.allows('203.0.113.9:1'));
});

test('an explicit --allow replaces the default', () => {
  const access = new AccessList(['203.0.113.0/24']);

  assert.ok(access.allows('203.0.113.7:1'));
  assert.ok(!access.allows('192.168.1.5:1'), 'an explicit list means exactly that list');
  assert.strictEqual(access.describe(), '203.0.113.0/24');
});

test('one address, not a range, is a /32', () => {
  const access = new AccessList(['198.51.100.4']);
  assert.ok(access.allows('198.51.100.4:1'));
  assert.ok(!access.allows('198.51.100.5:1'));
});

test('a rig reconnect storm is rate limited, a normal farm is not', () => {
  const limiter = new RateLimiter({ perMinute: 60, burst: 20 });

  for (let index = 0; index < 20; index++) assert.ok(limiter.allow('192.168.1.9:1'), `connection ${index} refused`);

  assert.ok(!limiter.allow('192.168.1.9:1'), 'the 21st connection in the same instant is dropped');
  assert.ok(limiter.allow('192.168.1.10:1'), 'a different rig is unaffected');
});

test('IPv6 rigs are matched by IPv6 rules, not by the IPv4 table', () => {
  const access = new AccessList(['::1/128', 'fd00::/8']);

  assert.ok(access.allows('::1'), 'loopback over IPv6');
  assert.ok(access.allows('fd12:3456::7'), 'a unique-local address');
  assert.ok(!access.allows('2001:db8::1'), 'a public v6 address is not in the list');
  assert.ok(!access.allows('fe80::1'), 'link-local is not included when the list is explicit');
});

test('addresses are normalised before matching', () => {
  assert.strictEqual(plainAddress('::ffff:10.0.0.5:1234'), '10.0.0.5');
  assert.strictEqual(plainAddress('[::1]:1234'), '::1');
  assert.strictEqual(plainAddress('10.0.0.5:1234'), '10.0.0.5');
  assert.strictEqual(parseCidr('10.0.0.0/8').prefix, 8);
  assert.throws(() => parseCidr('10.0.0.999/8'));
});

// --- wireguard ------------------------------------------------------------

test('wireguard configs give every rig its own address and never overlap', () => {
  const keys = Array.from({ length: 4 }, (_, index) => ({ private: `priv${index}`, public: `pub${index}` }));
  const state = wireguardConfig({
    rigs: 3,
    endpoint: '203.0.113.10',
    serverKeys: { private: 'serverpriv', public: 'serverpub' },
    peerKeys: keys,
  });

  assert.match(state.server, /Address = 10\.66\.66\.1\/24/);
  assert.match(state.server, /ListenPort = 51820/);

  for (let index = 0; index < 3; index++) {
    const peer = state.peers[index];
    assert.strictEqual(peer.address, `10.66.66.${index + 2}`);
    assert.match(state.server, new RegExp(`AllowedIPs = ${peer.address.replace(/\./g, '\\.')}\\/32`));
    assert.match(peer.client, /Endpoint = 203\.0\.113\.10:51820/);
    assert.match(peer.client, /PersistentKeepalive = 25/);
  }

  const addresses = state.peers.map((peer) => peer.address);
  assert.strictEqual(new Set(addresses).size, addresses.length, 'duplicate addresses would mean duplicate work');
});

test('wireguard config generation refuses to invent keys', () => {
  assert.throws(() => wireguardConfig({ rigs: 1, peerKeys: [] }), /peerKeys/);
  assert.throws(() => wireguardConfig({ rigs: 1, peerKeys: [{ private: 'a', public: 'b' }] }), /serverKeys/);
  assert.throws(() => wireguardConfig({ rigs: 3, peerKeys: [{ private: 'a', public: 'b' }], serverKeys: { private: 'c', public: 'd' } }), /need 3 key pairs/);
});
