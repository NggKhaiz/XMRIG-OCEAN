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

function difficultyFromTarget(target) {
  const value = typeof target === 'bigint' ? target : BigInt(`0x${target}`);
  if (value <= 0n) return 1;
  const scaled = (MAX_TARGET * ONE) / value;

  return Number(scaled) / 1e6;
}

/** True when the submitted hash clears the job's target. */
function meetsTarget(hashBytes, difficulty) {
  if (!hashBytes || hashBytes.length < 32) return false;

  return hashValue(hashBytes) < targetForDifficulty(difficulty);
}

/** Vardiff: grow or shrink the target share time slowly, and never by more
 *  than 4x in one step (a big jump makes miners throw away work). */
function nextDifficulty(current, observedSeconds, desiredSeconds, limits = {}) {
  const min = Number(limits.min || 0.01);
  const max = Number(limits.max || 1e9);

  if (!(observedSeconds > 0) || !(desiredSeconds > 0)) return current;

  const ratio = Math.min(Math.max(observedSeconds / desiredSeconds, 0.25), 4);
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
