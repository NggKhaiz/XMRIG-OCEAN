// Job store: turns block templates into per-miner jobs and keeps them alive
// long enough for slow shares to arrive.
//
// One template per height is shared by every miner. The blob is *not* mutated
// per miner: the nonce lives in the blob and miners pick their own, exactly
// like every other stratum pool. The pool rewrites the nonce only when it
// verifies a submitted share.

'use strict';

const { randomHex } = require('./util');
const { targetHex } = require('./target');

class JobStore {
  constructor(options = {}) {
    this.ttl = Number(options.ttl || 600);
    this.log = options.logger || (() => {});
    this.current = null;
    this.byId = new Map();
    this.counter = 0;
    this.seq = 0;
  }

  /**
   * template: { blob, height, seed_hash, next_seed_hash, difficulty }
   * (the shape monerod returns, already normalised by daemon.js)
   */
  setTemplate(template) {
    this.counter += 1;
    this.seq += 1;

    const job = {
      id: `job-${this.counter}-${randomHex(4)}`,
      blob: template.blob,
      height: Number(template.height || 0),
      seed: template.seed_hash || '',
      nextSeed: template.next_seed_hash || '',
      algo: template.algo || 'rx/0',
      nonceOffset: Number(template.nonce_offset || 39),
      announcedAt: Math.floor(Date.now() / 1000),
      networkDifficulty: Number(template.difficulty || 0),
      reward: template.reward || '0',
      blockReward: template.reward_atomic || '0',
      // A template that is already a few seconds old still makes a fine job.
      templateSeenAt: Date.now(),
    };

    this.current = job;
    this.byId.set(job.id, job);
    this.prune();

    return job;
  }

  get(id) {
    return this.byId.get(id) || null;
  }

  isFresh(job, now = Math.floor(Date.now() / 1000)) {
    if (!job) return false;

    return now - job.announcedAt <= this.ttl;
  }

  /** The object sent to a miner. Difficulty is the *share* difficulty. */
  forMiner(job, difficulty) {
    return {
      job_id: job.id,
      blob: job.blob,
      target: targetHex(difficulty),
      height: job.height,
      seed_hash: job.seed,
      next_seed_hash: job.nextSeed,
      algo: job.algo,
    };
  }

  prune(now = Math.floor(Date.now() / 1000)) {
    if (this.byId.size < 64) return;

    for (const [id, job] of this.byId.entries()) {
      if (now - job.announcedAt > this.ttl * 2 && job.id !== this.current?.id) {
        this.byId.delete(id);
      }
    }
  }

  /** Deterministic template for tests and for `mode: "synthetic"`. */
  static synthetic(height = 1, seed = null) {
    const seedHash = seed || '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
    const blob = Buffer.alloc(76);

    blob[0] = 12; // major version
    blob[1] = 0;  // minor version
    // Timestamp at 2..6, prev hash 6..38, nonce 39..43: left zero, which is
    // fine — the pool only needs a blob that hashes consistently.
    blob.writeUInt32LE(height, 43); // a little entropy so jobs differ

    return {
      blob: blob.toString('hex'),
      height,
      seed_hash: seedHash,
      next_seed_hash: seedHash,
      algo: 'rx/0',
      difficulty: 50000000,
      reward: '0.600000000000',
      reward_atomic: '600000000000',
      nonce_offset: 39,
    };
  }
}

module.exports = { JobStore };
