// Transport adapters: one shape for TCP, TLS and WebSocket connections so the
// protocol code in downstream.js never learns which one it is talking over.
//
// The contract is deliberately tiny:
//
//   write(text)     send a line (the newline is added by the caller)
//   on('line')      a complete line arrived, trailing CR removed
//   on('close')     the peer is gone
//   close()         hang up
//
// Getting this right is not cosmetic: the pool shipped a version where the
// socket's 'data' event was wired to the line handler and every frame arrived
// as a Buffer -- JSON.parse survives it by accident, partial lines do not.

'use strict';

const { EventEmitter } = require('node:events');

const MAX_BUFFER = 256 * 1024;

class SocketConnection extends EventEmitter {
  constructor(socket, meta = {}) {
    super();

    this.socket = socket;
    this.meta = meta;
    this.remote = meta.remote || (socket.remoteAddress ? `${socket.remoteAddress}:${socket.remotePort}` : 'unknown');
    this.buffer = '';
    this.closed = false;

    socket.setNoDelay?.(true);
    socket.setKeepAlive?.(true, 30_000);

    socket.on('data', (chunk) => this.onData(chunk));
    socket.on('error', () => this.close());
    socket.on('close', () => this.onClose());
  }

  onData(chunk) {
    this.buffer += chunk.toString('utf8');

    if (this.buffer.length > MAX_BUFFER) {
      this.buffer = '';
      this.emit('overflow');
      this.close();

      return;
    }

    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).replace(/\r$/, '');
      this.buffer = this.buffer.slice(index + 1);
      if (line.trim()) this.emit('line', line);
    }
  }

  write(text) {
    if (this.closed) return false;

    try {
      return this.socket.write(text);
    } catch (_) {
      this.onClose();

      return false;
    }
  }

  close() {
    if (this.closed) return;
    try { this.socket.destroy(); } catch (_) {}

    this.onClose();
  }

  onClose() {
    if (this.closed) return;
    this.closed = true;
    this.emit('close');
  }
}

/** Wraps the dependency-free WebSocket server's connections (pool/src/ws.js),
 *  which deliver whole text frames rather than a byte stream. */
class WebSocketConnection extends EventEmitter {
  constructor(ws, meta = {}) {
    super();

    this.ws = ws;
    this.meta = meta;
    this.remote = meta.remote || ws.remote || 'ws';
    this.closed = false;

    ws.on('message', (text) => {
      // A frame may hold one JSON object or several newline-separated ones.
      for (const line of String(text).split('\n')) {
        const trimmed = line.trim();
        if (trimmed) this.emit('line', trimmed);
      }
    });
    ws.on('close', () => this.onClose());
    ws.on('error', () => this.close());
  }

  write(text) {
    if (this.closed) return false;

    try {
      this.ws.send(text);

      return true;
    } catch (_) {
      this.onClose();

      return false;
    }
  }

  close() {
    try { this.ws.close(); } catch (_) {}
    this.onClose();
  }

  onClose() {
    if (this.closed) return;
    this.closed = true;
    this.emit('close');
  }
}

module.exports = { SocketConnection, WebSocketConnection };
