// Unit tests for the parts that decide money and share validity.
//   node --test pool/tests/

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');

const { targetForDifficulty, targetHex, difficultyFromTarget, meetsTarget, nextDifficulty } = require('../src/target');
const { formatXmr, parseXmr, looksLikeAddress, splitLogin, ATOMIC } = require('../src/util');
const { Ledger } = require('../src/ledger');

const OPERATOR = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
const MINER = '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge';
const MINER_B = '4BpRyGYGkEjLnGYtE5jGwFE7U4uBU1w5LZ6UQ6NaHVv7knhG7HdKuPmSf1cw4vK5zG96Hq4EEynuKfXkmDZpEEcQYwXWEwt';

test('difficulty and target round trip', () => {
  for (const difficulty of [1, 100, 2000, 50000, 1e6]) {
    const target = targetForDifficulty(difficulty);
    const back = difficultyFromTarget(target);
    assert.ok(Math.abs(back - difficulty) / difficulty < 1e-6, `${difficulty} -> ${back}`);
  }
});

test('target is sent little-endian, the way miners parse it', () => {
  // difficulty 1000 -> 0x004189374BC6A7EF (big endian) which must go out as
  // ef a7 c6 4b 37 89 41 00.
  assert.strictEqual(targetHex(1000), 'efa7c64b37894100');
  assert.strictEqual(targetHex(2000), 'f753e3a59bc42000');

  // A miner reading those bytes as a little-endian u64 must get the target.
  const bytes = Buffer.from(targetHex(2000), 'hex');
  assert.strictEqual(bytes.readBigUInt64LE(0), targetForDifficulty(2000));
});

test('share test compares the last 8 bytes of the hash', () => {
  const low = Buffer.alloc(32, 0);
  const high = Buffer.alloc(32, 0xff);

  assert.strictEqual(meetsTarget(low, 1), true);
  assert.strictEqual(meetsTarget(high, 1), false);
  // difficulty 1 accepts far more hashes than difficulty 1e6.
  const middle = Buffer.alloc(32, 0);
  middle.writeBigUInt64LE(9_000_000_000_000_000n, 24);
  assert.strictEqual(meetsTarget(middle, 1), true);
  assert.strictEqual(meetsTarget(middle, 1e6), false);
});

test('vardiff moves slowly and respects the limits', () => {
  const slower = nextDifficulty(1000, 60, 15, { min: 1, max: 1e9 });
  assert.ok(slower > 1000 && slower <= 1000 * 2.1, `got ${slower}`);

  const faster = nextDifficulty(1000, 1, 15, { min: 1, max: 1e9 });
  assert.ok(faster < 1000 && faster >= 1000 * 0.49, `got ${faster}`);

  assert.strictEqual(nextDifficulty(2, 1000, 15, { min: 10, max: 100 }), 10);
  assert.strictEqual(nextDifficulty(2, 1, 15, { min: 0.001, max: 1 }), 1);
});

test('amounts are exact piconero BigInts', () => {
  assert.strictEqual(parseXmr('0.010000000000'), 10n * (ATOMIC / 1000n));
  assert.strictEqual(parseXmr('1'), ATOMIC);
  assert.strictEqual(parseXmr('1.000000000001'), ATOMIC + 1n);
  assert.strictEqual(parseXmr('abc'), null);
  assert.strictEqual(formatXmr(ATOMIC), '1.000000000000');
  assert.strictEqual(formatXmr(1n), '0.000000000001');
});

test('addresses and logins', () => {
  assert.strictEqual(looksLikeAddress(MINER), true);
  assert.strictEqual(looksLikeAddress(OPERATOR), true);
  assert.strictEqual(looksLikeAddress('rig1'), false);
  assert.strictEqual(looksLikeAddress(''), false);

  assert.deepStrictEqual(splitLogin(`${MINER}.rig-01`), { address: MINER, worker: 'rig-01' });
  assert.deepStrictEqual(splitLogin(`${MINER}/rig-01`), { address: MINER, worker: 'rig-01' });
  assert.deepStrictEqual(splitLogin('rig1'), { address: 'rig1', worker: '' });
});

function tempLedger(extra = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pool-ledger-'));
  return new Ledger({
    feePercent: 1,
    operatorAddress: OPERATOR,
    windowSeconds: 3600,
    stateFile: path.join(dir, 'state.json'),
    auditFile: path.join(dir, 'audit.jsonl'),
    minPayout: '10000000000',
    ...extra,
  });
}

test('PPLNS splits the reward by difficulty, not by share count', () => {
  const ledger = tempLedger();
  const now = Math.floor(Date.now() / 1000);

  // Miner A: 3 shares of 100 = 300 weight. Miner B: 1 share of 300 = 300.
  // Two different payout addresses: shares of one address are aggregated,
  // because that is who gets the money.
  ledger.addShare(`${MINER}.a`, 100, now - 10);
  ledger.addShare(`${MINER}.a`, 100, now - 9);
  ledger.addShare(`${MINER}.a`, 100, now - 8);
  ledger.addShare(`${MINER_B}.b`, 300, now - 7);

  const record = ledger.distributeBlock({ height: 1, hash: 'aa', rewardAtomic: '600000000000', ts: now });

  assert.strictEqual(record.distributed.length, 2);

  const a = ledger.balanceOf(MINER);
  const b = ledger.balanceOf(MINER_B);
  const total = BigInt(a.pending) + BigInt(b.pending);

  // 0.6 XMR minus the 1 % fee.
  assert.strictEqual(total, 600000000000n - 6000000000n);
  // Equal weights -> equal payouts (within one piconero of rounding).
  const diff = BigInt(a.pending) - BigInt(b.pending);
  assert.ok(diff <= 1n && diff >= -1n, `a=${a.pending} b=${b.pending}`);
});

test('the fee is exactly the published percentage, rounded down', () => {
  const ledger = tempLedger({ feePercent: 1.5 });
  const now = Math.floor(Date.now() / 1000);

  ledger.addShare(`${MINER}.x`, 1000, now);
  const record = ledger.distributeBlock({ height: 2, hash: 'bb', rewardAtomic: '1234567890123', ts: now });

  const reward = 1234567890123n;
  const expectedFee = (reward * 150n) / 10000n; // 1.5 %
  const fee = BigInt(record.fee);
  const dust = BigInt(record.leftover);

  assert.ok(fee <= expectedFee + dust, 'never take more than the published fee plus rounding dust');
  assert.ok(fee >= expectedFee, 'the fee must not silently shrink');
  assert.ok(dust < BigInt(record.distributed.length + 1), 'dust is piconeros, not a hidden cut');
});

test('an empty window sends the reward to the operator and says so in the audit log', () => {
  const ledger = tempLedger();
  const now = Math.floor(Date.now() / 1000);
  const record = ledger.distributeBlock({ height: 3, hash: 'cc', rewardAtomic: '600000000000', ts: now });

  assert.strictEqual(record.distributed.length, 0);
  assert.strictEqual(record.fee, '600000000000');
  assert.ok(fs.existsSync(ledger.auditFile));
  const line = JSON.parse(fs.readFileSync(ledger.auditFile, 'utf8').trim().split('\n').pop());
  assert.strictEqual(line.event, 'block');
  assert.match(line.note, /no shares/);
});

test('shares outside the PPLNS window do not earn', () => {
  const ledger = tempLedger({ windowSeconds: 300 });
  const now = Math.floor(Date.now() / 1000);

  ledger.addShare(`${MINER_B}.old`, 5000, now - 4000);
  ledger.addShare(`${MINER}.new`, 100, now - 10);

  const record = ledger.distributeBlock({ height: 4, hash: 'dd', rewardAtomic: ATOMIC, ts: now });

  assert.strictEqual(record.distributed.length, 1);
  assert.strictEqual(record.distributed[0].address, MINER);
  assert.strictEqual(ledger.balanceOf(MINER_B).pending, '0');
});

test('a payout can never exceed the pending balance', () => {
  const ledger = tempLedger();
  const now = Math.floor(Date.now() / 1000);

  ledger.addShare(`${MINER}.p`, 100, now);
  ledger.distributeBlock({ height: 5, hash: 'ee', rewardAtomic: '10000000000', ts: now }); // 0.01 XMR

  const pending = ledger.balanceOf(MINER).pending;
  assert.ok(BigInt(pending) > 0n);
  assert.strictEqual(ledger.markPaid(MINER, BigInt(pending) + 1n, 'tx'), null);
  assert.ok(ledger.markPaid(MINER, pending, 'tx-1'));
  assert.strictEqual(ledger.balanceOf(MINER).pending, '0');
  assert.strictEqual(ledger.balanceOf(MINER).paid, pending);
});

test('payouts skip addresses that cannot receive money', () => {
  const ledger = tempLedger();
  const now = Math.floor(Date.now() / 1000);

  ledger.addShare('rig-without-address', 1e6, now);
  ledger.addShare(`${MINER}.q`, 1e6, now);
  ledger.distributeBlock({ height: 6, hash: 'ff', rewardAtomic: '100000000000', ts: now });

  const due = ledger.duePayouts();
  assert.strictEqual(due.length, 1);
  assert.strictEqual(due[0].address, MINER);
});

test('the ledger survives a restart', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pool-restart-'));
  const stateFile = path.join(dir, 'state.json');
  const now = Math.floor(Date.now() / 1000);

  const first = new Ledger({ feePercent: 1, operatorAddress: OPERATOR, stateFile, windowSeconds: 3600 });
  first.addShare(`${MINER}.r`, 1000, now);
  first.distributeBlock({ height: 7, hash: '11', rewardAtomic: '50000000000', ts: now });

  const before = first.balanceOf(MINER).pending;

  const second = new Ledger({ feePercent: 1, operatorAddress: OPERATOR, stateFile, windowSeconds: 3600 });
  assert.strictEqual(second.balanceOf(MINER).pending, before);
  assert.strictEqual(second.stats().blocks, 1);
});
