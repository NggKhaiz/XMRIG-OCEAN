// The pool table is repeated in four places that a visitor can reach:
//   * legacy/assets/pools.js       — what the wizard and the builder show
//   * oneclick.sh pool_preset() — what the installer actually dials
//   * doc/POOLS.md              — the reasoning and the sources
//   * legacy/content/vi/chon-pool.md — the same reasoning, on the site
//
// A fee or a hostname that is right in one and stale in another is worse than
// no table at all: somebody pastes a dead host, or picks a pool believing it
// is free. These tests fail when the four drift apart.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const pools = require(path.join(ROOT, 'legacy', 'assets', 'pools.js'));

function read(file) {
  return fs.readFileSync(path.join(ROOT, file), 'utf8');
}

// `moneroocean|ocean) echo "gulf.moneroocean.stream:10001" ;;`
function installerPresets() {
  const script = read('oneclick.sh');
  const start = script.indexOf('pool_preset()');
  const body = script.slice(start, script.indexOf('\n}', start));
  const map = {};
  const pattern = /^\s*([a-z0-9.|-]+)\)\s+echo\s+"([^"]+)"/gm;
  let match;
  while ((match = pattern.exec(body)) !== null) {
    for (const name of match[1].split('|')) map[name] = match[2];
  }
  return map;
}

test('every pool the site offers has a working --pool preset in oneclick.sh', () => {
  const presets = installerPresets();

  assert.ok(Object.keys(presets).length >= 6, 'presets were parsed');

  for (const pool of pools.list) {
    const value = presets[pool.id];
    assert.ok(value, `oneclick.sh has no preset for "${pool.id}"`);
    assert.strictEqual(value, pool.host, `--pool=${pool.id} dials ${value}, the site says ${pool.host}`);
  }
});

test('every host the site shows appears in doc/POOLS.md and the site page', () => {
  const doc = read('doc/POOLS.md');
  const page = read('legacy/content/vi/chon-pool.md');

  for (const pool of pools.list) {
    assert.ok(doc.includes(pool.host.split(':')[0]), `doc/POOLS.md never mentions ${pool.name}`);
    assert.ok(page.includes(pool.host.split(':')[0]), `chon-pool.md never mentions ${pool.name}`);
  }
});

test('the documented fee for each pool matches the published one', () => {
  // The numbers checked in October 2026. If a pool changes its fee, this is the
  // line to edit -- and POOLS.md, chon-pool.md and pools.js all at once.
  const expected = {
    moneroocean: 0,
    supportxmr: 0.6,
    c3pool: 0,
    herominers: 0.9,
    xmrpool: 0.9,
    p2pool: 0,
    'p2pool-nano': 0,
  };

  for (const pool of pools.list) {
    assert.strictEqual(pool.fee, expected[pool.id], `${pool.id} fee`);
    assert.ok(pool.min >= 0, `${pool.id} has a minimum`);
    assert.match(pool.host, /^[a-z0-9.-]+:\d+$/, `${pool.id} endpoint looks like host:port`);
    assert.ok(pool.why.length > 40, `${pool.id} explains itself`);
  }
});

test('a TLS port, when offered, is a different port than the plaintext one', () => {
  for (const pool of pools.list) {
    if (!pool.tlsPort) continue;
    assert.match(pool.tlsPort, /^[a-z0-9.-]+:\d+$/);
    assert.notStrictEqual(pool.tlsPort, pool.host, `${pool.id}: TLS must not reuse the plaintext port silently`);
  }
});

test('lookup by id and by host both work, and unknown names return null', () => {
  assert.strictEqual(pools.find('c3pool').name, 'C3Pool');
  assert.strictEqual(pools.find('C3POOL').name, 'C3Pool');
  assert.strictEqual(pools.find('c3pool.com:3333').name, 'C3Pool');
  assert.strictEqual(pools.find('not-a-pool'), null);
  assert.strictEqual(pools.find(''), null);
  assert.strictEqual(pools.find(undefined), null);
});

test('the fee labels are readable Vietnamese, not raw floats', () => {
  assert.strictEqual(pools.feeLabel(pools.find('moneroocean')), '0 %');
  assert.strictEqual(pools.feeLabel(pools.find('supportxmr')), '0,6 %');
  assert.strictEqual(pools.minLabel(pools.find('supportxmr')), '0,1 XMR');
});
