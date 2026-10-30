// What a rig's work is worth, from what the proxy actually observes.
//
// The proxy never sees a hashrate -- rigs do not report one over stratum -- so
// it measures. Every accepted share at the difficulty *this proxy handed out*
// is proof of `difficulty * 2^32` hashes on average, so
//
//     H/s ~= accepted * difficulty * 2^32 / seconds
//
// which is unbiased and converges within a few shares. Turning that into XMR
// needs two numbers the proxy cannot measure: the network difficulty and the
// block reward. Both are optional, and when they are missing `/status` says
// `null` rather than inventing a figure -- a wrong XMR/day costs an operator
// real money when they use it to decide where to point a farm.

'use strict';

const TWO32 = 4294967296;
const BLOCK_TIME = 120;      // Monero target block time, seconds
const DAY = 86400;

/** Reads a difficulty out of whatever shape a node or pool API returns.
 *
 *  Accepts `{difficulty}`, `{data:{difficulty}}`, `{network:{difficulty}}`,
 *  `{netdiff}`, and the same keys as numeric strings. Returns `null` when there
 *  is nothing usable, so a wrong URL shows as "unknown" instead of "0". */
function pickDifficulty(payload) {
  if (payload === null || payload === undefined) return null;
  if (typeof payload === 'number' || typeof payload === 'string') {
    const single = Number(payload);

    return Number.isFinite(single) && single > 0 ? single : null;
  }
  if (typeof payload !== 'object') return null;

  const keys = ['difficulty', 'netdiff', 'network_difficulty', 'networkDifficulty'];

  for (const key of keys) {
    if (payload[key] !== undefined) {
      const value = pickDifficulty(payload[key]);
      if (value) return value;
    }
  }

  for (const nested of ['data', 'network', 'result', 'stats']) {
    if (payload[nested] && typeof payload[nested] === 'object') {
      const value = pickDifficulty(payload[nested]);
      if (value) return value;
    }
  }

  return null;
}

/** H/s from shares this proxy accepted, at the difficulty it gave the rig. */
function hashrateFromShares({ shares, difficulty, seconds }) {
  const count = Number(shares);
  const diff = Number(difficulty);
  const time = Number(seconds);

  if (!(count > 0) || !(diff > 0) || !(time > 0)) return 0;

  return (count * diff * TWO32) / time;
}

/** XMR/day for a given hashrate. `null` when the network figure is unknown. */
function xmrPerDay({ hashrate, networkDifficulty, reward = 0.6 }) {
  const rate = Number(hashrate);
  const diff = Number(networkDifficulty);

  if (!(rate > 0) || !(diff > 0)) return null;

  // Expected blocks per day for this share of the network, times the reward.
  return (rate / diff) * (DAY / BLOCK_TIME) * Number(reward);
}

/** Holds the network difficulty, from a flag or a periodically fetched URL.
 *
 *  The feed is deliberately boring: one timer, one request, no retries storm,
 *  and any failure leaves the last known value in place. A monitoring feature
 *  must never be able to take the tunnel or the pool connection down. */
class NetworkFeed {
  constructor(options = {}) {
    this.fixed = Number(options.difficulty) > 0 ? Number(options.difficulty) : 0;
    this.url = String(options.url || '').trim();
    this.intervalMs = Number(options.intervalMs) || 600_000;
    this.reward = Number(options.reward) > 0 ? Number(options.reward) : 0.6;
    this.fetchImpl = options.fetchImpl || globalThis.fetch;
    this.log = options.logger || (() => {});
    this.value = this.fixed || null;
    this.fetchedAt = 0;
    this.error = null;
    this.timer = null;
    this.stopped = false;
  }

  get difficulty() {
    return this.value;
  }

  /** `flag`, `url` or `null` -- what /status reports as the source. */
  get source() {
    if (this.fixed) return 'flag';
    if (this.value) return 'url';
    return null;
  }

  snapshot() {
    return {
      difficulty: this.difficulty,
      blockReward: this.reward,
      source: this.source,
      fetchedAt: this.fetchedAt || null,
      error: this.error,
    };
  }

  async refresh() {
    if (!this.url || this.fixed) return this.value;

    try {
      const response = await this.fetchImpl(this.url, {
        signal: AbortSignal.timeout(5000),
        headers: { accept: 'application/json' },
      });

      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const difficulty = pickDifficulty(await response.json());
      if (!difficulty) throw new Error('no difficulty in the response');

      this.value = difficulty;
      this.fetchedAt = Math.floor(Date.now() / 1000);
      this.error = null;
    } catch (error) {
      // Keep the last good number: the network difficulty moves by fractions
      // of a percent per hour, so an old value is far better than none.
      this.error = error.message;
      this.log('warn', `network difficulty: ${error.message} (keeping ${this.value ?? 'unknown'})`);
    }

    return this.value;
  }

  start() {
    if (!this.url || this.fixed) return this;

    this.refresh();
    this.timer = setInterval(() => this.refresh(), this.intervalMs);
    if (typeof this.timer.unref === 'function') this.timer.unref();

    return this;
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.stopped = true;
  }
}

module.exports = {
  BLOCK_TIME,
  NetworkFeed,
  hashrateFromShares,
  pickDifficulty,
  xmrPerDay,
};
