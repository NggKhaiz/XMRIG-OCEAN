// Extranonce allocation: one top byte per connected miner, released on
// disconnect, never two miners holding the same one.
//
// Deliberately simple and deterministic (lowest free prefix first) so a restart
// hands the same prefixes back to the same rigs, and the allocator's state is
// one array that can be printed by `proxy status`.

'use strict';

const { FIRST_PREFIX, MAX_PREFIX } = require('./blob');

class ExtranonceAllocator {
  constructor({ first = FIRST_PREFIX, last = MAX_PREFIX } = {}) {
    this.first = Math.min(Math.max(first, FIRST_PREFIX), MAX_PREFIX);
    this.last = Math.min(Math.max(last, this.first), MAX_PREFIX);
    this.owners = new Map();   // prefix -> owner id
    this.reverse = new Map();  // owner id -> prefix
  }

  get capacity() {
    return this.last - this.first + 1;
  }

  get used() {
    return this.owners.size;
  }

  get free() {
    return this.capacity - this.used;
  }

  /**
   * Gives `ownerId` a prefix. The same owner asking twice gets the same answer,
   * which makes a reconnect after a network blip free instead of a slot leak.
   * Returns null when the space is full -- the caller has to decide whether to
   * share (and duplicate work) or refuse the miner.
   */
  acquire(ownerId) {
    const existing = this.reverse.get(ownerId);
    if (existing !== undefined) return existing;

    for (let prefix = this.first; prefix <= this.last; prefix++) {
      if (this.owners.has(prefix)) continue;

      this.owners.set(prefix, ownerId);
      this.reverse.set(ownerId, prefix);

      return prefix;
    }

    return null;
  }

  release(prefix) {
    const owner = this.owners.get(prefix);
    if (owner === undefined) return false;

    this.owners.delete(prefix);
    this.reverse.delete(owner);

    return true;
  }

  releaseOwner(ownerId) {
    const prefix = this.reverse.get(ownerId);
    if (prefix === undefined) return false;

    return this.release(prefix);
  }

  ownerOf(prefix) {
    return this.owners.get(prefix) ?? null;
  }

  snapshot() {
    return {
      first: this.first,
      last: this.last,
      capacity: this.capacity,
      used: this.used,
      free: this.free,
    };
  }
}

module.exports = { ExtranonceAllocator };
