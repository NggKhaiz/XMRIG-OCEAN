// Listeners. Four transports, one protocol.
//
//   TCP     the default, what every miner speaks. LAN only unless --bind.
//   TLS     `stratum+ssl`, for rigs on a network that inspects plain strata.
//   WS      WebSocket. The only transport Cloudflare can carry, and the one a
//           browser dashboard can use.
//   WSS     the same over TLS.
//
// Everything a rig sends goes through the same `Downstream`, so a share
// submitted over WebSocket is validated, counted and forwarded by exactly the
// same code as one over TCP. Transport-specific behaviour is limited to bytes
// in and bytes out -- that is what makes the WebSocket path trustworthy.

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const tls = require('node:tls');

const { AccessList, RateLimiter, plainAddress } = require('./access');
const { SocketConnection, WebSocketConnection } = require('./conn');
const ws = require('../../pool/src/ws');

async function startServers(config, { downstream, logger, log }) {
  const access = new AccessList(config.allow);
  const limiter = new RateLimiter({ perMinute: 60, burst: 20 });
  const servers = [];
  const ports = {};
  const refused = { rate: 0, address: 0 };

  const guard = (remote) => {
    if (!limiter.allow(remote)) {
      refused.rate += 1;
      log('warn', `refused ${plainAddress(remote)}: too many connection attempts`);

      return false;
    }

    if (!access.allows(remote)) {
      refused.address += 1;
      log('warn', `refused ${plainAddress(remote)}: not in --allow (${access.describe()})`);

      return false;
    }

    return true;
  };

  const rigPort = (connection) => {
    if (downstream.connections.size >= config.maxRigs) {
      log('warn', `refused a rig: ${config.maxRigs} connections already open`);
      try { connection.write(JSON.stringify({ id: 0, jsonrpc: '2.0', error: { code: -1, message: 'proxy is full' }, result: null }) + '\n'); } catch (_) {}
      connection.close();

      return;
    }

    downstream.attach(connection);
  };

  // --- raw stratum ---------------------------------------------------------

  const tcp = net.createServer((socket) => {
    if (!guard(socket.remoteAddress)) {
      socket.destroy();

      return;
    }

    rigPort(new SocketConnection(socket));
  });

  await listen(tcp, config.port, config.bind);
  servers.push(tcp);
  ports.stratum = config.port;

  if (config.tls) {
    const secure = tls.createServer({
      cert: fs.readFileSync(config.tlsCert),
      key: fs.readFileSync(config.tlsKey),
      minVersion: 'TLSv1.2',
    }, (socket) => {
      if (!guard(socket.remoteAddress)) {
        socket.destroy();

        return;
      }

      rigPort(new SocketConnection(socket));
    });

    await listen(secure, config.tlsPort, config.bind);
    servers.push(secure);
    ports.stratumTls = config.tlsPort;
  }

  // --- WebSocket -----------------------------------------------------------

  if (config.ws) {
    const handler = (request, response) => {
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ ok: true, rigs: downstream.status().rigs }));
    };

    const httpServer = config.wss
      ? https.createServer({ cert: fs.readFileSync(config.tlsCert), key: fs.readFileSync(config.tlsKey) }, handler)
      : http.createServer(handler);

    // The address check happens before the socket becomes a stratum client:
    // refusing after the handshake would still leave the rig believing it is
    // connected and quietly not mining.
    ws.attach(httpServer, {
      path: config.wsPath,
      logger: { debug: () => {}, info: () => {}, warn: (message) => log('warn', message) },
      onConnection: (connection, request) => {
        const remote = request?.socket?.remoteAddress || connection.socket?.remoteAddress || 'unknown';

        if (!guard(remote)) {
          connection.close();

          return;
        }

        rigPort(new WebSocketConnection(connection, { remote }));
      },
    });

    await listen(httpServer, config.wsPort, config.bind);
    servers.push(httpServer);
    ports.ws = config.wsPort;
  }

  // --- status --------------------------------------------------------------

  let statusServer = null;

  if (config.statusPort) {
    statusServer = http.createServer((request, response) => {
      const url = request.url || '/';

      if (config.token) {
        const header = String(request.headers.authorization || '');
        const bearer = header.startsWith('Bearer ') ? header.slice(7) : '';
        const supplied = bearer || String(request.headers['x-proxy-token'] || '');

        if (supplied !== config.token) {
          response.writeHead(401, { 'content-type': 'application/json' });
          response.end(JSON.stringify({ error: 'token required' }));

          return;
        }
      }

      if (url.startsWith('/status')) {
        response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        response.end(JSON.stringify({ ...downstream.status(), access: access.describe(), refused }, null, 2));

        return;
      }

      response.writeHead(404, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: 'not found' }));
    });

    try {
      await listen(statusServer, config.statusPort, config.statusBind);
      servers.push(statusServer);
      ports.status = config.statusPort;
    } catch (error) {
      // A busy status port must not take the miner listener down with it.
      log('warn', `status listener on ${config.statusBind}:${config.statusPort} failed: ${error.message}`);
      statusServer = null;
    }
  }

  log('info', `stratum listening on ${config.bind}:${ports.stratum} (${access.describe()})` +
    (ports.stratumTls ? `, tls on :${ports.stratumTls}` : '') +
    (ports.ws ? `, ${config.wss ? 'wss' : 'ws'} on ${config.bind}:${ports.ws}${config.wsPath}` : '') +
    (ports.status ? `, status on ${config.statusBind}:${ports.status}` : ''));

  return {
    ports,
    access,
    refused,
    close: async () => {
      for (const server of servers) {
        await new Promise((resolve) => {
          try {
            server.close(() => resolve());
          } catch (_) {
            resolve();
          }
        });
        try { server.closeAllConnections?.(); } catch (_) {}
      }
    },
  };
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.removeListener('listening', onListening);
      reject(describeListenError(error, host, port));
    };
    const onListening = () => {
      server.removeListener('error', onError);
      resolve();
    };

    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}

function describeListenError(error, host, port) {
  if (error.code === 'EADDRINUSE') return new Error(`${host}:${port} is already in use (another proxy or pool is running)`);
  if (error.code === 'EADDRNOTAVAIL') return new Error(`${host} is not an address of this machine`);

  return error;
}

module.exports = { startServers };
