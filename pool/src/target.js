// Difficulty <-> target, and the share test.
//
// Monero convention: a share whose 64-bit hash value is below
//
//     target = 0xFFFFFFFFFFFFFFFF / difficulty
//
// is valid. The pool sends that target to the miner as 16 hex digits, and the
// miner sends back the hash of the blob with its nonce patched in. Both sides
// then compare the same number, so a share cannot be faked by lying about the
// difficulty of the job.

'use strict';

const { hashValue } = require('./util');

const MAX_TARGET = 0xffffffffffffffffn;
const ONE = 1000000n; // difficulty has 6 decimal places

/** Difficulty as an integer with 6 decimals, so JSON never carries floats
 *  that lose precision in target math. */
function parseDifficulty(value) {
  if (typeof value === 'bigint') return value > 0n ? value : ONE;
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return ONE;

  return BigInt(Math.max(Math.round(number * 1e6), 1));
}

function targetForDifficulty(difficulty) {
  const scaled = parseDifficulty(difficulty);
  const target = (MAX_TARGET * ONE) / scaled;

  return target > 0n ? target : 1n;
}

/** 16 lowercase hex digits: the target as a *little-endian* 8-byte integer,
 *  which is how xmrig and zmrig read the `target` field of a job. Getting this
 *  backwards makes the miner see a wildly different difficulty. */
function targetHex(difficulty) {
  const target = targetForDifficulty(difficulty);
  const bytes = Buffer.alloc(8);

  for (let i = 0; i < 8; i++) {
    bytes[i] = Number((target >> BigInt(8 * i)) & 0xffn);
  }

  return bytes.toString('hex');
}

/** Reads a target back into a difficulty.
 *
 *  Two shapes are accepted and they are *not* the same bytes:
 *    * a bigint, the internal form (`targetForDifficulty` output);
 *    * a hex string from the wire, which is a little-endian integer -- the same
 *      order `targetHex` writes and the same order a miner reads it.
 *
 *  Parsing the wire form as big-endian (which this function used to do) turns
 *  difficulty 1000 into 1.07, i.e. a pool or proxy that thinks every share is
 *  worth a thousandth of what it is. A 32-byte target -- what a full CryptoNote
 *  target looks like -- is compared on its low 64 bits, matching `hashValue`. */
function difficultyFromTarget(target) {
  let value;

  if (typeof target === 'bigint') {
    value = target;
  } else if (typeof target === 'number') {
    value = BigInt(Math.trunc(target));
  } else {
    const hex = String(target).replace(/^0x/i, '');
    if (!/^[0-9a-fA-F]+$/.test(hex)) return 1;

    // First eight bytes, low byte first: exactly what the miner compares.
    const low = hex.slice(0, 16).padEnd(16, '0');
    value = BigInt(`0x${Buffer.from(low, 'hex').reverse().toString('hex')}`);
  }

  if (value <= 0n) return 1;
  const scaled = (MAX_TARGET * ONE) / value;

  return Number(scaled) / 1e6;
}

/** True when the submitted hash clears the job's target. */
function meetsTarget(hashBytes, difficulty) {
  if (!hashBytes || hashBytes.length < 32) return false;

  return hashValue(hashBytes) < targetForDifficulty(difficulty);
}

/** Vardiff: grow or shrink the difficulty slowly, and never by more than 4x in
 *  one step (a big jump makes miners throw away work).
 *
 *  Direction matters more than the maths: `observedSeconds` is the time between
 *  shares, and time per share is proportional to difficulty. A miner taking
 *  four times too long needs an *easier* target, i.e. `current * (desired /
 *  observed)` -- the ratio is inverted on purpose. Getting this backwards is
 *  not subtle in its effects and is invisible in a log: the weak rig is given
 *  harder and harder targets until it submits nothing at all while still
 *  burning full power, and the fast rig drifts to the minimum and floods the
 *  pool. This file shipped that inversion once; the test in
 *  pool/tests/unit.test.js now pins the direction. */
function nextDifficulty(current, observedSeconds, desiredSeconds, limits = {}) {
  const min = Number(limits.min || 0.01);
  const max = Number(limits.max || 1e9);

  if (!(observedSeconds > 0) || !(desiredSeconds > 0)) return current;

  const ratio = Math.min(Math.max(desiredSeconds / observedSeconds, 0.25), 4);
  // Square root of the ratio: half a step now, the rest on the next round.
  const adjusted = current * Math.sqrt(ratio);

  return Math.min(Math.max(adjusted, min), max);
}

module.exports = {
  MAX_TARGET,
  difficultyFromTarget,
  meetsTarget,
  nextDifficulty,
  parseDifficulty,
  targetForDifficulty,
  targetHex,
};
