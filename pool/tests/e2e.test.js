// End-to-end: a real miner against a real pool process.
//
//   zmrig ---TCP--->   pool  ---> verifier (zmrig --verify-share) ---> ledger
//              |
//              +------WebSocket------>  the same pool, second path
//
// Plus the case that matters for trust: a miner that submits a hash it never
// computed must be rejected, not paid.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const MINER = process.env.ZMRIG_BINARY || path.join(ROOT, 'zmrig', 'out', 'zmrig');
const POOL_ENTRY = path.join(ROOT, 'pool', 'src', 'index.js');
const MINER_ADDRESS = '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge';

const haveMiner = fs.existsSync(MINER);

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function waitForLine(child, pattern, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${pattern}\n${buffer.slice(-800)}`)), timeoutMs);

    const onData = (chunk) => {
      buffer += chunk.toString();
      if (pattern.test(buffer)) {
        clearTimeout(timer);
        child.stdout.off('data', onData);
        resolve(buffer);
      }
    };

    child.stdout.on('data', onData);
    child.on('exit', () => {
      clearTimeout(timer);
      reject(new Error(`pool exited early\n${buffer}`));
    });
  });
}

async function startPool(extraEnv = {}) {
  const port = await freePort();
  const httpPort = await freePort();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ocean-pool-e2e-'));

  const child = spawn(process.execPath, [POOL_ENTRY, '--config', path.join(ROOT, 'pool', 'config.example.json')], {
    env: {
      ...process.env,
      POOL_MODE: 'synthetic',
      PORT: String(port),
      HTTP_PORT: String(httpPort),
      BIND: '127.0.0.1',
      INITIAL_DIFFICULTY: '50',
      MIN_DIFFICULTY: '1',
      VARDIFF: 'false',
      STATE_FILE: path.join(dir, 'state.json'),
      AUDIT_FILE: path.join(dir, 'audit.jsonl'),
      LOG_LEVEL: 'info',
      VERIFIER_BINARY: MINER,
      ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  child.stderr.on('data', (chunk) => { output += chunk.toString(); });
  child.stdout.on('data', (chunk) => { output += chunk.toString(); });

  try {
    await waitForLine(child, /pool ready/);
  } catch (error) {
    child.kill('SIGKILL');
    throw new Error(`${error.message}\noutput: ${output}`);
  }

  return {
    child,
    port,
    httpPort,
    dir,
    output: () => output,
    stop() {
      // Idempotent: a second call must not wait for an exit that already
      // happened (the test runner would cancel it as a hung promise).
      if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(child.exitCode);

      return new Promise((resolve) => {
        child.once('exit', (code) => resolve(code));
        child.kill('SIGTERM');
        setTimeout(() => { child.kill('SIGKILL'); resolve(null); }, 8000).unref();
      });
    },
  };
}

function startMiner(args) {
  return spawn(MINER, args, { stdio: ['ignore', 'pipe', 'pipe'] });
}

function stopMiner(child) {
  return new Promise((resolve) => {
    child.once('exit', resolve);
    child.kill('SIGTERM');
    setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000).unref();
  });
}

function collect(child) {
  const chunks = [];
  child.stdout.on('data', (chunk) => chunks.push(chunk.toString()));
  child.stderr.on('data', (chunk) => chunks.push(chunk.toString()));

  return () => chunks.join('');
}

async function getJson(port, route) {
  const response = await fetch(`http://127.0.0.1:${port}${route}`);
  return response.json();
}

test('miner over TCP: login, shares accepted, ledger credited', { skip: !haveMiner, timeout: 90000 }, async () => {
  const pool = await startPool();

  try {
    const miner = startMiner([
      '-o', `127.0.0.1:${pool.port}`,
      '-u', `${MINER_ADDRESS}.e2e`,
      '-t', '1',
      '--mode', 'light',
      '--no-color',
      '--print-time', '5',
    ]);
    const output = collect(miner);

    // Wait for the first accepted share rather than a fixed sleep.
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no accepted share in 45 s\n${output().slice(-1200)}`)), 45000);
      const interval = setInterval(() => {
        if (/share accepted/.test(output())) {
          clearTimeout(timer);
          clearInterval(interval);
          resolve();
        }
      }, 250);
    });

    await stopMiner(miner);
    const log = output();

    assert.match(log, /login ok/, 'miner logged in');
    assert.match(log, /share accepted/, 'at least one share accepted');
    assert.doesNotMatch(log, /share rejected/, 'no share rejected');

    const stats = await getJson(pool.httpPort, '/api/stats');
    assert.ok(stats.pool.accepted >= 1, 'pool counted the share');
    assert.strictEqual(stats.pool.rejected, 0);
    assert.ok(stats.pool.verifier.verified >= 1, 'the share was re-hashed by the pool');
    assert.strictEqual(stats.ledger.feePercent, 1);

    const worker = await getJson(pool.httpPort, `/api/worker/${MINER_ADDRESS}`);
    assert.strictEqual(worker.address, MINER_ADDRESS);
    assert.ok(Number(worker.shares) >= 1, 'shares recorded against the address');

    // Shutting down with a verifier child alive used to throw EPIPE into the
    // uncaught handler. The pool must exit cleanly instead.
    const code = await pool.stop();
    assert.strictEqual(code, 0, 'clean exit on SIGTERM');
    assert.doesNotMatch(pool.output(), /uncaught/, pool.output().slice(-600));
  } finally {
    await pool.stop();
  }
});

test('miner over WebSocket: the same pool through the Cloudflare path', { skip: !haveMiner, timeout: 90000 }, async () => {
  const pool = await startPool();

  try {
    const miner = startMiner([
      '-o', `ws://127.0.0.1:${pool.httpPort}/stratum`,
      '-u', `${MINER_ADDRESS}.wss`,
      '-t', '1',
      '--mode', 'light',
      '--no-color',
    ]);
    const output = collect(miner);

    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no accepted share over ws in 45 s\n${output().slice(-1200)}`)), 45000);
      const interval = setInterval(() => {
        if (/share accepted/.test(output())) {
          clearTimeout(timer);
          clearInterval(interval);
          resolve();
        }
      }, 250);
    });

    await stopMiner(miner);
    assert.match(output(), /login ok/);
    assert.match(output(), /share accepted/);

    const stats = await getJson(pool.httpPort, '/api/stats');
    assert.ok(stats.pool.accepted >= 1);
  } finally {
    await pool.stop();
  }
});

test('a forged share is rejected and the connection dropped', { skip: !haveMiner, timeout: 60000 }, async () => {
  const pool = await startPool();

  try {
    const socket = net.connect(pool.port, '127.0.0.1');
    let buffer = '';
    const messages = [];

    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        try { messages.push(JSON.parse(line)); } catch (_) {}
      }
    });

    await new Promise((resolve) => socket.once('connect', resolve));

    socket.write(`${JSON.stringify({
      id: 1,
      jsonrpc: '2.0',
      method: 'login',
      params: { login: `${MINER_ADDRESS}.forger`, pass: 'x', agent: 'forger/1.0' },
    })}\n`);

    // Wait for the login reply with a job.
    const login = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('no login reply')), 10000);
      const interval = setInterval(() => {
        const reply = messages.find((m) => m.id === 1);
        if (reply) {
          clearTimeout(timer);
          clearInterval(interval);
          resolve(reply);
        }
      }, 50);
    });

    assert.ok(login.result && login.result.job, 'got a job');
    assert.strictEqual(login.result.fee, 1, 'the pool publishes its fee in the login reply');

    // Submit a hash of all zeroes: it would pass any difficulty check, so only
    // re-hashing on the pool side can catch it.
    socket.write(`${JSON.stringify({
      id: 2,
      jsonrpc: '2.0',
      method: 'submit',
      params: {
        id: '1',
        job_id: login.result.job.job_id,
        nonce: '00000000',
        result: '00'.repeat(32),
        algo: 'rx/0',
        height: login.result.job.height,
      },
    })}\n`);

    const verdict = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('no submit reply')), 15000);
      const interval = setInterval(() => {
        const reply = messages.find((m) => m.id === 2);
        if (reply) {
          clearTimeout(timer);
          clearInterval(interval);
          resolve(reply);
        }
      }, 50);
    });

    assert.ok(verdict.error, 'forged share rejected');
    assert.match(String(verdict.error.message), /result does not match/i);

    const stats = await getJson(pool.httpPort, '/api/stats');
    assert.strictEqual(stats.pool.accepted, 0, 'nothing was credited');
    assert.ok(stats.pool.badShares >= 1, 'counted as a bad share');

    socket.destroy();
  } finally {
    await pool.stop();
  }
});
