// End-to-end tests of the data plane: real sockets, a fake pool on one side, a
// fake rig on the other, the proxy in the middle. Nothing is stubbed at the
// protocol level -- if a job does not reach a rig or a share does not reach the
// pool here, it will not in production either.
//
//   node --test proxy/tests/

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const net = require('node:net');

const { Upstream } = require('../src/upstream');
const { Downstream } = require('../src/downstream');
const { SocketConnection } = require('../src/conn');
const { difficultyFromTarget } = require('../../pool/src/target');
const { Rig, WALLET, ZERO_HASH, fakePool, sleep } = require('./helpers');

/** Builds a proxy on a random port and returns the pieces. */
async function startProxy({ pools, downstreamOptions = {} } = {}) {
  const upstream = new Upstream({ pools, user: WALLET, password: 'x', retryPauseMs: 50, maxRetryPauseMs: 200 });
  const downstream = new Downstream({ upstream, user: WALLET, ...downstreamOptions });
  const timer = setInterval(() => downstream.tick(), 20);
  timer.unref?.();

  const server = net.createServer((socket) => {
    downstream.attach(new SocketConnection(socket));
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));

  upstream.start();

  return {
    port: server.address().port,
    upstream,
    downstream,
    stop: async () => {
      clearInterval(timer);
      downstream.close();
      upstream.close();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

async function withProxy(t, options) {
  const proxy = await startProxy(options);
  t.after(() => proxy.stop());

  return proxy;
}

async function withPool(t, options) {
  const pool = await fakePool(options);
  t.after(() => pool.close());

  return pool;
}

test('one upstream connection serves two rigs with disjoint extranonce', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rigA = await new Rig(proxy.port).connect();
  const rigB = await new Rig(proxy.port).connect();

  const loginA = await rigA.login(`${WALLET}.rigA`);
  const loginB = await rigB.login(`${WALLET}.rigB`);

  assert.strictEqual(loginA.result.status, 'OK');
  assert.ok(loginA.result.job, 'a rig must get a job in the login reply');
  assert.ok(loginB.result.job);

  const prefixA = Number.parseInt(loginA.result.job.blob.slice(39 * 2 + 6, 39 * 2 + 8), 16);
  const prefixB = Number.parseInt(loginB.result.job.blob.slice(39 * 2 + 6, 39 * 2 + 8), 16);

  assert.notStrictEqual(prefixA, prefixB, 'two rigs must never share a nonce byte');
  assert.ok(prefixA >= 1 && prefixB >= 1, 'prefix 0 would turn extranonce off in the miner');

  // The pool must have seen exactly one login: that is the point of the proxy.
  const logins = pool.logins.filter((m) => m.method === 'login');
  assert.strictEqual(logins.length, 1, `pool saw ${logins.length} logins`);
  assert.strictEqual(logins[0].params.login, WALLET, 'the proxy logs in with its own wallet');

});

test('difficulty is read from the pool target in the right byte order', async (t) => {
  const pool = await withPool(t, { difficulty: 50_000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rig = await new Rig(proxy.port).connect();
  await rig.login(`${WALLET}.rigA`);

  const status = proxy.downstream.status();
  assert.ok(Math.abs(status.difficulty - 50_000) / 50_000 < 1e-4, `read ${status.difficulty} from the target`);
  assert.strictEqual(status.rigs, 1);

});

test('an accepted share is forwarded with the pool job id, not the proxy job id', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);

  const job = login.result.job;
  const prefix = Number.parseInt(job.blob.slice(39 * 2 + 6, 39 * 2 + 8), 16);

  rig.send({
    id: 2,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: job.job_id, nonce: ((prefix << 24) | 0x1234).toString(16).padStart(8, '0'), result: ZERO_HASH },
  });

  const reply = await rig.waitFor((m) => m.id === 2);
  assert.strictEqual(reply.result.status, 'OK');

  const submitted = await (async () => {
    for (let i = 0; i < 200; i++) {
      if (pool.submits.length) return pool.submits[0];
      await sleep(10);
    }
    throw new Error('the share never reached the pool');
  })();

  assert.strictEqual(submitted.params.job_id, 'job-1', 'the pool must receive its own job id');
  assert.notStrictEqual(job.job_id, 'job-1', 'the rig must have been given a proxy-owned job id');
  assert.strictEqual(proxy.downstream.status().forwarded, 1);

});

test('a share below the pool target is accepted locally and counted, not forwarded', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  // Local difficulty pinned low on purpose: this is the metered-link mode.
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`], downstreamOptions: { localFactor: 1 / 8 } });

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);
  const job = login.result.job;

  assert.ok(difficultyFromTarget(job.target) < 1000, 'the rig must be given the lower local difficulty');

  // A hash that clears 125 but not 1000: value 2^62 is above 2^64/125 but
  // below 2^64/1000. Write it little-endian into the last 8 bytes.
  const hash = Buffer.alloc(32);
  hash.writeBigUInt64LE((2n ** 64n) / 500n, 24);

  rig.send({
    id: 2,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: job.job_id, nonce: '01000001', result: hash.toString('hex') },
  });

  const reply = await rig.waitFor((m) => m.id === 2);
  assert.strictEqual(reply.result.status, 'OK', 'the rig did real work, it must not see a reject');

  await sleep(100);
  assert.strictEqual(pool.submits.length, 0, 'a share under the pool target must not be forwarded');
  const status = proxy.downstream.status();
  assert.strictEqual(status.absorbed, 1);
  assert.strictEqual(status.forwarded, 0);

});

test('rigs stay connected when the pool dies, and a new rig still gets the last job', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rigA = await new Rig(proxy.port).connect();
  const loginA = await rigA.login(`${WALLET}.rigA`);
  assert.ok(loginA.result.job);

  await pool.close();
  await sleep(200);

  assert.strictEqual(rigA.closed, false, 'the rig must not be dropped because the pool went away');
  assert.strictEqual(proxy.downstream.status().upstream.connected, false);

  // A rig retrying its login during the outage gets the last known job instead
  // of a reconnect loop: that is hashrate kept, not politeness.
  const rigB = await new Rig(proxy.port).connect();
  const loginB = await rigB.login(`${WALLET}.rigB`);
  assert.ok(loginB.result.job, 'the last job is replayed while the pool is down');

  // And a share during the outage is acknowledged, not silently lost.
  rigB.send({
    id: 2,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: loginB.result.job.job_id, nonce: '01000002', result: ZERO_HASH },
  });
  const reply = await rigB.waitFor((m) => m.id === 2);
  assert.strictEqual(reply.result.status, 'OK');
});

test('the proxy fails over to the second pool without touching the rigs', async (t) => {
  const dead = await withPool(t, { rejectLogin: true });
  const alive = await withPool(t, { difficulty: 2000, height: 3_600_000 });

  const proxy = await withProxy(t, { pools: [`127.0.0.1:${dead.port}`, `127.0.0.1:${alive.port}`] });

  // The pool refusal is what rotates the dial list; wait for it, then bring a
  // rig -- it should see nothing but a working pool.
  const started = Date.now();
  while (Date.now() - started < 6000) {
    if (proxy.upstream.snapshot().pool.endsWith(`:${alive.port}`)) break;
    await sleep(20);
  }

  const waitForConnected = async () => {
    const deadline = Date.now() + 6000;
    while (Date.now() < deadline) {
      const snapshot = proxy.downstream.status();
      if (snapshot.upstream.pool.endsWith(`:${alive.port}`) && snapshot.upstream.connected) return snapshot;
      await sleep(20);
    }
    throw new Error(`never connected: ${JSON.stringify(proxy.downstream.status().upstream)}`);
  };

  const status = await waitForConnected();
  assert.match(status.upstream.pool, new RegExp(`:${alive.port}$`), 'failover must reach the second pool');

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);
  assert.ok(login.result?.job, 'the rig must get a job from the pool that answered');
});

test('a rig that ignores its extranonce is reported once, and its shares still count', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const warnings = [];
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });
  proxy.downstream.log = (level, message) => { if (level === 'warn') warnings.push(message); };

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);
  const job = login.result.job;

  for (const id of [2, 3]) {
    rig.send({
      id,
      jsonrpc: '2.0',
      method: 'submit',
      params: { id: 'x', job_id: job.job_id, nonce: `ff0000${id}`.padStart(8, '0'), result: ZERO_HASH },
    });
    await rig.waitFor((m) => m.id === id);
  }

  await sleep(100);
  const status = proxy.downstream.status();
  assert.strictEqual(status.prefixIgnored, 2);
  assert.strictEqual(status.accepted, 2);
  assert.strictEqual(warnings.filter((w) => w.includes('extranonce')).length, 1, 'one warning, not a flood');

});

test('vardiff hands a fast rig a harder target and a slow rig an easier one', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const fast = await new Rig(proxy.port).connect();
  const slow = await new Rig(proxy.port).connect();
  await fast.login(`${WALLET}.fast`);
  await slow.login(`${WALLET}.slow`);

  const { downstream } = proxy;
  const fastConn = [...downstream.connections].find((c) => c.worker === 'fast');
  const slowConn = [...downstream.connections].find((c) => c.worker === 'slow');

  // The fast rig submitted four shares in the window, the slow rig none.
  const now = Math.floor(Date.now() / 1000);
  for (let i = 0; i < 4; i++) fastConn.vardiff.record(now, true);
  fastConn.vardiff.startedAt = now - 30;
  fastConn.vardiff.lastAdjust = now - 31;
  slowConn.vardiff.startedAt = now - 30;
  slowConn.vardiff.lastAdjust = now - 31;

  const fastAfter = fastConn.vardiff.poll(now);
  const slowAfter = slowConn.vardiff.poll(now);

  assert.ok(fastAfter !== null, 'the fast rig must be re-targeted');
  assert.ok(fastAfter > 1000, `fast rig went to ${fastAfter}, expected harder than 1000`);
  assert.ok(slowAfter !== null, 'the slow rig must be re-targeted');
  assert.ok(slowAfter < 1000, `slow rig went to ${slowAfter}, expected easier than 1000`);

});
