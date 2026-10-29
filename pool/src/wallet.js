// Payouts through monero-wallet-rpc.
//
// Two modes:
//   "ledger" — compute and record what each worker is owed, send nothing.
//              Safe default for a test pool; the numbers are still auditable.
//   "wallet" — actually send transfers. Requires monero-wallet-rpc with a
//              wallet that holds the block rewards.
//
// Safety rules baked in:
//   * never send more than the ledger says is pending,
//   * one transfer per address per round, largest first,
//   * stop the round on the first RPC error (no half-paid state),
//   * every transfer is written to the audit log with its txid.

'use strict';

const { formatXmr } = require('./util');

class Wallet {
  constructor(config, options = {}) {
    this.url = String(config.wallet_rpc || '').replace(/\/+$/, '');
    this.user = config.wallet_user || null;
    this.password = config.wallet_password || null;
    this.mode = config.payout_mode || 'ledger';
    this.reserve = BigInt(Math.round(Number(config.reserve || 0) * 1e12));
    this.minPayout = BigInt(Math.round(Number(config.payout_min || 0.01) * 1e12));
    this.log = options.logger || (() => {});
    this.rpcId = 0;
    this.unlocked = null;
  }

  authHeader() {
    if (!this.user && !this.password) return {};

    return { Authorization: `Basic ${Buffer.from(`${this.user || ''}:${this.password || ''}`).toString('base64')}` };
  }

  async call(method, params = {}, timeoutMs = 15000) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const response = await fetch(`${this.url}/json_rpc`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...this.authHeader() },
        body: JSON.stringify({ jsonrpc: '2.0', id: String(++this.rpcId), method, params }),
        signal: controller.signal,
      });

      const text = await response.text();
      if (!response.ok) throw new Error(`wallet-rpc HTTP ${response.status}: ${text.slice(0, 160)}`);

      const parsed = JSON.parse(text);
      if (parsed.error) throw new Error(parsed.error.message || JSON.stringify(parsed.error));

      return parsed.result;
    } finally {
      clearTimeout(timer);
    }
  }

  async balance() {
    const result = await this.call('get_balance', { account_index: 0 });
    this.unlocked = BigInt(result.unlocked_balance || 0);

    return { total: BigInt(result.balance || 0), unlocked: this.unlocked };
  }

  /** Sends one transfer to one address. Returns the txid. */
  async send(address, amountAtomic) {
    const result = await this.call('transfer', {
      destinations: [{ amount: Number(amountAtomic), address }],
      account_index: 0,
      priority: 1,
      // The pool pays the network fee; the worker receives exactly what the
      // ledger says it is owed.
      subtract_fee_from_amount: false,
    }, 60000);

    if (!result || !result.tx_hash) {
      throw new Error(`wallet-rpc returned no tx_hash: ${JSON.stringify(result).slice(0, 160)}`);
    }

    return result.tx_hash;
  }

  /**
   * One payout round.
   *  ledger   : Ledger instance
   *  onPaid   : optional callback(record) — the server uses it to log lines
   * Returns a summary instead of throwing, so the timer keeps running.
   */
  async runRound(ledger) {
    const due = ledger.duePayouts();
    const summary = { mode: this.mode, due: due.length, paid: 0, skipped: 0, failed: 0, txids: [] };

    if (due.length === 0) return summary;

    if (this.mode !== 'wallet') {
      // Ledger mode: prove the numbers add up without moving money.
      for (const item of due.slice(0, 10)) {
        this.log('info', `[ledger] would pay ${formatXmr(item.atomic)} XMR to ${item.address.slice(0, 12)}…`);
      }
      summary.skipped = due.length;

      return summary;
    }

    let unlocked;

    try {
      const balance = await this.balance();
      unlocked = balance.unlocked;
    } catch (error) {
      this.log('error', `cannot read the wallet balance: ${error.message}`);
      summary.failed = due.length;

      return summary;
    }

    let available = unlocked - this.reserve;

    for (const item of due) {
      const amount = BigInt(item.atomic);

      if (amount < this.minPayout) {
        summary.skipped += 1;
        continue;
      }

      if (amount > available) {
        // Not enough confirmed coins to cover this one. Stop: paying a smaller
        // amount than owed would silently change the ledger.
        this.log('warn', `wallet has ${formatXmr(available < 0n ? 0n : available)} XMR spendable, ${formatXmr(item.atomic)} needed for ${item.address.slice(0, 10)}…`);
        summary.skipped += due.length - summary.paid - summary.skipped;
        break;
      }

      try {
        const txid = await this.send(item.address, amount);
        ledger.markPaid(item.address, item.atomic, txid);
        available -= amount;
        summary.paid += 1;
        summary.txids.push(txid);
        this.log('info', `paid ${formatXmr(item.atomic)} XMR to ${item.address.slice(0, 12)}… tx ${txid}`);
      } catch (error) {
        // A failed transfer must not be retried in a loop: mark and move on, the
        // next round picks it up.
        this.log('error', `transfer to ${item.address.slice(0, 12)}… failed: ${error.message}`);
        summary.failed += 1;
        break;
      }
    }

    return summary;
  }
}

module.exports = { Wallet };
