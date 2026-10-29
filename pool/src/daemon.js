// monerod JSON-RPC: block templates in, solved blocks out.
//
// The pool never trusts a miner about the chain state: templates come from the
// daemon, and a block is only announced as "found" after submit_block says OK.

'use strict';

const { JobStore } = require('./jobs');

class Daemon {
  constructor(config, options = {}) {
    this.url = String(config.daemon || '').replace(/\/+$/, '');
    this.fallback = config.daemon_fallback || null;
    this.user = config.daemon_user || null;
    this.password = config.daemon_password || null;
    this.wallet = config.operator_address;
    this.log = options.logger || (() => {});
    this.lastError = null;
    this.height = 0;
    this.lastTemplateAt = 0;
    this.rpcId = 0;
  }

  authHeader() {
    if (!this.user) return {};

    const token = Buffer.from(`${this.user}:${this.password || ''}`).toString('base64');

    return { Authorization: `Basic ${token}` };
  }

  async call(method, params, timeoutMs = 8000) {
    const body = JSON.stringify({ jsonrpc: '2.0', id: String(++this.rpcId), method, params });
    const targets = [this.url, this.fallback].filter(Boolean);
    let lastError = null;

    for (const url of targets) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);

      try {
        const response = await fetch(`${url}/json_rpc`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', ...this.authHeader() },
          body,
          signal: controller.signal,
        });

        const text = await response.text();
        if (!response.ok) throw new Error(`HTTP ${response.status}: ${text.slice(0, 160)}`);

        const parsed = JSON.parse(text);
        if (parsed.error) throw new Error(parsed.error.message || JSON.stringify(parsed.error));

        this.lastError = null;
        return parsed.result;
      } catch (error) {
        lastError = error;
        if (url !== targets[targets.length - 1]) {
          this.log('warn', `daemon ${url} failed (${error.message}), trying the fallback`);
        }
      } finally {
        clearTimeout(timer);
      }
    }

    this.lastError = lastError ? lastError.message : 'no daemon configured';
    throw lastError || new Error('no daemon configured');
  }

  /** Returns a normalised template or throws. */
  async getTemplate(reserveSize = 18) {
    const result = await this.call('get_block_template', {
      wallet_address: this.wallet,
      reserve_size: reserveSize,
    });

    if (!result || !result.blockhashing_blob) {
      throw new Error('daemon returned no blockhashing_blob');
    }

    this.height = Number(result.height || 0);
    this.lastTemplateAt = Date.now();

    return {
      blob: result.blockhashing_blob,
      // The full blob is what gets submitted; keep it next to the job.
      fullBlob: result.blocktemplate_blob,
      height: Number(result.height || 0),
      seed_hash: result.seed_hash || '',
      next_seed_hash: result.next_seed_hash || '',
      difficulty: Number(result.difficulty || 0),
      reward_atomic: String(result.expected_reward || '0'),
      reward: String(result.expected_reward || '0'),
      algo: 'rx/0',
      nonce_offset: 39,
    };
  }

  async submitBlock(blockBlobHex) {
    const result = await this.call('submit_block', [blockBlobHex], 15000);

    return result || { status: 'OK' };
  }

  /** Pool height from the daemon, for the status page. */
  async getInfo() {
    return this.call('get_info', {}, 4000);
  }

  /** Templates for synthetic mode: no chain, deterministic jobs. */
  static syntheticTemplate(height) {
    return JobStore.synthetic(height);
  }
}

/** Polls the daemon and keeps the job store current. */
class TemplateFeeder {
  constructor({ config, daemon, jobs, logger }) {
    this.config = config;
    this.daemon = daemon;
    this.jobs = jobs;
    this.log = logger;
    this.timer = null;
    this.running = false;
    this.syntheticHeight = 1000;
    this.failures = 0;
    this.onTemplate = null;
  }

  start() {
    this.running = true;
    this.tick();

    return this;
  }

  stop() {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
  }

  async tick() {
    if (!this.running) return;

    try {
      let template;

      if (this.config.mode === 'synthetic') {
        this.syntheticHeight += 1;
        template = Daemon.syntheticTemplate(this.syntheticHeight);
      } else {
        template = await this.daemon.getTemplate();
      }

      const job = this.jobs.setTemplate(template);
      this.failures = 0;

      if (this.onTemplate) this.onTemplate(job);

      this.log('debug', `template height ${job.height} job ${job.id}`);
    } catch (error) {
      this.failures += 1;
      // Log the first failure and then every 20th: a daemon that is down
      // should not fill the journal with one line every five seconds.
      if (this.failures === 1 || this.failures % 20 === 0) {
        this.log('error', `cannot get a block template (${this.failures}x): ${error.message}`);
      }
    } finally {
      if (this.running) {
        // Back off while the daemon is unhappy, but never above 60 s.
        const delay = Math.min(Number(this.config.template_interval || 5) * 1000 * (1 + Math.floor(this.failures / 5)), 60000);
        this.timer = setTimeout(() => this.tick(), delay);
      }
    }
  }
}

module.exports = { Daemon, TemplateFeeder };
