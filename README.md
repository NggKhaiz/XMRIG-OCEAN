# XMRig — fee-free, performance-first fork

A fork of [XMRig](https://github.com/xmrig/xmrig) `6.26.0` (MoneroOcean flavour,
native RandomX v2 support) rebuilt around two hard requirements:

* **0 % developer fee** — the donation strategy, its time slicing, its wallet and
  its pool endpoint are removed from the source tree and from the binary. The
  miner reports `DONATE 0%` and never opens a second stratum session.
* **maximum hashrate on the machine you build on** — tuned build flags, tuned
  runtime defaults (JIT huge pages, 1 GiB page auto-detection, scratchpad memory
  pool, no thread yielding), real Linux process priority, an OS tuning script and
  a reproducible benchmark harness.

## One-click install

```bash
# fresh machine: fetch, build, tune, install as a service, verify, print stats
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/XMRIG-OCEAN/arena/918a7f95-xmrig-ocean/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress...
```

```bash
sudo ./oneclick.sh status     # service + live hashrate + accepted shares
sudo ./oneclick.sh bench      # 180 s RandomX measurement
sudo ./oneclick.sh verify     # prove the 0% fee
sudo ./oneclick.sh update     # git pull, rebuild, restart
```

It installs `xmrig-ocean` (miner), `xmrig-ocean-tune` (host tuning),
`xmrig-ocean-bench`, `xmrig-ocean-verify`, a supervised systemd service and a
boot-time tuning unit. Safe to re-run; the config is never overwritten without
`--force`. Details, options and troubleshooting: [`doc/INSTALL.md`](doc/INSTALL.md).

Two frontends are available, and the installer picks one:

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress...                # C++ XMRig (all algorithms)
sudo ./oneclick.sh install --wallet 4YourMoneroAddress... --engine zmrig # Zig miner (RandomX)
```

`zmrig` is a full RandomX miner written in Zig on top of the same hash engine,
installed side by side as `/usr/local/bin/zmrig`; the service, the config, the
benchmark and the fee audit work the same way for both. Measured on the
validation host: **1084–1089 H/s installed** versus 1075.7 H/s for the C++
frontend, i.e. the frontend is not the bottleneck. See
[`zmrig/README.md`](zmrig/README.md).

Restrictive network? A host that only lets 443/tcp out, or sits behind a CDN,
can still mine:

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress... \
     --pool your-relay.example.com:443 --cloudflare --ws-path /monero/TOKEN
```

`--cloudflare` switches the pool to WebSocket-over-TLS on 443 (the one shape
that passes HTTPS-only egress) and selects the engine that speaks it. Proxies,
edge-IP dialling and certificate pinning are covered in
[`doc/NETWORK.md`](doc/NETWORK.md).

## Website: documentation and a fleet calculator

`web/` is a static site (no build step, no framework) with the operator-facing
documentation and a profitability/electricity calculator for one or many
machines. The miner prints a one-line report code, you paste it in, and the page
prices the machine without sending anything anywhere:

```bash
zmrig --report --power 95          # 15 s measurement, prints ZMRIG1.<base64>
cat /var/lib/xmrig-ocean/report.txt # or the live file the service updates
```

```bash
python3 -m http.server -d web 8080  # preview at http://localhost:8080
```

Deploy by pointing Cloudflare Pages (or Vercel) at the repository with **no
build command** and `web` as the output directory; `_headers` / `vercel.json`
carry the security and cache headers. See [`web/README.md`](web/README.md).

## Documentation

* [`web/content/vi/`](web/content/vi/) — the same material as a browsable site,
  in Vietnamese: install, configuration, benchmarks, restrictive networks,
  monitoring, profitability, troubleshooting.
* [`doc/INSTALL.md`](doc/INSTALL.md) — one-click installer, options, service
  layout, unattended fleet install, troubleshooting.
* [`doc/ALTERNATIVES.md`](doc/ALTERNATIVES.md) — measured comparison against
  Rust/Go/other miners, why the C++ RandomX JIT stays, and what a "rewrite it
  in a fast language" project can and cannot buy.
* [`zmrig/README.md`](zmrig/README.md) — the Zig miner: architecture, build,
  tests, measured hashrate, known limits.
* [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) — complete map of the code base:
  threads, job flow, RandomX internals, config system, where to change what.
* [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md) — every lever that affects
  hashrate, measured on real hardware, plus a troubleshooting table.
* [`doc/ZERO_FEE.md`](doc/ZERO_FEE.md) — what was removed, why it matters for
  RandomX performance, and how to verify the binary yourself.
* [`doc/NETWORK.md`](doc/NETWORK.md) — mining from a VPS that only allows 443:
  `--cloudflare`, WebSocket/TLS transports, HTTP CONNECT and SOCKS5 proxies,
  `--connect-to`, certificate pinning, and a ready-to-deploy Cloudflare Worker
  relay.

## Manual install

```bash
# 1. build for this CPU (Release + native ISA, CPU-only)
./scripts/build-optimized.sh

# 2. prepare the host: huge pages, THP, governor, MSR (root, once per boot)
sudo ./scripts/tune-linux.sh

# 3. edit config/performance.json (wallet + pool) and start
sudo ./build/xmrig -c config/performance.json

# 4. measure, and prove there is no fee
./scripts/bench.sh --seconds 300
./scripts/verify-fee-free.sh
```

Startup log should show `huge pages 100%`, `dataset ready`, `READY` and the MSR
preset applied. Anything else is explained in `doc/PERFORMANCE.md` §9.

To make sure huge pages and MSR survive a reboot, call
`scripts/tune-linux.sh` from a systemd oneshot unit.

## The Zig miner

`zmrig/` contains a second, complete miner: Zig frontend (stratum, jobs, threads,
config, stats) + the RandomX JIT from `src/crypto/randomx` behind a small C ABI.
Same hashrate as the C++ frontend, no runtime, no GC, 0% fee, and it builds in
about a minute once the engine objects are cached.

```bash
./zmrig/build.sh                                   # build zmrig/out/zmrig
./zmrig/tests/run.sh                               # engine conformance tests
./zmrig/out/zmrig --self-test                      # vectors + 2 GiB dataset check
./zmrig/out/zmrig -o pool:port -u <wallet> -t 2    # mine
```

Why Zig instead of Rust or Go is answered with measurements in
[`zmrig/README.md`](zmrig/README.md) and [`doc/ALTERNATIVES.md`](doc/ALTERNATIVES.md):
a pure Rust/Go RandomX is the portable interpreter, which is 6.1x slower here.

## Mining backends

- **CPU** (x86/x64, ARMv7/ARMv8, RISC-V, RandomX v2, CryptoNight family, Argon2,
  GhostRider, Flex/KCN, Panthera)
- **OpenCL** for AMD GPUs (`--all-backends` build)
- **CUDA** for NVIDIA GPUs via the external
  [CUDA plugin](https://github.com/xmrig/xmrig-cuda) (`--all-backends` build)

## Configuration

`config/performance.json` is a ready-to-edit template for a CPU rig on
MoneroOcean (auto algorithm switching). The miner still accepts every upstream
XMRig option; see `--help`, `doc/` and the upstream
[config documentation](https://xmrig.com/docs/miner/config).

`donate-level` and `donate-over-proxy` are accepted and ignored: this build is
permanently fee-free.

## Tests

```bash
./tests/hash/check.sh                     # hash known-answer suite
node run_tests.js --safe --build-dir build # what CI runs
```

## Credits and license

XMRig is Copyright (C) 2016-2026 xmrig.com, Copyright (C) 2018-2026 SChernykh,
and the RandomX authors, licensed under **GPL-3.0**. The MoneroOcean additions
are Copyright (C) MoneroOcean. This fork keeps all copyright headers and the
license intact; see [`LICENSE`](LICENSE).

If you want to support upstream development, make a voluntary one-off donation
using the address published in the upstream project — nothing in this tree is
wired to it.
