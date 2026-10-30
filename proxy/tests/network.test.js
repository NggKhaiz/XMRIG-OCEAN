'use strict';

// The /status price column is the only place this proxy turns shares into
// money. A wrong number there is worse than no number: it is used to decide
// where a farm points, so every shape of "unknown" has to stay null.

const test = require('node:test');
const assert = require('node:assert');

const { NetworkFeed, hashrateFromShares, pickDifficulty, xmrPerDay } = require('../src/network');

test('a difficulty is read from the shapes public APIs use', () => {
  assert.strictEqual(pickDifficulty({ difficulty: 3.1e11 }), 3.1e11);
  assert.strictEqual(pickDifficulty({ data: { difficulty: 123 } }), 123);
  assert.strictEqual(pickDifficulty({ network: { difficulty: 456 } }), 456);
  assert.strictEqual(pickDifficulty({ netdiff: 789 }), 789);
  assert.strictEqual(pickDifficulty({ difficulty: '987654' }), 987654);
  assert.strictEqual(pickDifficulty('1500'), 1500);
  assert.strictEqual(pickDifficulty(42), 42);
});

test('anything that is not a difficulty stays unknown', () => {
  assert.strictEqual(pickDifficulty({}), null);
  assert.strictEqual(pickDifficulty({ difficulty: 0 }), null);
  assert.strictEqual(pickDifficulty({ difficulty: 'n/a' }), null);
  assert.strictEqual(pickDifficulty(null), null);
  assert.strictEqual(pickDifficulty([1, 2, 3]), null);
});

test('hashrate is derived from accepted shares at the difficulty we handed out', () => {
  // 1 share of difficulty 1000 in 100 s is 1000 * 2^32 / 100 hashes per second.
  assert.strictEqual(hashrateFromShares({ shares: 1, difficulty: 1000, seconds: 100 }), 42949672960);
  // Two rigs at different difficulties: the same real hashrate must come out.
  const slow = hashrateFromShares({ shares: 10, difficulty: 100, seconds: 1000 });
  const fast = hashrateFromShares({ shares: 100, difficulty: 10, seconds: 1000 });
  assert.strictEqual(slow, fast);
  // No shares, no time, no answer -- never Infinity or NaN.
  assert.strictEqual(hashrateFromShares({ shares: 0, difficulty: 100, seconds: 10 }), 0);
  assert.strictEqual(hashrateFromShares({ shares: 1, difficulty: 100, seconds: 0 }), 0);
});

test('XMR/day needs a network difficulty and says so by returning null', () => {
  assert.strictEqual(xmrPerDay({ hashrate: 1000, networkDifficulty: 0 }), null);
  assert.strictEqual(xmrPerDay({ hashrate: 0, networkDifficulty: 3e11 }), null);

  // 1 kH/s is 1000/3e11 of a 3e11 network; 720 blocks a day at 0.6 XMR each.
  const value = xmrPerDay({ hashrate: 1000, networkDifficulty: 3e11, reward: 0.6 });
  assert.ok(Math.abs(value - 1.44e-6) < 1e-12, `got ${value}`);
});

test('the feed prefers a fixed difficulty and never fetches when pinned', async () => {
  let calls = 0;
  const feed = new NetworkFeed({
    difficulty: 3.2e11,
    url: 'https://example.invalid/stats',
    fetchImpl: async () => { calls += 1; return { ok: true, json: async () => ({ difficulty: 1 }) }; },
  });

  await feed.refresh();
  assert.strictEqual(calls, 0);
  assert.strictEqual(feed.difficulty, 3.2e11);
  assert.strictEqual(feed.source, 'flag');
});

test('the feed fetches once, then keeps the last good value when the API fails', async () => {
  let payload = { data: { difficulty: 3.0e11 } };
  let fail = false;
  const warnings = [];
  const feed = new NetworkFeed({
    url: 'https://example.invalid/stats',
    logger: (level, message) => warnings.push(`${level}:${message}`),
    fetchImpl: async () => {
      if (fail) throw new Error('ETIMEDOUT');
      return { ok: true, json: async () => payload };
    },
  });

  await feed.refresh();
  assert.strictEqual(feed.difficulty, 3.0e11);
  assert.strictEqual(feed.source, 'url');

  fail = true;
  await feed.refresh();
  assert.strictEqual(feed.difficulty, 3.0e11, 'an old value beats no value');
  assert.strictEqual(feed.snapshot().error, 'ETIMEDOUT');
  assert.strictEqual(warnings.length, 1);

  fail = false;
  payload = { difficulty: 3.1e11 };
  await feed.refresh();
  assert.strictEqual(feed.difficulty, 3.1e11);
  assert.strictEqual(feed.snapshot().error, null);
});

test('an HTTP error does not become a difficulty', async () => {
  const feed = new NetworkFeed({
    url: 'https://example.invalid/stats',
    logger: () => {},
    fetchImpl: async () => ({ ok: false, status: 429, json: async () => ({ difficulty: 1 }) }),
  });

  await feed.refresh();
  assert.strictEqual(feed.difficulty, null);
  assert.strictEqual(feed.source, null);
  assert.match(feed.snapshot().error, /HTTP 429/);
});
