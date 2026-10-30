// The three modules that decide whether a proxy earns its keep, tested without
// a network: the nonce field, the allocator that keeps two rigs from doing the
// same work, and the difficulty controller.

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const blob = require('../src/blob');
const { ExtranonceAllocator } = require('../src/extranonce');
const { Vardiff } = require('../src/vardiff');
const { targetHex } = require('../../pool/src/target');

// A 76-byte blob: header (0..39) + nonce (39..43) + the rest.
function makeBlob(nonce = 0) {
  const bytes = Buffer.alloc(76, 0x00);
  bytes[0] = 12;
  bytes[1] = 0;

  return blob.writeNonce(bytes.toString('hex'), 39, nonce);
}

test('the nonce field is little endian, and the round trip is exact', () => {
  const hex = makeBlob(0);

  // 0xAB000001 -> bytes 01 00 00 AB at offset 39.
  const patched = blob.writeNonce(hex, 39, 0xab000001);
  const at = 39 * 2;

  assert.strictEqual(patched.slice(at, at + 8), '010000ab');
  assert.strictEqual(blob.readNonce(patched, 39), 0xab000001);

  // Big values must not go negative through a signed shift.
  assert.strictEqual(blob.readNonce(blob.writeNonce(hex, 39, 0xffffffff), 39), 0xffffffff);
  assert.strictEqual(blob.readNonce(blob.writeNonce(hex, 39, 0xffffffff), 39) > 0, true);
});

test('a prefix lands in the top byte and leaves the low 24 bits to the miner', () => {
  const hex = makeBlob(0);

  const given = blob.applyExtranonce(hex, { minerPrefix: 7 });
  assert.strictEqual(given.mode, 'per-miner');
  assert.strictEqual(given.nonce, 0x07000000);
  assert.strictEqual(blob.prefixOf(given.nonce), 7);

  // The miner varies the low bits; the prefix must survive.
  for (const low of [0, 1, 0xffffff, 0x123456]) {
    const value = (low | (7 << 24)) >>> 0;
    assert.strictEqual(blob.prefixOf(value), 7, `low ${low.toString(16)}`);
  }

  // The blob on the wire equals what the miner will hash.
  assert.strictEqual(blob.readNonce(given.blob, 39), 0x07000000);
});

test('prefix 0 is never handed out: it is the signal that switches extranonce off', () => {
  const hex = makeBlob(0);

  // This is the trap: a blob whose nonce is 0 makes zmrig (and xmrig with
  // --nicehash off) overwrite the whole field, which is exactly the shared
  // space the proxy is trying to avoid.
  const none = blob.applyExtranonce(hex, { minerPrefix: 0 });
  assert.strictEqual(none.mode, 'none');
  assert.strictEqual(none.nonce, 0);

  const allocator = new ExtranonceAllocator();
  assert.notStrictEqual(allocator.acquire('rig-1'), 0);
  assert.strictEqual(allocator.acquire('rig-1'), 1);
});

test('an upstream that already owns the top byte is never split, and says so', () => {
  const hex = makeBlob(0);

  // Some pools hand the proxy its own extranonce. The proxy then has one byte
  // of freedom less, and handing the miner a different prefix would overlap
  // the pool's space.
  const shared = blob.applyExtranonce(hex, { upstreamPrefix: 0x2a, minerPrefix: 9 });
  assert.strictEqual(shared.mode, 'shared');
  assert.strictEqual(blob.prefixOf(shared.nonce), 0x2a);
});

test('a miner that ignores its prefix is detected, not trusted', () => {
  assert.strictEqual(blob.honoursPrefix(0x07000001, 7), true);
  // xmrig started without --nicehash overwrites the top byte.
  assert.strictEqual(blob.honoursPrefix(0x07000001, 9), false);
  // No allocation means nothing to check.
  assert.strictEqual(blob.honoursPrefix(0x00000001, 0), true);
});

test('the allocator gives every rig a different prefix and reuses freed ones', () => {
  const allocator = new ExtranonceAllocator();
  const seen = new Set();

  for (let i = 0; i < 255; i++) {
    const prefix = allocator.acquire(`rig-${i}`);
    assert.ok(prefix !== null, `ran out at ${i}`);
    assert.ok(prefix >= 1 && prefix <= 255);
    assert.ok(!seen.has(prefix), `prefix ${prefix} handed out twice`);
    seen.add(prefix);
  }

  assert.strictEqual(seen.size, 255);
  assert.strictEqual(allocator.acquire('rig-extra'), null, 'the space is full');
  assert.strictEqual(allocator.free, 0);

  // A reconnect must not leak a slot.
  assert.strictEqual(allocator.acquire('rig-0'), 1);

  allocator.release(1);
  assert.strictEqual(allocator.free, 1);
  assert.strictEqual(allocator.acquire('rig-new'), 1, 'lowest free prefix is reused');
});

test('releasing an unknown prefix is harmless', () => {
  const allocator = new ExtranonceAllocator();
  assert.strictEqual(allocator.release(9), false);
  assert.strictEqual(allocator.releaseOwner('never-seen'), false);
  assert.strictEqual(allocator.used, 0);
});

test('the allocator can be narrowed for chained proxies', () => {
  const allocator = new ExtranonceAllocator({ first: 10, last: 12 });
  assert.strictEqual(allocator.capacity, 3);
  assert.strictEqual(allocator.acquire('a'), 10);
  assert.strictEqual(allocator.acquire('b'), 11);
  assert.strictEqual(allocator.acquire('c'), 12);
  assert.strictEqual(allocator.acquire('d'), null);
});

test('vardiff keeps the local difficulty inside the window around the pool\'s', () => {
  // A miner submitting far too fast gets a harder local target...
  const miner = new Vardiff({ upstream: 1000, local: 1000, target: 15, now: 0 });
  for (let i = 0; i < 60; i++) miner.record(1 + i * 0.5, false);
  const raised = miner.poll(30);

  assert.ok(raised !== null, 'a miner 30x too fast must be adjusted');
  assert.ok(raised > 1000);
  assert.ok(raised <= 4000, `never more than 4x the pool (${raised})`);

  // ...and one submitting far too slowly gets an easier one, never below 1/8.
  const slow = new Vardiff({ upstream: 1000, local: 1000, target: 15, now: 0 });
  slow.record(29, false);
  const lowered = slow.poll(30);
  assert.ok(lowered !== null);
  assert.ok(lowered < 1000);
  assert.ok(lowered >= 125, `never below 1/8 of the pool (${lowered})`);
});

test('vardiff leaves a miner that is already on target alone', () => {
  const miner = new Vardiff({ upstream: 1000, local: 1000, target: 15, now: 0 });
  // Two shares in 30 s: 15 s each, exactly the target.
  miner.record(15, true);
  miner.record(30, true);

  assert.strictEqual(miner.poll(30), null, 'no change means no pointless job reset');
});

test('vardiff does not judge a connection before its first window', () => {
  const miner = new Vardiff({ upstream: 500, local: 500, target: 15, now: 100 });

  assert.strictEqual(miner.poll(105), null);
});

test('following the pool keeps the local difficulty in bounds', () => {
  const miner = new Vardiff({ upstream: 1000, local: 1000 });
  miner.setUpstream(8000);

  assert.strictEqual(miner.upstream, 8000);
  assert.ok(miner.current <= 32000);
  // A pinned local difficulty survives a pool change.
  const pinned = new Vardiff({ upstream: 1000, local: 250 });
  pinned.setUpstream(8000, true);
  assert.strictEqual(pinned.current, 250);
});

test('only shares at or above the pool difficulty can be forwarded', () => {
  const miner = new Vardiff({ upstream: 1000, local: 250 });
  assert.strictEqual(miner.clearsUpstream(250), false);
  assert.strictEqual(miner.clearsUpstream(1000), true);

  // The forward ratio is what tells an operator how much work is absorbed here.
  for (let i = 0; i < 10; i++) miner.record(i, i < 3);
  assert.strictEqual(miner.snapshot().forwardRatio, 0.3);
});

test('the proxy computes targets with the same code the pool uses', () => {
  // Drift between the two would make every forwarded share fail upstream.
  const proxyTarget = require('../src/target');
  for (const difficulty of [1, 100, 1000, 20000, 123456.789]) {
    assert.strictEqual(proxyTarget.targetHex(difficulty), targetHex(difficulty));
  }
});

test('the nonce offset follows the algorithm, not a constant', () => {
  const { nonceOffsetFor, NONCE_OFFSET, NONCE_OFFSET_PANTHERA, applyExtranonce } = require('../src/blob');

  assert.strictEqual(nonceOffsetFor('rx/0'), NONCE_OFFSET);
  assert.strictEqual(nonceOffsetFor('rx/wow'), NONCE_OFFSET);
  assert.strictEqual(nonceOffsetFor(undefined), NONCE_OFFSET);
  assert.strictEqual(nonceOffsetFor('panthera'), NONCE_OFFSET_PANTHERA);
  assert.strictEqual(nonceOffsetFor('RX/XLA'), NONCE_OFFSET_PANTHERA);
  assert.notStrictEqual(NONCE_OFFSET_PANTHERA, NONCE_OFFSET);

  // Patching a panthera blob at 39 would corrupt its header.
  const blob = 'ab'.repeat(147) + '00000000' + 'cd'.repeat(20);
  const patched = applyExtranonce(blob, { offset: nonceOffsetFor('panthera'), minerPrefix: 7 });
  assert.strictEqual(patched.mode, 'per-miner');
  assert.strictEqual(patched.blob.slice(0, 147 * 2), blob.slice(0, 147 * 2), 'the header is untouched');
  assert.strictEqual(patched.blob.slice(150 * 2, 150 * 2 + 2), '07', 'the prefix lands at byte 150');
});

test('a refusal is classified, because a retried ban is a longer ban', () => {
  const { Refusal, classifyRefusal } = require('../src/upstream');

  assert.strictEqual(classifyRefusal('your IP is banned'), Refusal.banned);
  assert.strictEqual(classifyRefusal('BLOCKED'), Refusal.banned);
  assert.strictEqual(classifyRefusal('Low difficulty share'), Refusal.invalidShare);
  assert.strictEqual(classifyRefusal('invalid address'), Refusal.credentials);
  assert.strictEqual(classifyRefusal('Unauthenticated'), Refusal.credentials);
  assert.strictEqual(classifyRefusal('too many connections'), Refusal.throttled);
  assert.strictEqual(classifyRefusal('pool is full'), Refusal.full);
  assert.strictEqual(classifyRefusal('something else'), Refusal.unknown);
  assert.strictEqual(classifyRefusal(undefined), Refusal.unknown);
});

