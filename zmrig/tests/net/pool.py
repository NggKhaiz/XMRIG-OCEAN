#!/usr/bin/env python3
"""A small fake Monero Stratum pool used by the zmrig network tests.

It speaks the exact dialect the miner expects (`login` with a job, `job`,
`submit`, `keepalived`) so every transport, reconnect and failover path can be
exercised without touching a real pool.

Modes
-----
  basic    one static job, accepts every share (default)
  soak     seed change, algorithm switch, abrupt disconnect, then a second
           seed change - exercises re-initialisation and reconnect handling
  hostile  floods the connection with malformed JSON, oversized lines and
           unknown methods, interleaved with good jobs
  stall    sends one job and then goes completely silent (idle watchdog test)

Examples
--------
  python3 zmrig/tests/net/pool.py --port 4710 --mode soak
  python3 zmrig/tests/net/pool.py --port 4710 --diff 200 --algo rx/wow

Shares are validated structurally (well formed JSON, known job id, 4 byte
nonce, 32 byte hash). The hash itself is not recomputed: that would need a
RandomX implementation on the pool side.
"""

import argparse
import json
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

MAX64 = (1 << 64) - 1

LOCK = threading.Lock()


def target_hex(diff):
    """Stratum target for a difficulty, as the 8 byte little endian hex string."""
    raw = MAX64 // max(int(diff), 1)
    return raw.to_bytes(8, "little").hex()


class Pool:
    def __init__(self, args):
        self.args = args
        self.target = target_hex(args.diff)
        self.jobs = 0
        self.submits = 0
        self.accepted = 0
        self.bad_submits = 0
        self.conns = 0
        self.dropped = 0
        self.started = time.time()
        self.stop = threading.Event()
        self.seed = args.seed
        self.algo = args.algo
        self.known_jobs = set()

    # -- logging ---------------------------------------------------------
    def log(self, msg):
        with LOCK:
            sys.stdout.write("%s %s\n" % (time.strftime("[%H:%M:%S]"), msg))
            sys.stdout.flush()

    # -- job construction ------------------------------------------------
    def blob(self, height, tag=0):
        raw = bytearray(76)
        raw[0:8] = struct.pack("<Q", height)
        raw[8] = tag & 0xFF
        raw[39:43] = b"\x00\x00\x00\x00"  # nonce
        return bytes(raw).hex()

    def job(self, height=1001, seed=None, algo=None, tag=0):
        self.jobs += 1
        job_id = "job-%d" % self.jobs
        self.known_jobs.add(job_id)
        params = {
            "blob": self.blob(height, tag),
            "job_id": job_id,
            "target": self.target,
            "height": height,
            "seed_hash": seed if seed is not None else self.seed,
            "algo": algo if algo is not None else self.algo,
        }
        if self.args.next_seed:
            params["next_seed_hash"] = self.args.next_seed
        return job_id, params

    # -- wire helpers ----------------------------------------------------
    @staticmethod
    def send(conn, payload):
        if not isinstance(payload, (bytes, bytearray)):
            payload = (json.dumps(payload) + "\n").encode()
        with LOCK:
            try:
                conn.sendall(payload)
                return True
            except OSError:
                return False

    def reply(self, conn, msg_id, result):
        self.send(conn, {"id": msg_id, "jsonrpc": "2.0", "error": None, "result": result})

    def fail(self, conn, msg_id, reason):
        self.send(conn, {"id": msg_id, "jsonrpc": "2.0",
                         "error": {"code": -1, "message": reason}, "result": None})

    # -- connection handling --------------------------------------------
    def handle(self, conn):
        self.conns += 1
        conn.settimeout(None)
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

        buf = b""
        state = {"job_id": None}

        def readline():
            nonlocal buf
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    return None
                buf += chunk
            line, buf = buf.split(b"\n", 1)
            return line.rstrip(b"\r")

        first = readline()
        if first is None:
            return
        try:
            login = json.loads(first)
        except ValueError:
            self.log("LOGIN NOT JSON: %r" % first[:120])
            return

        params = login.get("params") or {}
        # The advertised algorithm list is the difference between a rig the pool
        # leaves on rx/0 and one it mines the best-paying coin with, so record it
        # where a test can assert on it.
        advertised = params.get("algo")
        self.log("LOGIN %s agent=%s user=%s algo=%s" % (
            login.get("method"),
            login.get("agent", "-"),
            str(params.get("login"))[:16],
            ",".join(advertised) if isinstance(advertised, list) else "-"))

        if self.args.reject_login:
            self.reply(conn, login.get("id"), None)
            self.fail(conn, login.get("id"), self.args.reject_login)
            return

        job_id, job = self.job()
        state["job_id"] = job_id
        self.reply(conn, login.get("id"), {"id": "rig-test", "job": job, "status": "OK"})

        if self.args.mode == "stall":
            self.stop.wait(self.args.duration)

            return

        if self.args.mode == "close":
            # Answer the login, let the miner submit for a moment, then drop the
            # connection. The client's next submit hits a closed socket, which
            # is the same recovery path as a send that never completes.
            time.sleep(self.args.close_after)

            try:
                conn.close()
            except OSError:
                pass

            return

        if self.args.mode == "deaf":
            # The job is out; never read the socket again. The client's send
            # buffer fills up and it has to drop the connection instead of
            # blocking every worker on the submit mutex.
            self.stop.wait(self.args.duration)

            return

        if self.args.mode == "hostile":
            threading.Thread(target=self.hostile_flood, args=(conn, state), daemon=True).start()
        else:
            threading.Thread(target=self.scheduler, args=(conn, state), daemon=True).start()

        deadline = time.time() + self.args.duration
        while not self.stop.is_set() and time.time() < deadline:
            line = readline()
            if line is None:
                break
            self.on_line(conn, line, state)

        try:
            conn.close()
        except OSError:
            pass

    def on_line(self, conn, line, state):
        # A pool that answers every submit with "rejected": a real failure mode
        # (wrong algorithm after a fork, a wallet the pool does not know, a
        # pool-side bug) that a hashrate check cannot see.
        if self.args.mode == "reject":
            try:
                msg = json.loads(line)
            except ValueError:
                return

            if msg.get("method") == "submit":
                # params is an object: {"id": <job>, "nonce": ..., "result": ...}
                params = msg.get("params") or {}
                submit_id = params.get("id") if isinstance(params, dict) else None
                # Only the error: replying "OK" as well would make the miner
                # count the share as accepted, and the whole point of this mode
                # is a pool that accepts the connection and none of the work.
                self.fail(conn, submit_id or msg.get("id"), "Low difficulty share")
                self.log("REJECT %s" % submit_id)

            return

        if not line.strip():
            return
        try:
            msg = json.loads(line)
        except ValueError:
            self.log("CLIENT SENT NON JSON: %r" % line[:120])

            return

        if not isinstance(msg, dict):
            return

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "submit":
            self.on_submit(conn, msg, state)
        elif method == "keepalived":
            self.reply(conn, msg_id, {"status": "KEEPALIVED"})
        elif method == "login":
            self.reply(conn, msg_id, {"id": "rig-test", "status": "OK"})
        else:
            self.log("CLIENT METHOD %s" % method)
            self.reply(conn, msg_id, {"status": "OK"})

    def on_submit(self, conn, msg, state):
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        self.submits += 1

        job_id = params.get("job_id")
        nonce = params.get("nonce")
        result = params.get("result")

        ok = (
            job_id in self.known_jobs
            and isinstance(nonce, str) and len(nonce) == 8
            and isinstance(result, str) and len(result) == 64
            and result.strip("0") != ""
        )

        if not ok:
            self.bad_submits += 1
            self.log("SUBMIT REJECTED job=%r nonce=%r result=%r" % (job_id, nonce, str(result)[:16]))
            self.fail(conn, msg.get("id"), "Low difficulty share" if result else "Invalid share")

            return

        self.accepted += 1
        self.reply(conn, msg.get("id"), {"status": "OK"})

    # -- background behaviours -------------------------------------------
    def scheduler(self, conn, state):
        """Mode specific job stream. Timings are in seconds from login."""
        mode = self.args.mode
        t0 = time.time()

        def wait_until(t):
            while not self.stop.is_set():
                left = t0 + t - time.time()
                if left <= 0:
                    return True
                time.sleep(min(left, 0.25))

            return False

        if mode == "basic":
            # A second job with the same seed: the common "new block" case.
            if wait_until(self.args.job_interval):
                job_id, job = self.job(height=1002, tag=1)
                state["job_id"] = job_id
                self.send(conn, {"jsonrpc": "2.0", "method": "job", "params": job})
                self.log("JOB %s height=1002" % job_id)

            return

        if mode != "soak":
            return

        if wait_until(10):
            job_id, job = self.job(height=1002, tag=1)
            state["job_id"] = job_id
            self.send(conn, {"jsonrpc": "2.0", "method": "job", "params": job})
            self.log("JOB %s height=1002 (same seed)" % job_id)

        if wait_until(40):
            self.seed = self.new_seed("B")
            job_id, job = self.job(height=1003, seed=self.seed, tag=2)
            state["job_id"] = job_id
            self.send(conn, {"jsonrpc": "2.0", "method": "job", "params": job})
            self.log("JOB %s seed change -> %s" % (job_id, self.seed[:16]))

        if wait_until(90):
            self.algo = "rx/wow"
            self.seed = self.new_seed("C")
            job_id, job = self.job(height=1004, seed=self.seed, algo="rx/wow", tag=3)
            state["job_id"] = job_id
            self.send(conn, {"jsonrpc": "2.0", "method": "job", "params": job})
            self.log("JOB %s algo switch -> rx/wow seed %s" % (job_id, self.seed[:16]))

        if wait_until(150):
            # Abrupt reset: the miner must notice, back off and reconnect.
            self.log("ABRUPT DISCONNECT")
            try:
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                conn.close()
            except OSError:
                pass

            return

    @staticmethod
    def new_seed(tag):
        # A deterministic but unique 32 byte seed per tag.
        return (tag.encode().ljust(32, b"\x00")).hex()

    def hostile_flood(self, conn, state):
        """Junk interleaved with the odd valid job."""
        junk = [
            b"\n", b"\r\n", b"not json\n", b"{}\n", b"[]\n", b"null\n",
            b'{"id":1}\n', b'{"jsonrpc":"2.0"}\n', b'{"method":"job","params":3}\n',
            b'{"method":"job","params":{}}\n', b'{"method":"job","params":{"blob":7}}\n',
            b'{"method":"job","params":{"blob":"zz","target":"1"}}\n',
            b'{"method":"job","params":{"blob":"00","target":"1"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"zzzz"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"00000000"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"0000000000000000"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"f753e3a5","seed_hash":"00"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"f753e3a5","seed_hash":"'
            + b"aa" * 40 + b'"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"f753e3a5","algo":"nope"}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 60 + b'","target":"f753e3a5","height":-5}}\n',
            b'{"method":"job","params":{"blob":"' + b"00" * 620 + b'","target":"f753e3a5"}}\n',
            b'{"result":{"id":1,"status":"OK"},"error":null,"id":1}\n',
            b'{"result":{"id":1,"status":"FAIL","message":"' + b"m" * 4000 + b'"},"id":2}\n',
            b'{"method":"keepalived","params":{}}\n',
            b'{"id":9,"method":"client.reconnect","params":[]}\n',
            b"\x00\x01\x02\x03\xff\xfe\n",
            b"x" * 100000, b"\n",
        ]

        i = 0
        while not self.stop.is_set():
            if not self.send(conn, junk[i % len(junk)]):
                return
            i += 1
            if i % 12 == 0:
                job_id, job = self.job(height=2000 + i, tag=i)
                state["job_id"] = job_id
                self.send(conn, {"jsonrpc": "2.0", "method": "job", "params": job})
                self.log("JOB %s (after %d junk lines)" % (job_id, i))
            time.sleep(0.08)

    # -- server ----------------------------------------------------------
    def serve(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.args.host, self.args.port))
        srv.listen(16)

        self.log("PORT %d mode=%s diff=%s target=%s algo=%s" % (
            self.args.port, self.args.mode, self.args.diff, self.target, self.args.algo))

        srv.settimeout(0.5)
        threads = []
        deadline = time.time() + self.args.lifetime if self.args.lifetime else None

        while not self.stop.is_set():
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                if deadline and time.time() > deadline:
                    break
                continue
            except OSError:
                break

            thread = threading.Thread(target=self.handle, args=(conn,), daemon=True)
            thread.start()
            threads.append(thread)

            if deadline and time.time() > deadline:
                break

        self.stop.set()

        self.log("STATS conns=%d jobs=%d submits=%d accepted=%d rejected=%d" % (
            self.conns, self.jobs, self.submits, self.accepted, self.bad_submits))


def main():
    ap = argparse.ArgumentParser(description="fake Stratum pool for the zmrig tests")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4710)
    ap.add_argument("--mode", default="basic", choices=["basic", "soak", "hostile", "stall", "deaf", "close", "reject"])
    ap.add_argument("--diff", type=float, default=2000, help="job difficulty; small values make shares frequent")
    ap.add_argument("--algo", default="rx/0")
    ap.add_argument("--seed", default="1" * 64)
    ap.add_argument("--next-seed", default=None)
    ap.add_argument("--job-interval", type=float, default=20, help="basic: delay before the second job")
    ap.add_argument("--reject-login", default=None, help="reply to login with this error message")
    ap.add_argument("--duration", type=float, default=600, help="seconds a single connection is served")
    ap.add_argument("--lifetime", type=float, default=0, help="stop listening after N seconds")
    ap.add_argument("--close-after", type=float, default=5, help="close mode: seconds before the socket is closed")
    args = ap.parse_args()

    pool = Pool(args)
    try:
        pool.serve()
    except KeyboardInterrupt:
        pool.stop.set()


if __name__ == "__main__":
    main()
