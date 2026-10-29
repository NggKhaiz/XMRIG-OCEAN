// The pool's fee destination.
//
// The address is kept obfuscated in the source so it cannot be lifted by a
// copy-paste scraper that greps repositories for Monero addresses. It is *not*
// a secret: the running pool publishes it at /api/config and on the status
// page, because a pool that hides where its fee goes does not deserve miners.
//
// Set OPERATOR_ADDRESS (or "operator_address" in config.json) to use your own;
// that always wins over the built-in one.

'use strict';

const crypto = require('node:crypto');

const SALT = 'ocean/pool/fee/v1';
const BLOB = 's261Pq4UAib93ue9ylc1GbTV/dvJte5BsC1y6oD0RCVsfhmNvht2O2Cnjwra87Wg22b2UFeRzDdNZRiJ33GKvB/70NCyb3WrT6gbKfLG3Yv35exeU0LY0S8tFZFO+no=';

/** Deterministic keystream: SHA-256 over a salted counter, never reused. */
function keystream(length) {
  const out = Buffer.alloc(length);
  let offset = 0;
  let counter = 0;

  while (offset < length) {
    const block = crypto.createHash('sha256').update(`${SALT}:${counter++}`).digest();
    block.copy(out, offset);
    offset += block.length;
  }

  return out;
}

let cached = null;

/** The built-in fee address, decoded once. */
function operatorAddress() {
  if (cached) return cached;

  const bytes = Buffer.from(BLOB, 'base64');
  const key = keystream(bytes.length);

  for (let i = 0; i < bytes.length; i++) bytes[i] ^= key[i];

  cached = bytes.toString('utf8');

  return cached;
}

/** What a log line or a page may show without printing the whole address. */
function shortAddress(address = operatorAddress()) {
  return address.length > 16 ? `${address.slice(0, 8)}…${address.slice(-6)}` : address;
}

module.exports = { operatorAddress, shortAddress, keystream };
