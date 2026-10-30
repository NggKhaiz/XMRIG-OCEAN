// The pool side of the proxy: what a miner would do, done once for all rigs.
//
// Deliberately the same protocol a miner speaks (login / job / submit /
// keepalived) so any pool works, including this repository's own pool at
// `pool/` and a P2Pool node's stratum port.
//
// The two behaviours that matter for income:
//
//   * reconnect without dropping the rigs. When the pool connection dies, the
//     downstream miners stay connected to the proxy and keep their sockets;
//     they are simply not given new jobs until the pool is back. A rig that
//     reconnects on its own loses 15-30 s of hashrate to the dataset check, ten
//     rigs do it ten times.
//   * failover across a list of pools, with the *same* login (the wallet), so a
//     dead pool costs a share of a minute instead of an evening.

'use strict';

const net = require('node:net');
const tls = require('node:tls');
const { EventEmitter } = require('node:events');

const KEEPALIVE_MS = 60_000;

class Upstream extends EventEmitter {
  /**
   * @param {object} options
   * @param {string[]} options.pools   "host:port", "tls://host:port"
   * @param {string} options.user      wallet (or wallet.worker)
   * @param {string} options.password  pool password
   * @param {string} options.agent     user agent reported to the pool
   */
  constructor(options = {}) {
    super();

    this.pools = (options.pools || []).filter(Boolean).map(parsePool);
    this.user = options.user || '';
    this.password = options.password || 'x';
    this.agent = options.agent || 'ocean-proxy/1.0';
    // What the pool may switch this proxy between. Every rig behind it runs a
    // miner that implements the whole RandomX family, so by default the pool is
    // told the truth: it can move the farm to whatever pays best per hash.
    this.algos = Array.isArray(options.algos) ? options.algos.filter(Boolean) : [];
    this.rigId = options.rigId || null;
    this.log = options.logger || (() => {});
    this.keepaliveMs = Number(options.keepaliveMs || KEEPALIVE_MS);
    this.retryPauseMs = Number(options.retryPauseMs || 5000);
    this.maxRetryPauseMs = Number(options.maxRetryPauseMs || 60_000);

    this.socket = null;
    this.buffer = '';
    this.poolIndex = 0;
    this.attempt = 0;
    this.closed = false;
    this.loggedIn = false;
    this.job = null;            // the raw job object, as the pool sent it
    this.difficulty = null;
    this.sessionId = null;
    this.nextId = 1;
    this.loginId = null;
    this.pending = new Map();   // request id -> { resolve, reject, timer }
    this.keepalive = null;
    this.reconnectTimer = null;
    this.stats = {
      connects: 0,
      disconnects: 0,
      jobs: 0,
      submitted: 0,
      accepted: 0,
      rejected: 0,
      stale: 0,
      lastError: null,
      lastJobAt: 0,
    };
  }

  get connected() {
    return Boolean(this.socket && this.loggedIn);
  }

  start() {
    this.closed = false;
    this.connect();

    return this;
  }

  connect() {
    if (this.closed) return;
    if (!this.pools.length) {
      this.emit('fatal', new Error('no upstream pool configured'));

      return;
    }

    const pool = this.pools[this.poolIndex % this.pools.length];
    this.log('info', `connecting upstream to ${pool.tls ? 'tls://' : 'tcp://'}${pool.host}:${pool.port}`);

    const onConnect = () => {
      this.attempt = 0;
      this.stats.connects += 1;
      this.log('info', `upstream connected to ${pool.host}:${pool.port}`);
      this.sendLogin();
    };

    try {
      this.socket = pool.tls
        ? tls.connect({ host: pool.host, port: pool.port, servername: pool.host }, onConnect)
        : net.connect({ host: pool.host, port: pool.port }, onConnect);
    } catch (error) {
      this.onError(error);
      return;
    }

    this.socket.setNoDelay(true);
    this.socket.setKeepAlive(true, 30_000);
    this.socket.on('data', (chunk) => this.onData(chunk));
    this.socket.on('error', (error) => this.onError(error));
    this.socket.on('close', () => this.onClose());
  }

  onData(chunk) {
    this.buffer += chunk.toString('utf8');

    // A pool that never sends a newline is not speaking stratum; do not let it
    // grow this string without bound.
    if (this.buffer.length > 1024 * 1024) {
      this.log('warn', 'upstream sent 1 MiB without a newline, dropping it');
      this.drop('protocol');
      return;
    }

    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).replace(/\r$/, '');
      this.buffer = this.buffer.slice(index + 1);
      if (line.trim()) this.onLine(line);
    }
  }

  onLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      this.log('debug', `upstream sent non-JSON: ${line.slice(0, 80)}`);
      return;
    }

    // A response to something we asked.
    if (message.id !== undefined && message.id !== null && this.pending.has(message.id)) {
      const waiter = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    }

    // A pool that answers the login with an error usually keeps the socket
    // open. Waiting for it to close means the proxy sits on a dead pool
    // forever while every rig is idle, so a refusal goes straight to failover.
    if (this.loginId !== null && message.id === this.loginId && message.error && !this.loggedIn) {
      this.loginId = null;
      this.onLoginError(message.error);

      return;
    }

    if (typeof message.method !== 'string') {
      // Login reply: the first response carrying a job and a status.
      if (!this.loggedIn && message.result && message.result.job) {
        this.onLoginReply(message);
      } else if (message.error) {
        this.log('debug', `upstream error: ${JSON.stringify(message.error).slice(0, 120)}`);
      }

      return;
    }

    if (message.method === 'job') {
      this.onJob(message.params || {});
      return;
    }

    if (message.method === 'client.reconnect') {
      this.log('warn', 'pool asked for a reconnect');
      this.drop('client.reconnect');
    }
  }

  onLoginReply(message) {
    const result = message.result;
    this.loggedIn = true;
    this.loginId = null;
    this.sessionId = result.id ?? null;

    if (result.job) this.onJob(result.job);

    this.log('info', `upstream login ok (session ${this.sessionId ?? '?'}, difficulty ${this.difficulty ?? '?'})`);
    this.emit('login', result);
  }

  onJob(job) {
    this.job = job;
    this.stats.jobs += 1;
    this.stats.lastJobAt = Date.now();

    // The difficulty lives in the target, not in a separate field.
    this.emit('job', job);

    // Keep the session alive: some pools drop a silent connection and only the
    // keepalived reply proves both ends are still there.
    this.startKeepalive();
  }

  sendLogin() {
    const params = {
      login: this.user,
      pass: this.password,
      agent: this.agent,
    };
    if (this.rigId) params.rigid = this.rigId;
    if (this.algos.length) params.algo = this.algos;

    this.loginId = this.nextId++;
    this.write({ id: this.loginId, jsonrpc: '2.0', method: 'login', params });
  }

  /** The pool refused the credentials. Rotate: a stale pool, a changed
   *  password or an IP ban all look the same from here. */
  onLoginError(error) {
    const reason = error?.message || JSON.stringify(error);
    this.stats.lastError = reason;
    this.log('warn', `pool refused the login: ${reason}`);

    this.poolIndex += 1;
    this.attempt = 0;
    this.drop('login rejected');
  }

  /** Sends a share upstream. Resolves with true when the pool accepted it. */
  submit({ jobId, nonce, result, algo, height }) {
    const id = this.nextId++;

    const params = {
      id: this.user,
      job_id: jobId,
      nonce,
      result,
    };
    if (algo) params.algo = algo;
    if (height) params.height = height;

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.stats.rejected += 1;
        resolve({ ok: false, reason: 'timeout' });
      }, 30_000);
      timer.unref?.();

      this.pending.set(id, {
        timer,
        resolve: (message) => {
          if (message.error) {
            const reason = message.error.message || JSON.stringify(message.error);
            this.stats.rejected += 1;
            if (/stale|job not found|expired/i.test(reason)) this.stats.stale += 1;
            resolve({ ok: false, reason });
            return;
          }

          this.stats.accepted += 1;
          resolve({ ok: true });
        },
      });

      this.stats.submitted += 1;
      this.write({ id, jsonrpc: '2.0', method: 'submit', params });
    });
  }

  startKeepalive() {
    if (this.keepalive) return;

    this.keepalive = setInterval(() => {
      if (!this.connected) return;
      this.write({ id: this.nextId++, jsonrpc: '2.0', method: 'keepalived', params: { id: this.sessionId } });
    }, this.keepaliveMs);
    this.keepalive.unref?.();
  }

  write(object) {
    if (!this.socket || this.socket.destroyed) return false;

    try {
      this.socket.write(`${JSON.stringify(object)}\n`);

      return true;
    } catch (error) {
      this.onError(error);

      return false;
    }
  }

  /** Closes the socket; the reconnect loop takes over unless `closed`. */
  drop(reason) {
    if (!this.socket) return;

    this.log('warn', `upstream connection dropped (${reason})`);
    this.stats.disconnects += 1;

    try { this.socket.destroy(); } catch (_) {}
  }

  onError(error) {
    this.stats.lastError = error.message;

    // ECONNREFUSED on the first try is the normal "pool is down" case; the log
    // line that matters is the reconnect, not the error.
    this.log('debug', `upstream error: ${error.message}`);
  }

  onClose() {
    const wasLoggedIn = this.loggedIn;

    this.socket = null;
    this.loggedIn = false;
    this.loginId = null;
    this.buffer = '';

    for (const [, waiter] of this.pending) {
      clearTimeout(waiter.timer);
      waiter.resolve({ error: { message: 'connection closed' } });
    }
    this.pending.clear();

    if (this.closed) return;

    // A pool that accepted the login and then died is worth retrying at once;
    // one that never answered gets an exponential pause.
    this.attempt = wasLoggedIn ? 0 : this.attempt + 1;
    const pause = Math.min(this.retryPauseMs * 2 ** Math.min(this.attempt, 4), this.maxRetryPauseMs);

    if (!wasLoggedIn && this.attempt >= 3) {
      this.poolIndex += 1;
      this.log('warn', `upstream failing, moving to the next pool (${this.pools[this.poolIndex % this.pools.length].host})`);
    }

    this.emit('down');
    this.reconnectTimer = setTimeout(() => this.connect(), pause);
    this.reconnectTimer.unref?.();
  }

  close() {
    this.closed = true;

    if (this.keepalive) clearInterval(this.keepalive);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.keepalive = null;
    this.reconnectTimer = null;

    try { this.socket?.destroy(); } catch (_) {}
    this.socket = null;
    this.loggedIn = false;
  }

  snapshot() {
    const pool = this.pools.length ? this.pools[this.poolIndex % this.pools.length] : null;

    return {
      connected: this.connected,
      pool: pool ? `${pool.tls ? 'tls://' : 'tcp://'}${pool.host}:${pool.port}` : null,
      pools: this.pools.map((p) => `${p.tls ? 'tls://' : 'tcp://'}${p.host}:${p.port}`),
      difficulty: this.difficulty,
      height: this.job?.height ?? null,
      ...this.stats,
    };
  }
}

function parsePool(text) {
  const value = String(text).trim();
  const tls = /^(tls|ssl|stratum\+ssl):\/\//.test(value);
  const hostPort = value.replace(/^[a-z+]+:\/\//i, '');
  const lastColon = hostPort.lastIndexOf(':');
  const host = lastColon > 0 ? hostPort.slice(0, lastColon) : hostPort;
  const port = lastColon > 0 ? Number(hostPort.slice(lastColon + 1)) : 3333;

  return { host, port: Number.isFinite(port) ? port : 3333, tls };
}

module.exports = { Upstream, parsePool };
