// The whole program, as an operator runs it: a child process, real flags, a
// real pool, real rigs over TCP and over WebSocket, and the status endpoint.
//
// Unit tests can all pass while `zmrig-proxy start` fails on the first line of
// its own banner, so this file exists.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const { Rig, WALLET, WsRig, ZERO_HASH, fakePool, sleep } = require('./helpers');

const ENTRY = path.join(__dirname, '..', 'src', 'main.js');
const TOKEN = 'sekrit-token';

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

function run(argv, options = {}) {
  const child = spawn(process.execPath, [ENTRY, ...argv], { stdio: ['ignore', 'pipe', 'pipe'] });
  const output = { stdout: '', stderr: '' };

  child.stdout.on('data', (chunk) => { output.stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { output.stderr += chunk.toString('utf8'); });

  return { child, output, waitForOutput: (pattern, timeout = 10_000) => waitFor(child, output, pattern, timeout, options) };
}

function waitFor(child, output, pattern, timeout, options) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const timer = setInterval(() => {
      const text = `${output.stdout}${output.stderr}`;
      if (pattern.test(text)) {
        clearInterval(timer);
        resolve(text);
      } else if (child.exitCode !== null) {
        clearInterval(timer);
        reject(new Error(`exited ${child.exitCode}:\n${text}`));
      } else if (Date.now() - started > timeout) {
        clearInterval(timer);
        reject(new Error(`timed out waiting for ${pattern}:\n${text}`));
      }
    }, 20);
    timer.unref?.();
    if (options.debug) process.stderr.write('');
  });
}

function fetchJson(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.get({ host: '127.0.0.1', port, path, headers, timeout: 4000 }, (response) => {
      let text = '';
      response.on('data', (chunk) => { text += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, body: text }));
    });
    request.on('error', reject);
    request.on('timeout', () => { request.destroy(new Error('timeout')); });
  });
}

test('one command starts a proxy that serves rigs over TCP and WebSocket', async (t) => {
  const pool = await fakePool({ difficulty: 4000 });
  const [port, wsPort, statusPort] = await Promise.all([freePort(), freePort(), freePort()]);

  const proxy = run([
    'start',
    `--user=${WALLET}`,
    `--pool=127.0.0.1:${pool.port}`,
    `--port=${port}`,
    '--ws',
    `--ws-port=${wsPort}`,
    `--status-port=${statusPort}`,
    `--token=${TOKEN}`,
    '--log-level=info',
  ]);

  t.after(async () => {
    proxy.child.kill('SIGTERM');
    await pool.close();
    await sleep(100);
  });

  // Wait for the last line of the banner, not the first: the rig commands are
  // printed after the listening line, and asserting on a half-written banner is
  // a test that fails one run in eight.
  const banner = await proxy.waitForOutput(/Status: http:/);
  assert.match(banner, new RegExp(`stratum listening on 127\\.0\\.0\\.1:${port}`));
  assert.match(banner, /zmrig --pool=stratum\+tcp:\/\//, 'the banner must print a command a rig can run');

  // --- TCP rig, correct token
  const rig = await new Rig(port).connect();
  const login = await rig.login(`${WALLET}.rigA`, TOKEN);
  assert.strictEqual(login.result.status, 'OK');
  assert.ok(login.result.job, 'a rig must receive a job');

  rig.send({
    id: 2,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: login.result.job.job_id, nonce: '01000001', result: ZERO_HASH },
  });
  assert.strictEqual((await rig.waitFor((m) => m.id === 2)).result.status, 'OK');

  // --- TCP rig, wrong token
  const intruder = await new Rig(port).connect();
  const refused = await intruder.login(`${WALLET}.rigB`, 'guess');
  assert.match(JSON.stringify(refused.error), /token/);

  // --- WebSocket rig
  const wsRig = await new WsRig(wsPort).connect();
  const wsLogin = await wsRig.login(`${WALLET}.rigC`, TOKEN);
  assert.strictEqual(wsLogin.result.status, 'OK', 'the WebSocket path must serve a job');
  assert.ok(wsLogin.result.job);

  // --- status endpoint
  const unauthorised = await fetchJson(statusPort, '/status');
  assert.strictEqual(unauthorised.status, 401, 'the status page must not answer without the token');

  const status = await fetchJson(statusPort, '/status', { authorization: `Bearer ${TOKEN}` });
  assert.strictEqual(status.status, 200);
  const parsed = JSON.parse(status.body);

  assert.ok(parsed.rigs >= 2, `expected at least two rigs, got ${parsed.rigs}`);
  assert.strictEqual(parsed.forwarded >= 1, true);
  assert.strictEqual(parsed.upstream.connected, true);
  assert.ok(Math.abs(parsed.difficulty - 4000) / 4000 < 1e-4, `difficulty read as ${parsed.difficulty}`);
  assert.ok(parsed.wallet.startsWith(WALLET.slice(0, 8)));

  const prefixes = parsed.connections.map((connection) => connection.prefix);
  assert.strictEqual(new Set(prefixes).size, prefixes.length, 'each rig must have its own nonce byte');
  assert.ok(prefixes.every((prefix) => prefix >= 1 && prefix <= 255));

  wsRig.close();
  rig.close();
  intruder.close();
});

test('SIGTERM shuts the proxy down without leaving a listener behind', async (t) => {
  const pool = await fakePool();
  const [port, statusPort] = await Promise.all([freePort(), freePort()]);

  const proxy = run([
    'start',
    `--user=${WALLET}`,
    `--pool=127.0.0.1:${pool.port}`,
    `--port=${port}`,
    `--status-port=${statusPort}`,
    '--log-level=info',
  ]);

  t.after(() => pool.close());

  await proxy.waitForOutput(/stratum listening/);

  const exited = new Promise((resolve) => proxy.child.on('exit', (code, signal) => resolve({ code, signal })));
  proxy.child.kill('SIGTERM');
  const result = await exited;

  assert.strictEqual(result.code, 0, 'a clean shutdown exits 0');

  // The port must be free again: a second start on the same port has to work.
  const again = net.createServer();
  await new Promise((resolve, reject) => {
    again.once('error', reject);
    again.listen(port, '127.0.0.1', resolve);
  });
  await new Promise((resolve) => again.close(resolve));
});

test('a bad flag exits 2 and says which flag', async () => {
  const bad = run(['start', `--pool=127.0.0.1:1`, '--bind=0.0.0.0']);
  const exit = await new Promise((resolve) => bad.child.on('exit', (code) => resolve(code)));

  assert.strictEqual(exit, 2);
  assert.match(bad.output.stderr, /exposes the proxy/);
});

test('doctor reports the pool, the difficulty and the latency', async (t) => {
  const pool = await fakePool({ difficulty: 2500 });
  t.after(() => pool.close());

  const doctor = run(['doctor', `--user=${WALLET}`, `--pool=127.0.0.1:${pool.port}`]);
  const text = await doctor.waitForOutput(/checks passed/, 20_000);
  doctor.child.kill('SIGTERM');

  assert.match(text, new RegExp(`pool 127\\.0\\.0\\.1:${pool.port} answered`));
  assert.match(text, /job difficulty -- 2500/);
  assert.match(text, /block height/);
  assert.match(text, /5 kH\/s rig would find/);
});
