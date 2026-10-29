// Cloudflare Worker: WebSocket ⇄ TCP bridge for Ocean Pool.
//
// Why this exists: a lot of VPS products only allow outbound 443. A miner on
// such a box cannot open a TCP connection to pool:3333, but it can open a
// WebSocket to Cloudflare. This Worker accepts that WebSocket and pumps the
// bytes to the pool over a normal TCP socket, so the pool itself needs no TLS
// and no public IP.
//
//   miner ──wss://pool.example/stratum──▶ Worker ──tcp──▶ pool:3333
//
// It is stateless: no Durable Object, no KV, no storage, so it fits the free
// Workers plan. Each connection is one miner; nothing is shared between them.
//
// Deploy:
//   cd pool/worker
//   npx wrangler deploy
//
// Vars (wrangler.toml or the dashboard):
//   POOL_HOST  hostname or IP of the pool, e.g. pool.example.com
//   POOL_PORT  TCP stratum port, default 3333
//   WS_PATH    path miners connect to, default /stratum

import { connect } from 'cloudflare:sockets';

const MAX_BUFFER = 64 * 1024;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = env.WS_PATH || '/stratum';

    if (url.pathname !== path) {
      return new Response('Ocean Pool bridge: connect a WebSocket to ' + path + '\n', {
        status: 404,
        headers: { 'content-type': 'text/plain' },
      });
    }

    if ((request.headers.get('Upgrade') || '').toLowerCase() !== 'websocket') {
      return new Response('Expected a WebSocket upgrade.\n', {
        status: 426,
        headers: { upgrade: 'websocket', 'content-type': 'text/plain' },
      });
    }

    if (!env.POOL_HOST) {
      return new Response('POOL_HOST is not configured.\n', { status: 500 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    server.accept();

    let socket;
    try {
      socket = connect({
        hostname: String(env.POOL_HOST),
        port: Number(env.POOL_PORT || 3333),
      });
    } catch (error) {
      server.close(1011, 'cannot reach the pool');

      return new Response(`cannot open a TCP socket to the pool: ${error.message}\n`, { status: 502 });
    }

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();
    const decoder = new TextDecoder();
    let closed = false;

    const shutdown = (code, reason) => {
      if (closed) return;
      closed = true;
      try { server.close(code, reason); } catch (_) {}
      try { writer.releaseLock(); } catch (_) {}
      socket.close().catch(() => {});
    };

    // Miner → pool. Stratum is JSON text; WebSocket may deliver a string or an
    // ArrayBuffer depending on the client.
    server.addEventListener('message', (event) => {
      const text = typeof event.data === 'string'
        ? event.data
        : decoder.decode(event.data, { stream: true });

      writer.write(new TextEncoder().encode(text)).catch(() => shutdown(1011, 'write failed'));
    });

    server.addEventListener('close', () => shutdown(1000, 'miner closed'));

    // Pool → miner. A TCP read can end mid-line, so decode with a streaming
    // decoder and let the pool's own line splitter see complete frames.
    (async () => {
      try {
        while (!closed) {
          const { value, done } = await reader.read();
          if (done) break;

          if (value && value.byteLength) {
            server.send(decoder.decode(value, { stream: true }));
          }
        }
      } catch (_) {
        // fall through to the close below
      } finally {
        shutdown(1000, 'pool closed the socket');
      }
    })();

    // A pooled connection that is idle for an hour is almost always dead.
    setTimeout(() => shutdown(1000, 'bridge timeout'), 60 * 60 * 1000);

    return new Response(null, { status: 101, webSocket: client });
  },
};
