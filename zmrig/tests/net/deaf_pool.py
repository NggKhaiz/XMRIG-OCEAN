#!/usr/bin/env python3
"""A pool that answers the login and then never reads the socket again.

Used to prove that a share submission cannot stall the mining threads: the
client's send buffer fills up, and the miner has to drop the connection
instead of blocking every worker on the submit mutex.

    python3 zmrig/tests/net/deaf_pool.py 4499
"""
import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4499

BLOB = "01" * 39 + "00000000" + "02" * 33
JOB = {
    "id": 1,
    "jsonrpc": "2.0",
    "error": None,
    "result": {
        "id": "deaf-session",
        "job": {
            "blob": BLOB,
            "job_id": "deaf-1",
            "target": "feffffffffffffff",
            "height": 1,
            "algo": "rx/0",
            "seed_hash": "ab" * 32,
        },
    },
}


def serve(client):
    try:
        client.makefile("rb").readline()
        client.sendall((json.dumps(JOB) + "\n").encode())
        # Never read again: the pool is alive but deaf.
        time.sleep(300)
    except Exception:
        pass
    finally:
        client.close()


def main():
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(8)
    print("deaf pool listening on 127.0.0.1:%d" % PORT, flush=True)

    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
