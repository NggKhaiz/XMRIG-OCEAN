// Who is allowed to connect, and how often.
//
// The proxy listens on a LAN interface by default and passes the whole farm
// through. Anyone who reaches the port can mine to their own wallet at your
// electricity, and a public scanner finds an open 3333 in hours. Two knobs,
// both off by default because the default bind is localhost:
//
//   --allow=<cidr,...>   address ranges that may connect
//   --token=<secret>     the password every rig must send
//
// Rate limiting is part of the same job: a rig that reconnects in a loop must
// not turn into a login storm that the *pool* sees and bans.

'use strict';

const LOOPBACK = ['127.0.0.0/8', '::1/128'];
const PRIVATE = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7', 'fe80::/10'];

/** Parses "10.0.0.0/8", "192.168.1.7" or a bare address into a matcher. */
function parseCidr(text) {
  const value = String(text).trim();
  const [address, bits] = value.split('/');
  const family = address.includes(':') ? 6 : 4;

  if (family === 4) {
    const parts = address.split('.');
    if (parts.length !== 4) throw new Error(`not an address: ${value}`);

    let numeric = 0;
    for (const part of parts) {
      const byte = Number(part);
      if (!Number.isInteger(byte) || byte < 0 || byte > 255) throw new Error(`not an address: ${value}`);
      numeric = (numeric << 8) | byte;
    }

    const prefix = bits === undefined ? 32 : Number(bits);
    if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) throw new Error(`bad prefix: ${value}`);

    const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;

    return { family, prefix, base: (numeric >>> 0) & mask, mask };
  }

  const prefix = bits === undefined ? 128 : Number(bits);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 128) throw new Error(`bad prefix: ${value}`);

  return { family, prefix, base: normalise6(address) };
}

function normalise6(text) {
  const [head, tail = ''] = String(text).split('::');
  const left = head ? head.split(':').filter(Boolean) : [];
  const right = tail ? tail.split(':').filter(Boolean) : [];
  const missing = 8 - left.length - right.length;
  const groups = [...left, ...Array(Math.max(missing, 0)).fill('0'), ...right];

  // IPv4-mapped addresses (::ffff:192.168.0.2) arrive from dual-stack sockets.
  if (groups.length && groups[groups.length - 1].includes('.')) {
    const v4 = groups.pop().split('.').map(Number);
    groups.push(((v4[0] << 8) | v4[1]).toString(16), ((v4[2] << 8) | v4[3]).toString(16));
  }

  return groups.map((group) => Number.parseInt(group, 16) || 0);
}

function ipv6Matches(address, rule) {
  const groups = normalise6(address);
  let remaining = rule.prefix;

  for (let i = 0; i < 8 && remaining > 0; i++) {
    const bits = Math.min(remaining, 16);
    const mask = bits === 16 ? 0xffff : (0xffff << (16 - bits)) & 0xffff;

    if ((groups[i] & mask) !== (rule.base[i] & mask)) return false;
    remaining -= bits;
  }

  return true;
}

function ipv4Matches(address, rule) {
  const parts = address.split('.');
  if (parts.length !== 4) return false;

  let numeric = 0;
  for (const part of parts) {
    const byte = Number(part);
    if (!Number.isInteger(byte) || byte < 0 || byte > 255) return false;
    numeric = ((numeric << 8) | byte) >>> 0;
  }

  return (numeric & rule.mask) === rule.base;
}

/** Strips the IPv6 prefix that dual-stack sockets put on an IPv4 peer. */
function plainAddress(remote = '') {
  let address = String(remote).replace(/^::ffff:/, '');

  // "1.2.3.4:5678" or "[::1]:5678" -> address only.
  if (address.startsWith('[')) {
    address = address.slice(1, address.indexOf(']'));
  } else if ((address.match(/:/g) || []).length === 1) {
    address = address.split(':')[0];
  }

  return address;
}

class AccessList {
  /** @param {string[]} rules CIDRs; empty means "loopback and RFC1918". */
  constructor(rules = []) {
    this.explicit = rules.length > 0;
    this.texts = this.explicit ? [...rules] : [...LOOPBACK, ...PRIVATE];
    this.rules = this.texts.map(parseCidr);
  }

  allows(remote) {
    const address = plainAddress(remote);
    if (!address) return false;

    for (const rule of this.rules) {
      if (rule.family === 4 && address.includes('.') && ipv4Matches(address, rule)) return true;
      if (rule.family === 6 && address.includes(':') && ipv6Matches(address, rule)) return true;
    }

    return false;
  }

  describe() {
    if (!this.explicit) return 'loopback + private networks (RFC1918)';

    return this.texts.join(', ');
  }
}

/** Connections per IP per minute. A NAT'd farm of 20 rigs reconnecting at once
 *  is 20; a scan or a fork bomb is hundreds. */
class RateLimiter {
  constructor({ perMinute = 60, burst = 20, now = () => Date.now() } = {}) {
    this.perMinute = perMinute;
    this.burst = burst;
    this.now = now;
    this.buckets = new Map();
  }

  allow(remote) {
    const address = plainAddress(remote);
    const now = this.now();
    let bucket = this.buckets.get(address);

    if (!bucket) {
      bucket = { tokens: this.burst, updated: now };
      this.buckets.set(address, bucket);
    }

    const refill = ((now - bucket.updated) / 60_000) * this.perMinute;
    bucket.tokens = Math.min(this.burst, bucket.tokens + refill);
    bucket.updated = now;

    if (bucket.tokens < 1) return false;

    bucket.tokens -= 1;

    // Keep the map from becoming a memory leak on a hostile network.
    if (this.buckets.size > 4096) {
      for (const [key, value] of this.buckets) {
        if (now - value.updated > 300_000) this.buckets.delete(key);
        if (this.buckets.size <= 2048) break;
      }
    }

    return true;
  }
}

module.exports = { AccessList, RateLimiter, parseCidr, plainAddress };
