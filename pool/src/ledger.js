// Share accounting and payout ledger.
//
// The model is PPLNS over a sliding time window: when a block is found, the
// reward is split by *share difficulty* inside the window, not by hash count.
// That is what makes a 60 kH/s rig and three 20 kH/s rigs earn the same for the
// same work.
//
// Every number here is a BigInt in atomic units (1e-12 XMR). Floats are only
// used for display, because rounding a payout down to the last piconero must
// never depend on the platform's floating point.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { ATOMIC, formatXmr, looksLikeAddress, splitLogin } = require('./util');
const { parseDifficulty } = require('./target');

class Ledger {
  constructor(options = {}) {
    this.feePercent = Number(options.feePercent ?? 1);
    this.operatorAddress = options.operatorAddress || '';
    this.windowSeconds = Number(options.windowSeconds ?? 3600);
    this.minPayout = BigInt(options.minPayout ?? '10000000000'); // 0.01 XMR
    this.stateFile = options.stateFile || null;
    this.auditFile = options.auditFile || null;
    this.log = options.logger || (() => {});

    this.workers = new Map();   // address -> { pending, paid, shares, lastSeen, worker }
    this.shares = [];           // { ts, difficulty(BigInt), address }
    this.blocks = [];           // found blocks and how they were split
    this.payouts = [];          // transfer history
    this.totals = {
      shares: 0,
      difficultY: 0n,           // sum of share difficulty, in micro units
      acceptedHashrate: 0n,     // rough estimate over the window
      blocks: 0,
      rewardAtomic: 0n,
      feeAtomic: 0n,
      paidAtomic: 0n,
    };

    this.load();
  }

  // --- persistence ------------------------------------------------------

  load() {
    if (!this.stateFile || !fs.existsSync(this.stateFile)) return;

    try {
      const raw = JSON.parse(fs.readFileSync(this.stateFile, 'utf8'));

      for (const [address, entry] of Object.entries(raw.workers || {})) {
        this.workers.set(address, {
          pending: BigInt(entry.pending || '0'),
          paid: BigInt(entry.paid || '0'),
          shares: Number(entry.shares || 0),
          lastSeen: Number(entry.lastSeen || 0),
          worker: entry.worker || '',
        });
      }

      this.blocks = raw.blocks || [];
      this.payouts = raw.payouts || [];
      this.totals.blocks = Number(raw.totals?.blocks || 0);
      this.totals.rewardAtomic = BigInt(raw.totals?.rewardAtomic || '0');
      this.totals.feeAtomic = BigInt(raw.totals?.feeAtomic || '0');
      this.totals.paidAtomic = BigInt(raw.totals?.paidAtomic || '0');
      this.log('info', `ledger restored: ${this.workers.size} workers, ${this.blocks.length} blocks`);
    } catch (error) {
      // A corrupt state file must not stop the pool: keep a copy and start
      // clean rather than crash on every restart.
      const backup = `${this.stateFile}.corrupt-${Date.now()}`;
      try { fs.renameSync(this.stateFile, backup); } catch (_) {}
      this.log('error', `state file was unreadable (${error.message}), moved to ${backup}`);
    }
  }

  save() {
    if (!this.stateFile) return;

    const workers = {};
    for (const [address, entry] of this.workers.entries()) {
      workers[address] = {
        pending: entry.pending.toString(),
        paid: entry.paid.toString(),
        shares: entry.shares,
        lastSeen: entry.lastSeen,
        worker: entry.worker,
      };
    }

    const payload = {
      version: 1,
      saved: new Date().toISOString(),
      workers,
      blocks: this.blocks.slice(-200),
      payouts: this.payouts.slice(-500),
      totals: {
        blocks: this.totals.blocks,
        rewardAtomic: this.totals.rewardAtomic.toString(),
        feeAtomic: this.totals.feeAtomic.toString(),
        paidAtomic: this.totals.paidAtomic.toString(),
      },
    };

    const dir = path.dirname(this.stateFile);
    if (dir && dir !== '.') fs.mkdirSync(dir, { recursive: true });

    const tmp = `${this.stateFile}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
    fs.renameSync(tmp, this.stateFile); // atomic on POSIX
  }

  audit(event) {
    if (!this.auditFile) return;

    const dir = path.dirname(this.auditFile);
    if (dir && dir !== '.') fs.mkdirSync(dir, { recursive: true });

    try {
      fs.appendFileSync(this.auditFile, `${JSON.stringify({ ...event, at: new Date().toISOString() })}\n`);
    } catch (error) {
      this.log('warn', `cannot write the audit log: ${error.message}`);
    }
  }

  // --- shares -----------------------------------------------------------

  workerFor(address, workerName) {
    let entry = this.workers.get(address);

    if (!entry) {
      entry = { pending: 0n, paid: 0n, shares: 0, lastSeen: 0, worker: workerName || '' };
      this.workers.set(address, entry);
    }

    if (workerName) entry.worker = workerName;

    return entry;
  }

  /** Records an accepted share. Returns the worker entry. */
  addShare(login, difficulty, ts = Math.floor(Date.now() / 1000)) {
    const { address, worker } = splitLogin(login);
    const entry = this.workerFor(address, worker);

    const diff = parseDifficulty(difficulty);
    entry.shares += 1;
    entry.lastSeen = ts;

    this.shares.push({ ts, difficulty: diff, address });
    this.totals.shares += 1;
    this.totals.difficultY += diff;

    // Keep the array bounded: drop anything older than the window, but never
    // less than a minute of history.
    const cutoff = ts - Math.max(this.windowSeconds, 60);
    let drop = 0;
    while (drop < this.shares.length && this.shares[drop].ts < cutoff) drop += 1;
    if (drop > 0) this.shares.splice(0, drop);

    return entry;
  }

  windowWeights(ts = Math.floor(Date.now() / 1000)) {
    const cutoff = ts - this.windowSeconds;
    const weights = new Map();
    let total = 0n;

    for (const share of this.shares) {
      if (share.ts < cutoff) continue;
      weights.set(share.address, (weights.get(share.address) || 0n) + share.difficulty);
      total += share.difficulty;
    }

    return { weights, total };
  }

  /** Hashrate estimate for the status page: work in the window / elapsed time.
   *  The floor on the span matters: one lucky share in the first second would
   *  otherwise read as hundreds of GH/s. 120 s is short enough to react, long
   *  enough to be honest. */
  estimateHashrate(ts = Math.floor(Date.now() / 1000)) {
    const { total } = this.windowWeights(ts);
    if (total === 0n) return 0;

    // In CryptoNote a share of difficulty d costs d hashes on average, and
    // `total` carries difficulty with six decimals. Multiplying by 2^32 here
    // reported a 100 H/s miner as 100 GH/s.
    const hashes = Number(total) / 1e6;
    const oldest = this.shares[0]?.ts ?? ts;
    const span = Math.min(Math.max(ts - oldest, 120), Math.max(this.windowSeconds, 120));

    return hashes / span;
  }

  // --- blocks -----------------------------------------------------------

  /**
   * Splits a block reward.
   *  rewardAtomic : BigInt, the full reward of the block
   *  feePercent   : override for this block (tests)
   *  Returns a record that is appended to `blocks` and written to the audit log.
   */
  distributeBlock({ height, hash, rewardAtomic, ts = Math.floor(Date.now() / 1000), feePercent }) {
    const reward = BigInt(rewardAtomic);
    const feePct = Number(feePercent ?? this.feePercent);
    const { weights, total } = this.windowWeights(ts);

    const record = {
      height,
      hash,
      ts,
      reward: reward.toString(),
      rewardXmr: formatXmr(reward),
      feePercent: feePct,
      fee: '0',
      feeXmr: '0.000000000000',
      operatorAddress: this.operatorAddress,
      shares: this.shares.length,
      distributed: [],
      leftover: '0',
    };

    if (total === 0n) {
      // Nobody shares in the window: the whole reward goes to the operator,
      // and the audit log says so instead of losing the money silently.
      record.fee = reward.toString();
      record.feeXmr = formatXmr(reward);
      record.leftover = reward.toString();
      this.totals.feeAtomic += reward;
      this.blocks.push(record);
      this.totals.blocks += 1;
      this.totals.rewardAtomic += reward;
      this.audit({ event: 'block', ...record, note: 'no shares in the window' });
      this.save();

      return record;
    }

    // Fee first, in atomic units, rounding *down* so the pool never takes a
    // piconero more than the published percentage.
    const fee = (reward * BigInt(Math.round(feePct * 100))) / 10000n;
    const payable = reward - fee;

    let assigned = 0n;
    const entries = [...weights.entries()];

    for (const [address, weight] of entries) {
      const amount = (payable * weight) / total;
      if (amount <= 0n) continue;

      const entry = this.workerFor(address, '');
      entry.pending += amount;
      entry.lastSeen = ts;
      assigned += amount;

      record.distributed.push({
        address,
        weight: weight.toString(),
        amount: amount.toString(),
        amountXmr: formatXmr(amount),
      });
    }

    // Rounding dust stays with the pool and is reported, not hidden.
    const dust = payable - assigned;
    record.fee = (fee + dust).toString();
    record.feeXmr = formatXmr(fee + dust);
    record.leftover = dust.toString();

    this.totals.feeAtomic += fee + dust;
    this.totals.rewardAtomic += reward;
    this.totals.blocks += 1;
    this.blocks.push(record);

    this.audit({ event: 'block', ...record });
    this.save();

    return record;
  }

  // --- payouts ----------------------------------------------------------

  duePayouts(now = Math.floor(Date.now() / 1000)) {
    const out = [];

    for (const [address, entry] of this.workers.entries()) {
      if (entry.pending >= this.minPayout && looksLikeAddress(address)) {
        out.push({ address, amount: entry.pending, atomic: entry.pending.toString() });
      }
    }

    // Largest first: fewer transactions, lower total fees.
    out.sort((a, b) => (a.amount === b.amount ? 0 : a.amount > b.amount ? -1 : 1));

    return out;
  }

  markPaid(address, amount, txid) {
    const entry = this.workers.get(address);
    if (!entry) return null;

    const value = BigInt(amount);
    if (value > entry.pending) return null; // never pay more than owed

    entry.pending -= value;
    entry.paid += value;
    this.totals.paidAtomic += value;

    const record = {
      address,
      amount: value.toString(),
      amountXmr: formatXmr(value),
      txid: txid || null,
      ts: Math.floor(Date.now() / 1000),
    };
    this.payouts.push(record);
    this.audit({ event: 'payout', ...record });
    this.save();

    return record;
  }

  balanceOf(address) {
    const entry = this.workers.get(address.split('.')[0]);

    return entry ? { pending: entry.pending.toString(), paid: entry.paid.toString(), shares: entry.shares } : null;
  }

  // --- reporting --------------------------------------------------------

  stats() {
    const now = Math.floor(Date.now() / 1000);
    const { total } = this.windowWeights(now);
    const top = [...this.windowWeights(now).weights.entries()]
      .sort((a, b) => (a[1] === b[1] ? 0 : a[1] > b[1] ? -1 : 1))
      .slice(0, 20)
      .map(([address, weight]) => ({
        address,
        sharePercent: total > 0n ? Number((weight * 10000n) / total) / 100 : 0,
      }));

    return {
      feePercent: this.feePercent,
      operatorAddress: this.operatorAddress,
      windowSeconds: this.windowSeconds,
      hashrate: this.estimateHashrate(now),
      workers: this.workers.size,
      activeWorkers: this.shares.filter((s) => s.ts > now - 300).length > 0
        ? new Set(this.shares.filter((s) => s.ts > now - 300).map((s) => s.address)).size
        : 0,
      sharesInWindow: this.shares.filter((s) => s.ts > now - this.windowSeconds).length,
      blocks: this.totals.blocks,
      rewardXmr: formatXmr(this.totals.rewardAtomic),
      feeXmr: formatXmr(this.totals.feeAtomic),
      paidXmr: formatXmr(this.totals.paidAtomic),
      pendingXmr: formatXmr([...this.workers.values()].reduce((sum, w) => sum + w.pending, 0n)),
      top,
    };
  }
}

module.exports = { Ledger, ATOMIC };
