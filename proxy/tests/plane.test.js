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
const { BLOB_PANTHERA, Rig, WALLET, ZERO_HASH, fakePool, sleep } = require('./helpers');
const { NetworkFeed } = require('../src/network');

/** A hash that clears the given difficulty (with a 100x margin), as hex. */
function hashUnder(difficulty) {
  const hash = Buffer.alloc(32);
  hash.writeBigUInt64LE((2n ** 64n) / (BigInt(Math.max(1, difficulty)) * 100n), 24);

  return hash.toString('hex');
}

/** Sends one share that the pool target accepts. */
async function submitAcceptedShare(rig, job, id) {
  rig.send({
    id,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: job.job_id, nonce: '01000001', result: hashUnder(1000) },
  });

  return rig.waitFor((m) => m.id === id);
}

/** Builds a proxy on a random port and returns the pieces. */
async function startProxy({ pools, downstreamOptions = {}, upstreamOptions = {} } = {}) {
  const upstream = new Upstream({ pools, user: WALLET, password: 'x', retryPauseMs: 50, maxRetryPauseMs: 200, ...upstreamOptions });
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

test('/status turns each rig\'s shares into H/s and XMR/day', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const network = new NetworkFeed({ difficulty: 3e11, reward: 0.6 });
  const proxy = await withProxy(t, {
    pools: [`127.0.0.1:${pool.port}`],
    downstreamOptions: { network },
  });

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);
  const reply = await submitAcceptedShare(rig, login.result.job, 2);
  assert.strictEqual(reply.result.status, 'OK');

  // Pin the window, or the estimate is dominated by however long the test took
  // to start: one share of difficulty 1000 in 60 s is 1000 * 2^32 / 60 H/s.
  for (const conn of proxy.downstream.connections) conn.connectedAt -= 60;

  const status = proxy.downstream.status();
  const rigStatus = status.connections[0];

  assert.ok(rigStatus.uptime >= 60, `uptime was ${rigStatus.uptime}`);
  assert.ok(Math.abs(rigStatus.hashrate - 71582788267) / 71582788267 < 0.01, `hashrate ${rigStatus.hashrate}`);
  assert.ok(rigStatus.sharesPerHour > 59 && rigStatus.sharesPerHour < 61, `shares/hour ${rigStatus.sharesPerHour}`);
  assert.ok(rigStatus.xmrPerDay > 0);

  // The fleet total is the same single rig, and the network figures are published
  // so an operator can see where the money column came from.
  assert.strictEqual(status.xmrPerDay, rigStatus.xmrPerDay);
  assert.strictEqual(status.hashrate, rigStatus.hashrate);
  assert.strictEqual(status.estimate.source, 'flag');
  assert.strictEqual(status.estimate.difficulty, 3e11);
});

test('/status refuses to price a rig when the network figure is unknown', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rig = await new Rig(proxy.port).connect();
  const login = await rig.login(`${WALLET}.rigA`);
  await submitAcceptedShare(rig, login.result.job, 2);

  const status = proxy.downstream.status();

  assert.strictEqual(status.estimate, null);
  assert.strictEqual(status.xmrPerDay, null);
  assert.ok(status.connections[0].hashrate > 0, 'hashrate is measurable without the network');
  assert.strictEqual(status.connections[0].xmrPerDay, null, 'money is not');
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

test('the proxy tells the pool which coins the farm can mine', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, {
    pools: [`127.0.0.1:${pool.port}`],
    upstreamOptions: { algos: ['rx/0', 'rx/wow', 'rx/arq', 'rx/graft', 'rx/sfx', 'rx/yada', 'panthera'] },
  });

  const rig = await new Rig(proxy.port).connect();
  t.after(() => rig.close());
  assert.ok((await rig.login(`${WALLET}.rigA`)).result.job);

  const login = pool.logins.find((message) => message.method === 'login');
  assert.deepStrictEqual(login.params.algo, ['rx/0', 'rx/wow', 'rx/arq', 'rx/graft', 'rx/sfx', 'rx/yada', 'panthera']);
});

test('a pool that switches the farm to panthera gets a nonce at offset 147', async (t) => {
  const pool = await withPool(t, { difficulty: 1000 });
  const proxy = await withProxy(t, { pools: [`127.0.0.1:${pool.port}`] });

  const rig = await new Rig(proxy.port).connect();
  t.after(() => rig.close());
  const first = await rig.login(`${WALLET}.rigA`);
  const prefix = Number.parseInt(first.result.job.blob.slice(39 * 2 + 6, 39 * 2 + 8), 16);
  assert.ok(prefix >= 1);

  // The pool moves to Scala. Writing the extranonce at 39 here would corrupt the
  // header and every share would come back rejected.
  pool.pushJob({ jobId: 'job-panthera', algo: 'panthera', blob: BLOB_PANTHERA, difficulty: 1000 });

  const job = await rig.waitFor((m) => m.method === 'job' && m.params.algo === 'panthera');
  assert.strictEqual(job.params.job_id.startsWith('p'), true, 'the rig gets a proxy-owned job id');

  const bytes = job.params.blob;
  const at147 = Number.parseInt(bytes.slice(147 * 2 + 6, 147 * 2 + 8), 16);
  const at39 = Number.parseInt(bytes.slice(39 * 2 + 6, 39 * 2 + 8), 16);

  assert.strictEqual(at147, prefix, 'the extranonce belongs at byte 150 of a panthera blob');
  assert.strictEqual(at39, 0, 'nothing may be written at the Monero offset');

  rig.send({
    id: 7,
    jsonrpc: '2.0',
    method: 'submit',
    params: { id: 'x', job_id: job.params.job_id, nonce: ((prefix << 24) | 9).toString(16).padStart(8, '0'), result: ZERO_HASH },
  });
  assert.strictEqual((await rig.waitFor((m) => m.id === 7)).result.status, 'OK');

  const forwarded = await (async () => {
    for (let i = 0; i < 200; i++) {
      if (pool.submits.length) return pool.submits[0];
      await sleep(10);
    }
    throw new Error('the panthera share never reached the pool');
  })();

  assert.strictEqual(forwarded.params.job_id, 'job-panthera');
  assert.strictEqual(forwarded.params.algo, 'panthera', 'the pool must be told which coin the share is for');
});
