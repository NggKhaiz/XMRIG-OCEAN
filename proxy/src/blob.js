// The nonce field of a Monero block blob, and the extranonce a proxy hands out.
//
// This is the single most dangerous piece of a proxy. Two miners that share a
// nonce space do the same work twice: ten rigs burn ten times the electricity
// for one result. Every proxy that gets this wrong looks healthy from the
// outside -- miners connected, shares accepted -- and earns a fraction of what
// it should.
//
// The unit is a little-endian uint32 at `nonceOffset` (39 for Monero). Miners
// do not send blob bytes: they send the *value* as 8 hex characters (see
// zmrig/src/stratum.zig and the pool's verifier), so every conversion here goes
// through the integer, never through raw byte order.
//
// RandomX miners in "nicehash" mode (xmrig's name for extranonce support, which
// zmrig switches on automatically when the blob's nonce is non-zero) keep the
// top byte of that value and vary the low 24 bits. That is the whole space this
// module manages: 255 usable prefixes x 16,777,216 nonces each.

'use strict';

const NONCE_OFFSET = 39;
const MAX_PREFIX = 255;
/// Prefix 0 is not a valid allocation: a blob whose nonce is 0 is exactly the
/// signal that switches extranonce support *off* in the miner (`detectNicehash`
/// in zmrig/src/job.zig). Handing 0 to a miner would silently put it back in
/// the shared space, which is the bug this module exists to prevent.
const FIRST_PREFIX = 1;

function assertHex(value, name) {
  if (typeof value !== 'string' || !/^[0-9a-fA-F]*$/.test(value) || value.length % 2 !== 0) {
    throw new Error(`${name} must be an even-length hex string`);
  }
}

/** The nonce as the miner will report it: an unsigned 32-bit value. */
function readNonce(blobHex, offset = NONCE_OFFSET) {
  assertHex(blobHex, 'blob');
  if (offset + 4 > blobHex.length / 2) throw new Error('nonce offset outside the blob');

  let value = 0;
  for (let i = 0; i < 4; i++) {
    const byte = parseInt(blobHex.slice((offset + i) * 2, (offset + i) * 2 + 2), 16);
    value += byte * 2 ** (8 * i);
  }

  return value >>> 0;
}

/** A copy of the blob with the nonce value patched in, little endian. */
function writeNonce(blobHex, offset, value) {
  assertHex(blobHex, 'blob');
  if (offset + 4 > blobHex.length / 2) throw new Error('nonce offset outside the blob');

  const bytes = [];
  const number = value >>> 0;
  for (let i = 0; i < 4; i++) {
    bytes.push(((number >>> (8 * i)) & 0xff).toString(16).padStart(2, '0'));
  }

  const start = offset * 2;
  return blobHex.slice(0, start) + bytes.join('') + blobHex.slice(start + 8);
}

/** Top byte of the nonce value: the extranonce the miner is expected to keep. */
function prefixOf(value) {
  return (value >>> 24) & 0xff;
}

/** Nonce value for a prefix and the low 24 bits the miner chose. */
function nonceValue(prefix, low = 0) {
  return (((prefix & 0xff) << 24) | (low & 0xffffff)) >>> 0;
}

/**
 * The blob to send to one miner.
 *
 * `upstreamPrefix` is what the pool already put in the top byte (usually 0: a
 * Monero pool has no reason to split the space, and every pool in practice
 * sends 0). When it is non-zero the proxy cannot also use that byte, so every
 * miner gets the pool's value and the result says so -- pretending otherwise
 * would hand out overlapping spaces.
 *
 * Returns { blob, mode, nonce } where mode is:
 *   'per-miner'  the top byte belongs to this miner
 *   'shared'     the upstream already owns the top byte; no splitting possible
 *   'none'       no extranonce at all (prefix 0 and upstream 0)
 */
function applyExtranonce(blobHex, { offset = NONCE_OFFSET, upstreamPrefix = 0, minerPrefix = 0 } = {}) {
  if (upstreamPrefix !== 0) {
    return {
      blob: writeNonce(blobHex, offset, nonceValue(upstreamPrefix)),
      mode: 'shared',
      nonce: nonceValue(upstreamPrefix),
    };
  }

  if (minerPrefix !== 0) {
    return {
      blob: writeNonce(blobHex, offset, nonceValue(minerPrefix)),
      mode: 'per-miner',
      nonce: nonceValue(minerPrefix),
    };
  }

  return { blob: writeNonce(blobHex, offset, 0), mode: 'none', nonce: 0 };
}

/**
 * True when a submitted nonce still carries the prefix the miner was given.
 * minerts that ignore it (xmrig started without `--nicehash`) overwrite the top
 * byte; their shares are still valid, they are just not protected from
 * duplicate work, so the proxy says so once per miner instead of staying quiet.
 */
function honoursPrefix(nonce, prefix) {
  if (prefix === 0) return true;

  return prefixOf(nonce) === prefix;
}

module.exports = {
  FIRST_PREFIX,
  MAX_PREFIX,
  NONCE_OFFSET,
  applyExtranonce,
  honoursPrefix,
  nonceValue,
  prefixOf,
  readNonce,
  writeNonce,
};
