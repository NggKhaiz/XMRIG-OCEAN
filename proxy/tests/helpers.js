// Shared fixtures: a fake pool, a fake rig over TCP, and a fake rig over
// WebSocket. Written by hand rather than with a library so the tests can be run
// with `node --test` and nothing installed -- the same constraint the proxy
// itself has.

'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const net = require('node:net');

const { targetHex } = require('../../pool/src/target');

const WALLET = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
// 76 bytes: 3 version + 36 (timestamp + prev hash) + 4 nonce at offset 39 + 33
const BLOB = '0c0c0c' + 'ab'.repeat(36) + '00000000' + 'cd'.repeat(33);
// Scala/Panthera: the nonce lives at offset 147, not 39.
const BLOB_PANTHERA = 'ab'.repeat(39) + '00000000' + 'ab'.repeat(104) + '00000000' + 'cd'.repeat(20);
const ZERO_HASH = '00'.repeat(32);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function jobFor(state) {
  return {
    job_id: state.jobId,
    blob: state.blob || BLOB,
    target: targetHex(state.difficulty),
    height: state.height,
    seed_hash: 'aa'.repeat(32),
    next_seed_hash: 'bb'.repeat(32),
    algo: state.algo || 'rx/0',
  };
}

/** A pool that answers login with a job and records what it was sent. */
function fakePool(options = {}) {
  const state = {
    logins: [],
    submits: [],
    sockets: new Set(),
    difficulty: options.difficulty || 1000,
    algo: options.algo || 'rx/0',
    blob: options.blob || BLOB,
    height: options.height || 3_500_000,
    jobId: 'job-1',
  };

  const server = net.createServer((socket) => {
    state.sockets.add(socket);
    socket.setNoDelay(true);
    socket.on('close', () => state.sockets.delete(socket));
    socket.on('error', () => {});

    let buffer = '';
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');

      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line.trim()) continue;

        const message = JSON.parse(line);
        state.logins.push(message);

        if (message.method === 'login') {
          if (options.rejectLogin) {
            socket.write(`${JSON.stringify({ id: message.id, jsonrpc: '2.0', error: { code: -1, message: 'nope' }, result: null })}\n`);
            continue;
          }

          socket.write(`${JSON.stringify({
            id: message.id,
            jsonrpc: '2.0',
            error: null,
            result: { id: 'session-1', job: jobFor(state), status: 'OK' },
          })}\n`);
          continue;
        }

        if (message.method === 'submit') {
          state.submits.push(message);
          socket.write(`${JSON.stringify({ id: message.id, jsonrpc: '2.0', error: null, result: { status: 'OK' } })}\n`);
        }
      }
    });
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      state.port = server.address().port;
      state.close = () => new Promise((done) => {
        for (const socket of state.sockets) socket.destroy();
        server.close(done);
      });
      state.pushJob = (patch = {}) => {
        Object.assign(state, patch);
        for (const socket of state.sockets) {
          socket.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'job', params: jobFor(state) })}\n`);
        }
      };
      resolve(state);
    });
  });
}

/** A rig speaking stratum over TCP. */
class Rig {
  constructor(port) {
    this.port = port;
    this.messages = [];
    this.buffer = '';
    this.closed = false;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.connect({ host: '127.0.0.1', port: this.port }, () => resolve(this));
      this.socket.setNoDelay(true);
      this.socket.on('close', () => { this.closed = true; });
      this.socket.on('data', (chunk) => {
        this.buffer += chunk.toString('utf8');
        let index;
        while ((index = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, index);
          this.buffer = this.buffer.slice(index + 1);
          if (line.trim()) this.messages.push(JSON.parse(line));
        }
      });
      this.socket.on('error', reject);
    });
  }

  send(object) {
    this.socket.write(`${JSON.stringify(object)}\n`);
  }

  async login(login = `${WALLET}.rig1`, pass = 'x') {
    this.send({ id: 1, jsonrpc: '2.0', method: 'login', params: { login, pass, agent: 'test-rig/1.0' } });

    return this.waitFor((m) => m.id === 1);
  }

  async waitFor(predicate, timeout = 4000) {
    const started = Date.now();
    while (Date.now() - started < timeout) {
      const found = this.messages.find(predicate);
      if (found) return found;
      await sleep(5);
    }
    throw new Error(`timed out; got ${JSON.stringify(this.messages).slice(0, 400)}`);
  }

  close() {
    this.socket.destroy();
  }
}

/** A rig speaking stratum over WebSocket. The handshake and the masked frames
 *  are written out by hand so the server's framing is genuinely exercised. */
class WsRig {
  constructor(port, path = '/stratum') {
    this.port = port;
    this.path = path;
    this.messages = [];
    this.buffer = Buffer.alloc(0);
  }

  connect() {
    return new Promise((resolve, reject) => {
      const request = http.request({
        host: '127.0.0.1',
        port: this.port,
        path: this.path,
        headers: {
          connection: 'Upgrade',
          upgrade: 'websocket',
          'sec-websocket-key': crypto.randomBytes(16).toString('base64'),
          'sec-websocket-version': '13',
        },
      });

      request.on('upgrade', (response, socket) => {
        this.socket = socket;
        socket.on('data', (chunk) => this.onData(chunk));
        socket.on('error', reject);
        resolve(this);
      });
      request.on('response', (response) => reject(new Error(`upgrade refused: ${response.statusCode}`)));
      request.on('error', reject);
      request.end();
    });
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    while (this.buffer.length >= 2) {
      const opcode = this.buffer[0] & 0x0f;
      let length = this.buffer[1] & 0x7f;
      let offset = 2;

      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }

      if (this.buffer.length < offset + length) return;

      const payload = this.buffer.slice(offset, offset + length).toString('utf8');
      this.buffer = this.buffer.slice(offset + length);

      if (opcode === 1) {
        for (const line of payload.split('\n')) {
          if (line.trim()) this.messages.push(JSON.parse(line));
        }
      }
    }
  }

  send(object) {
    const payload = Buffer.from(`${JSON.stringify(object)}\n`, 'utf8');
    const mask = crypto.randomBytes(4);
    const masked = Buffer.from(payload);
    for (let index = 0; index < masked.length; index++) masked[index] ^= mask[index % 4];

    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x81, 0x80 | payload.length]);
    } else {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
    }

    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  async login(login = `${WALLET}.ws`, pass = 'x') {
    this.send({ id: 1, jsonrpc: '2.0', method: 'login', params: { login, pass, agent: 'ws-rig/1.0' } });

    return this.waitFor((m) => m.id === 1);
  }

  async waitFor(predicate, timeout = 4000) {
    const started = Date.now();
    while (Date.now() - started < timeout) {
      const found = this.messages.find(predicate);
      if (found) return found;
      await sleep(5);
    }
    throw new Error(`timed out; got ${JSON.stringify(this.messages).slice(0, 400)}`);
  }

  close() {
    try { this.socket.destroy(); } catch (_) {}
  }
}

module.exports = { BLOB, BLOB_PANTHERA, Rig, WALLET, WsRig, ZERO_HASH, fakePool, jobFor, sleep };
