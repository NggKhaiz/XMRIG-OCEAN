// Per-miner difficulty, at the proxy.
//
// Two numbers matter and they are not the same one:
//
//   upstream difficulty  what the *pool* asked of the proxy. A share that does
//                        not clear it cannot be forwarded, no matter what the
//                        miner thinks it achieved.
//   local difficulty     what the proxy asks of *this miner*. Lower means the
//                        miner reports shares more often, which is what the
//                        proxy needs to notice a rig that died or throttled.
//
// The default keeps them equal: every share the proxy accepts is forwarded, so
// the pool's hashrate estimate for the rig is exact. Moving the local number is
// allowed but bounded, because both directions have a real cost:
//
//   local < upstream  more shares on the wire, and only a fraction forwarded.
//                     Fine for a metered 3G link, pointless on a LAN.
//   local > upstream  the proxy forwards a sample instead of everything. The
//                     pool's estimate stays unbiased (a share above the local
//                     difficulty is also above the upstream one) but it gets
//                     noisier, and a lucky pool payout window can be missed.
//
// The controller is pure: it is fed a timestamp for every accepted share and
// asked for a decision, so the whole thing is tested without a network.

'use strict';

const { nextDifficulty } = require('../../pool/src/target');

const clamp = (value, low, high) => Math.min(Math.max(value, low), high);

class Vardiff {
  constructor(options = {}) {
    this.upstream = Number(options.upstream ?? 1);
    this.current = Number(options.local ?? this.upstream);
    this.target = Number(options.target ?? 15);          // seconds between shares
    this.minimum = Number(options.min ?? this.upstream / 8);
    this.maximum = Number(options.max ?? this.upstream * 4);
    this.window = Number(options.window ?? 30);          // seconds per sample
    this.startedAt = Number(options.now ?? 0);
    this.lastAdjust = this.startedAt;
    this.shares = 0;                                     // in the current window
    this.accepted = 0;
    this.forwarded = 0;
  }

  /** A share cleared the local target. `forward` says whether the proxy could
   *  send it upstream. */
  record(now, forward) {
    this.shares += 1;
    this.accepted += 1;
    if (forward) this.forwarded += 1;
    this.now = now;
  }

  /** The pool changed the difficulty; local follows unless it was pinned. */
  setUpstream(difficulty, pinned) {
    const value = Number(difficulty);
    if (!(value > 0)) return;

    this.upstream = value;
    this.minimum = value / 8;
    this.maximum = value * 4;
    if (!pinned) this.current = clamp(this.current, this.minimum, this.maximum);
  }

  /**
   * Called on a timer. Returns the new local difficulty, or null when nothing
   * should change -- null matters: every difficulty change forces a new job to
   * the miner, and a job announcement resets its internal work.
   */
  poll(now) {
    const elapsed = now - this.lastAdjust;
    if (elapsed < this.window) return null;

    // A fresh connection has no history; wait for a full window before judging
    // it, otherwise the first sample is always "0 shares in 0 seconds".
    if (this.startedAt === 0) this.startedAt = now;

    const observed = this.shares > 0 ? elapsed / this.shares : elapsed * 2;
    this.shares = 0;
    this.lastAdjust = now;

    const adjusted = nextDifficulty(this.current, observed, this.target, {
      min: this.minimum,
      max: this.maximum,
    });

    // Only act on a real change: 15 % is above the noise of a shared machine
    // and below the point where the miner's own averaging goes wrong.
    if (Math.abs(adjusted - this.current) / this.current < 0.15) return null;

    this.current = clamp(adjusted, this.minimum, this.maximum);

    return this.current;
  }

  /** Would a share at `difficulty` also clear the pool's target? */
  clearsUpstream(difficulty = this.current) {
    return Number(difficulty) >= this.upstream;
  }

  snapshot() {
    return {
      upstream: this.upstream,
      local: this.current,
      target: this.target,
      accepted: this.accepted,
      forwarded: this.forwarded,
      // The ratio is the honest measure of how much work the proxy is
      // absorbing: 0.25 means three of every four shares never reach the pool.
      forwardRatio: this.accepted > 0 ? this.forwarded / this.accepted : null,
    };
  }
}

module.exports = { Vardiff, clamp };
