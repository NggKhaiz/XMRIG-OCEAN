# zmrig — the Zig miner

`zmrig` is the second frontend of this repository: a complete RandomX miner
written in Zig that statically links the RandomX engine that ships in
`src/crypto/randomx` (the same JIT that the C++ XMRig frontend uses).

It is not a toy port. It does everything a miner has to do on a pool:

* stratum (`stratum+tcp://` and `stratum+ssl://`), login, job/seed rotation,
  keepalive, share submission, failover between pools;
* huge pages for the cache, the dataset and the JIT code;
* one mining thread per VM, CPU pinning, thread priority;
* pipelined hashing (`hash_first`/`hash_next`), the same order XMRig uses;
* XMRig-compatible CLI flags and JSON config;
* live hashrate windows (10 s / 60 s / 15 min), session maximum, share
  counters, dataset and huge-page telemetry;
* `--version`, `--check`, `--self-test[=light]`, `--bench=N`;
* 0% developer fee — there is no donation code to audit, only `grep -c donat`.

## Why Zig and not Rust/Go

RandomX is a memory-hard, JIT-compiled proof of work. 95% of the runtime is
inside the JIT-generated code and the 2 GiB dataset; the frontend only has to
feed it blobs without getting in the way. That was measured, not assumed:

| implementation | hashrate on the validation host (2 vCPU, AVX2/VAES) |
| --- | --- |
| RandomX **JIT** (this engine, both frontends) | **≈ 1090 H/s** |
| RandomX portable interpreter (`RX_ARCH=native -Drandomx_interpreter`) | 178 H/s |
| pure-Rust (`mithril`, interpreter only) | interpreter class |
| pure-Go (`opd-ai/go-randomx`) | interpreter class, and not consensus-correct yet |
| `go-randomx` / `GxMiner` | CGo around libRandomX — i.e. this engine, plus cgo overhead |

A rewrite of RandomX in Rust or Go therefore cannot beat the JIT: it *is* the
interpreter. Reaching JIT speed means shipping the same C++ JIT anyway, so the
interesting question is which language makes the best *host* around it. Zig
wins because it compiles to a static binary with no runtime, has no GC, can
`extern` the C ABI directly, and its `comptime` covers the protocol/constant
work at build time.

See `doc/ALTERNATIVES.md` for the full comparison and the sources.

## Build

```sh
./zmrig/build.sh                 # release build into zmrig/out/zmrig
./zmrig/build.sh --jobs 8        # parallel C++ compile
./zmrig/build.sh --portable      # no -march=native (binary runs anywhere x86-64)
./zmrig/build.sh --no-zig        # only rebuild libxmorx.a (the hash engine)
./zmrig/build.sh --output DIR    # write zmrig + obj/ into DIR
```

Requirements: `g++`, `ar`, and Zig 0.13 (`ZIG=/path/to/zig` or on `PATH`).
`oneclick.sh --engine zmrig` installs Zig automatically from the PyPI wheel
(`pip3 install ziglang==0.13.0`) because it is usually missing on servers.

The C++ side is compiled with the same flags the project uses everywhere
(`-std=c++11 -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -fno-rtti -maes -march=native
-fno-plt`), object files are cached per flag signature, and the Zig frontend is
linked against `libxmorx.a` plus the system `libstdc++`/`libgcc_s` — Zig 0.13
does not resolve `-lstdc++` on a bare Debian install, so the build resolves the
real archive paths with `c++ -print-file-name=`.

## Test

```sh
./zmrig/tests/run.sh             # C API conformance (reference vectors, dataset)
./zmrig/out/zmrig --self-test    # full: vectors + pipelining + 2 GiB dataset match
./zmrig/out/zmrig --self-test=light   # vectors + pipelining only (runs beside a miner)
./zmrig/out/zmrig --bench=100000 -t 2 # offline hashrate, no pool
```

`--self-test` prints `PASS`/`FAIL` per check and exits 0 on success; it is what
`oneclick.sh verify` runs.

## Run

```sh
zmrig -o pool.example.org:10001 -u <wallet> --rig-id rig1
zmrig -c /etc/xmrig-ocean/config.json --no-color
zmrig --check -c /etc/xmrig-ocean/config.json   # validate config, do not mine
```

Supported flags mirror XMRig (`-o/-u/-p/-a/-t/-k/--cpu-affinity/--huge-pages/
--no-huge-pages/--huge-pages-jit/--no-jit/--mode=auto|fast|light/--print-time/
--retries/--retry-pause/--priority/--no-color/--verbose/--log-file/--tls`), so an
existing `config.json` can be used unchanged.

## Restrictive networks

`zmrig` speaks four transports and can tunnel through two kinds of proxy, which
is what makes it usable on a VPS that only allows 443/tcp or sits behind a CDN:

```sh
zmrig --url wss://relay.example.com/monero/TOKEN -u <wallet>   # WebSocket+TLS
zmrig --url tls://pool.example.org:443 -u <wallet> --tls-ca ca.pem
zmrig -o pool:3333 -u <wallet> --proxy socks5://user:pass@10.0.0.5:1080
zmrig -o pool:3333 -u <wallet> --proxy http://user:pass@10.0.0.5:3128
zmrig --cloudflare=relay.example.com --ws-path /monero/TOKEN -u <wallet>
```

`--connect-to HOST:PORT` keeps the pool name for TLS SNI and the HTTP `Host`
header while dialling another address, `--tls-ca FILE` pins a private CA,
`--idle-timeout` and `--keepalive-interval` control how a silent socket is
treated. See [`doc/NETWORK.md`](../doc/NETWORK.md) for the whole picture,
including a Cloudflare Worker that turns any pool into a `wss` endpoint.

## Measured performance

Validation host: 2 vCPU Xeon VM (AES, AVX2, AVX-512, VAES, SHA-NI), 3.9 GiB RAM,
1234 reserved 2 MiB huge pages, `-march=native`.

| run | result |
| --- | --- |
| `--bench=100000 -t 2` | 100001 hashes in 91–94 s = **1.083–1.098 kH/s** (3 runs, ~2% spread) |
| C++ frontend, `scripts/bench.sh --hashes 250K --seconds 45` | 1075.7 H/s |
| installed service (`oneclick.sh install --engine zmrig`) | 1084–1089 H/s steady state |
| dataset init | 15.2 s (huge pages, 2 threads) |
| memory | cache 256 MB + dataset 2080 MB, 2336 MB of it in huge pages |

The frontend adds nothing measurable over the C++ one: the hash loop and the
dataset are the same code, so the remaining difference between runs is noise.

## Known limits

* RandomX family only (`rx/0`, `rx/2`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`,
  `rx/yada`, `panthera`); the engine has an `rx/xla` code path but the miner
  does not implement the MoneroOcean v2 commitment yet.
* `--tls-insecure` is not implemented: Zig 0.13's TLS client has no
  "do not verify" switch. TLS with a valid chain works, and `--tls-ca` covers
  private CAs and pinned relays.
* The CPU backend is the only backend. GPU mining of RandomX is not a thing
  (RandomX was designed to be CPU-only), and CUDA/PTX work would be dead code.
* Linux/x86-64 is the tested platform; the engine itself also builds for ARM64.
