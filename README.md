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

## Documentation

* [`doc/INSTALL.md`](doc/INSTALL.md) — one-click installer, options, service
  layout, unattended fleet install, troubleshooting.
* [`doc/ALTERNATIVES.md`](doc/ALTERNATIVES.md) — measured comparison against
  Rust/Go/other miners, and why the C++ RandomX JIT stays.
* [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) — complete map of the code base:
  threads, job flow, RandomX internals, config system, where to change what.
* [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md) — every lever that affects
  hashrate, measured on real hardware, plus a troubleshooting table.
* [`doc/ZERO_FEE.md`](doc/ZERO_FEE.md) — what was removed, why it matters for
  RandomX performance, and how to verify the binary yourself.

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
