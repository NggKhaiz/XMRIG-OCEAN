#!/usr/bin/env python3
"""Transport shims for the zmrig network tests.

Each mode puts a different protocol in front of a plain TCP Stratum pool, so
every code path in zmrig/src/transport.zig can be tested without a real pool
and without a real CDN.

  tls      raw TLS tunnel          (zmrig --tls / stratum+tls)
  ws       WebSocket tunnel        (zmrig ws:// / stratum+ws)
  wss      TLS + WebSocket         (zmrig wss:// / stratum+wss, Cloudflare style)
  http     HTTP CONNECT proxy      (zmrig --proxy http://...)
  socks5   SOCKS5 proxy            (zmrig --proxy socks5://...)

Examples
--------
  python3 zmrig/tests/net/relay.py --mode wss --port 4802 \
      --backend 127.0.0.1:4800 --cert /tmp/zmrig-test/cert.pem --key /tmp/zmrig-test/key.pem

Generate a certificate first with zmrig/tests/net/cert.sh.
"""

import argparse
import base64
import hashlib
import socket
import ssl
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOCK = threading.Lock()


def log(msg):
    with LOCK:
        sys.stdout.write("%s %s\n" % (time.strftime("[%H:%M:%S]"), msg))
        sys.stdout.flush()


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def pump(src, dst, close_after=True):
    """Copy bytes one way until EOF, then half-close the destination."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except (OSError, ssl.SSLError):
        pass
    finally:
        if close_after:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass


# --------------------------------------------------------------------------
# WebSocket framing
# --------------------------------------------------------------------------
def ws_frame(opcode, payload):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


def ws_read_frame(sock):
    """Read one client frame, unmask it and return (opcode, payload)."""
    head = recv_exact(sock, 2)
    if head is None:
        return None
    opcode = head[0] & 0x0F
    masked = bool(head[1] & 0x80)
    length = head[1] & 0x7F
    if length == 126:
        raw = recv_exact(sock, 2)
        if raw is None:
            return None
        length = struct.unpack(">H", raw)[0]
    elif length == 127:
        raw = recv_exact(sock, 8)
        if raw is None:
            return None
        length = struct.unpack(">Q", raw)[0]
    mask = None
    if masked:
        mask = recv_exact(sock, 4)
        if mask is None:
            return None
    payload = recv_exact(sock, length) if length else b""
    if payload is None:
        return None
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def ws_handshake(sock, backend, extra_path=None):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 65536:
            return None

    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    request = lines[0].decode("latin-1")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        headers[name.strip().lower().decode("latin-1")] = value.strip().decode("latin-1")

    key = headers.get("sec-websocket-key")
    if not key or "upgrade" not in headers.get("connection", "").lower():
        sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        return None

    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    sock.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
    ).encode())

    log("WS %s host=%s origin=%s" % (
        request.split(" ")[1] if " " in request else "?",
        headers.get("host", "-"),
        headers.get("origin", "-")))

    return rest


def ws_bridge(sock, upstream, rest):
    """Turn the WebSocket stream into a byte stream for the backend."""
    if rest:
        try:
            upstream.sendall(rest)
        except OSError:
            return

    def client_to_backend():
        while True:
            frame = ws_read_frame(sock)
            if frame is None:
                break
            opcode, payload = frame
            if opcode in (0x1, 0x2, 0x0):
                if payload:
                    # A Cloudflare Worker turns a WebSocket message back into a
                    # line: Stratum over TCP is newline delimited, while the
                    # miner (correctly) leaves the newline out of the frame.
                    upstream.sendall(payload if payload.endswith(b"\n") else payload + b"\n")
            elif opcode == 0x8:
                break
            elif opcode == 0x9:
                sock.sendall(ws_frame(0xA, payload))
            # 0xA (pong) is ignored
        try:
            upstream.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def backend_to_client():
        try:
            while True:
                data = upstream.recv(65536)
                if not data:
                    break
                sock.sendall(ws_frame(0x2, data))
        except OSError:
            pass
        try:
            sock.sendall(ws_frame(0x8, b""))
        except OSError:
            pass

    thread = threading.Thread(target=client_to_backend, daemon=True)
    thread.start()
    backend_to_client()
    thread.join(timeout=5)


# --------------------------------------------------------------------------
# Proxies
# --------------------------------------------------------------------------
def http_connect(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data += chunk

    head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1")
    request = head.split("\r\n")[0]
    parts = request.split(" ")
    if len(parts) < 2 or parts[0].upper() != "CONNECT":
        sock.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        return None
    host, _, port = parts[1].partition(":")
    log("HTTP CONNECT %s:%s" % (host, port or "443"))
    sock.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    return host, int(port or 443)


def socks5_handshake(sock):
    head = recv_exact(sock, 2)
    if head is None or head[0] != 0x05:
        return None
    methods = recv_exact(sock, head[1])
    if methods is None:
        return None
    sock.sendall(b"\x05\x00")  # no authentication

    head = recv_exact(sock, 4)
    if head is None or head[1] != 0x01:
        return None
    atyp = head[3]
    if atyp == 0x01:
        host = socket.inet_ntoa(recv_exact(sock, 4))
    elif atyp == 0x03:
        length = recv_exact(sock, 1)[0]
        host = recv_exact(sock, length).decode()
    elif atyp == 0x04:
        host = socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
    else:
        return None
    port = struct.unpack(">H", recv_exact(sock, 2))[0]
    log("SOCKS5 CONNECT %s:%d" % (host, port))
    sock.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 0))
    return host, port


# --------------------------------------------------------------------------
# Server
# --------------------------------------------------------------------------
class Relay:
    def __init__(self, args):
        self.args = args
        self.context = None
        self.count = 0
        if args.mode in ("tls", "wss"):
            self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self.context.load_cert_chain(args.cert, args.key)

    def backend_addr(self, host=None, port=None):
        if host and port and self.args.passthrough:
            return host, port
        host, _, port = self.args.backend.partition(":")
        return host, int(port)

    def handle(self, conn):
        self.count += 1
        conn.settimeout(None)
        try:
            if self.context is not None:
                conn = self.context.wrap_socket(conn, server_side=True)
            self.serve(conn)
        except (OSError, ssl.SSLError) as e:
            log("connection error: %s" % e)
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def serve(self, conn):
        mode = self.args.mode
        rest = b""
        host = port = None

        if mode == "http":
            addr = http_connect(conn)
            if addr is None:
                return
            host, port = self.backend_addr(*addr)
        elif mode == "socks5":
            addr = socks5_handshake(conn)
            if addr is None:
                return
            host, port = self.backend_addr(*addr)
        else:
            host, port = self.backend_addr()

        if mode in ("ws", "wss"):
            upstream = socket.create_connection((host, port), timeout=10)
            upstream.settimeout(None)
            rest = ws_handshake(conn, upstream)
            if rest is None:
                upstream.close()

                return
            ws_bridge(conn, upstream, rest)
            upstream.close()

            return

        upstream = socket.create_connection((host, port), timeout=10)
        upstream.settimeout(None)
        log("%s tunnel %s:%d" % (mode.upper(), host, port))
        thread = threading.Thread(target=pump, args=(conn, upstream), daemon=True)
        thread.start()
        pump(upstream, conn)
        thread.join(timeout=5)
        upstream.close()

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.args.host, self.args.port))
        srv.listen(16)
        log("PORT %d mode=%s backend=%s" % (self.args.port, self.args.mode, self.args.backend))

        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser(description="transport shim for the zmrig tests")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--mode", required=True, choices=["tls", "ws", "wss", "http", "socks5"])
    ap.add_argument("--backend", default="127.0.0.1:4710")
    ap.add_argument("--cert", default=None)
    ap.add_argument("--key", default=None)
    ap.add_argument("--passthrough", action="store_true",
                    help="proxy modes connect to the host the client asked for")
    args = ap.parse_args()

    if args.mode in ("tls", "wss") and (not args.cert or not args.key):
        ap.error("--cert and --key are required for %s" % args.mode)

    try:
        Relay(args).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
