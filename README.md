# XMRig Ocean

A RandomX miner with **no developer fee**, and the pool that pays for it.

This repository contains two halves of a working setup:

| Part | What it is | What it costs |
| --- | --- | --- |
| **Miner** — `src/`, `zmrig/`, `oneclick.sh` | XMRig `6.26.0` fork with the donation code removed, plus a complete Zig miner on the same RandomX engine | 0 % — forever, provable |
| **Pool** — `pool/`, `deploy/`, `worker/` | Self-hosted Monero pool: stratum over TCP and WebSocket, PPLNS ledger, share verification, auditable payouts | 1 % of each block reward |
| **Site** — `web/` | Static documentation, fleet calculator, command builder | free to host |

You can use the miner with any pool. If you point it at the pool included
here, the 1 % fee is what keeps the project alive; nothing else is charged, and
the miner takes nothing from you either way.

## The money model, stated plainly

**The miner has no fee.** The donation strategy, its time slicing, its wallet
and its endpoint are gone from the source and from the binary. `donate-level`
and `donate-over-proxy` are accepted and ignored. `sudo ./oneclick.sh verify`
greps the binary for the upstream endpoints and wallets, and the miner prints
`0% developer fee` at startup.

**The pool charges 1 % of each block reward**, taken before the PPLNS split and
rounded *down*. It is not a hidden spread: the miner receives the number in the
`login` reply, `/api/config` prints it, the status page shows it, and every
block is written to an append-only audit log with the reward, the fee, each
miner's payment and the leftover dust.

**Why 1 %.** It is the range the established Monero pools live in (0.6 – 1 %),
and it has to fund the thing those pools mostly skip: the pool re-hashes every
submitted share with `zmrig --verify-share` before paying for it. That costs the
operator real CPU, and it is the only reason a miner can trust that nobody else
is being paid for work they did not do. There is no registration, no coin
switching, no "donation" button and no second address.

**Long-term fairness.** A 1 % fee with honest share accounting keeps the best
miners, and the best miners are the only reason a pool earns anything. The
ledger is PPLNS over one hour by share *difficulty*, so a slow connection is not
punished and a split rig is not paid twice.

## Install in one command

```bash
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/XMRIG-OCEAN/arena/918a7f95-xmrig-ocean/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress...
```

The installer fetches, builds, tunes the host (huge pages, THP, governor, MSR),
installs a systemd service, verifies the 0 % fee and prints live stats. Re-running
it is safe; the config is never overwritten without `--force`.

Choose the engine, the pool, or the transport:

```bash
# C++ frontend, all algorithms
sudo ./oneclick.sh install --wallet 4YourMoneroAddress...

# Zig frontend (RandomX), same engine, same hashrate
sudo ./oneclick.sh install --wallet 4YourMoneroAddress... --engine zmrig

# only 443/tcp out, or behind a CDN
sudo ./oneclick.sh install --wallet 4YourMoneroAddress... \
  --pool pool.example.com:443 --cloudflare --ws-path /stratum
```

Prefer to see the command before running it? The site builds it for you:
**<https://nggkhaiz.github.io/XMRIG-OCEAN/#builder>** — tick the options you
want, paste the one-liner, and the only thing left is your `sudo` password.

## Everyday commands

```bash
sudo ./oneclick.sh status           # service, hashrate, accepted shares
sudo ./oneclick.sh bench            # 180 s RandomX measurement
sudo ./oneclick.sh report --power 95 # ZMRIG1. code for the site calculator
sudo ./oneclick.sh verify           # prove the 0 % fee
sudo ./oneclick.sh update           # git pull, rebuild, restart
sudo ./oneclick.sh config --wallet 4YourMoneroAddress... --force
```

The same measurements are available from the miner itself:

```bash
zmrig --self-test                   # hash vectors, benchmark, memory pre-flight
zmrig --bench 60 --mode fast        # 60 s on the real dataset
zmrig --report --power 95           # prints ZMRIG1.<base64> in ~15 s
zmrig -o pool:3333 -u 4YourAddress.rig1 -t 4
```

`oneclick.sh report` refuses to run when the machine cannot hold the dataset,
instead of being killed by the OOM killer mid-measurement.

## Mining to Ocean Pool

The pool in `pool/` is meant to be deployed by whoever runs it; there is no
central service to sign up for. A reference deployment is reachable as:

```bash
zmrig -o wss://pool.example.com/stratum -u 4YourMoneroAddress.rig1 -t 4
# or, where raw TCP is allowed
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress.rig1 -t 4
```

Fees from that pool go to `46SQLW7D…n6ysb5tJ` (the full address is published by
the running pool at `/api/config` — deliberately not copy-pasteable out of the
source tree). Point your own instance at your own wallet by setting
`OPERATOR_ADDRESS`; the built-in address is obfuscated in
`pool/src/operator.js`, and every payout is on-chain anyway.

Running your own pool is documented in [`pool/README.md`](pool/README.md):
five-minute start, PPLNS and audit log, wallet-rpc payouts, Docker, Render,
Fly.io and the Cloudflare Worker bridge.

## The pool

* **Stratum over TCP and over WebSocket** — the second one is what makes a
  miner work on a host that only allows outbound 443.
* **Every share verified** — the pool runs `zmrig --verify-share` on the blob it
  handed out; a hash that does not match closes the connection instead of being
  paid.
* **PPLNS in BigInt piconero** — no floating point anywhere near money, fee
  rounded down, dust listed rather than absorbed.
* **Auditable** — `/api/audit` and `audit.jsonl` carry the reward, the fee and
  every miner payment for every block.
* **No dependencies** — `node pool/src/index.js`, no `npm install`, no database.
* **Free to host** — one process, one port; Render for WSS, Fly.io for raw TCP,
  a Cloudflare Worker in front if your miners are behind a restrictive network.

```bash
cd pool
node src/index.js --check --config config.json   # validate and exit
node src/index.js --config config.json           # stratum + HTTP
npm test                                         # 28 tests, includes a real miner
```

## Restrictive networks

`--cloudflare` switches the miner to WebSocket over TLS on 443, dials a specific
edge IP when DNS is poisoned (`--connect-to`), and keeps certificate
verification against the real hostname. HTTP CONNECT and SOCKS5 proxies are
supported, and [`worker/`](pool/worker/) is a ready-to-deploy Cloudflare bridge
that turns a WebSocket into a TCP connection to your own pool. Details:
[`doc/NETWORK.md`](doc/NETWORK.md).

## Website

`web/` is a static site — no framework, no build step, no analytics:

* operator documentation in Vietnamese,
* a fleet calculator that prices one machine or a thousand from a `ZMRIG1.` report
  code (computed in the browser, nothing uploaded),
* a **command builder** that assembles the exact install command from the
  options you tick.

```bash
python3 -m http.server -d web 8080    # preview
```

Deploy by pointing Cloudflare Pages or Vercel at the repository with no build
command and `web` as the output directory.

## Build from source

```bash
# C++ miner (Release, native ISA, CPU only)
./scripts/build-optimized.sh
sudo ./scripts/tune-linux.sh
sudo ./build/xmrig -c config/performance.json

# Zig miner
./zmrig/build.sh                        # needs zig 0.13 and g++
./zmrig/out/zmrig -o pool:3333 -u 4YourAddress...
```

Measured on the validation host (2 vCPU): **1084–1089 H/s** from the Zig
frontend, **1075.7 H/s** from the C++ frontend, 813.77 H/s with stock defaults —
the frontend is never the bottleneck, and the tuning scripts are worth more than
any rewrite. See [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md).

## Tests

```bash
./zmrig/tests/run.sh                 # hash vectors and engine conformance
./zmrig/tests/net.sh --soak          # 22 network cases: pools, proxies, WS/TLS
./tests/hash/check.sh                # C++ known-answer suite
node run_tests.js --safe --build-dir build
cd pool && npm test                  # pool unit + protocol + end-to-end
```

## Documentation

* [`doc/INSTALL.md`](doc/INSTALL.md) — installer, options, service layout,
  unattended fleet install, troubleshooting.
* [`pool/README.md`](pool/README.md) — running a pool: configuration, PPLNS,
  payouts, deployment, API.
* [`zmrig/README.md`](zmrig/README.md) — the Zig miner: architecture, build,
  tests, measured hashrate.
* [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) — the code base, thread by thread.
* [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md) — every lever that affects hashrate.
* [`doc/ZERO_FEE.md`](doc/ZERO_FEE.md) — what was removed and how to prove it.
* [`doc/NETWORK.md`](doc/NETWORK.md) — 443-only VPS, proxies, edge dialling.
* [`doc/ALTERNATIVES.md`](doc/ALTERNATIVES.md) — measured comparison with
  Rust/Go miners, and why the C++ RandomX JIT stays.
* [`web/content/vi/`](web/content/vi/) — the same material as a browsable site.

## Mining backends

* **CPU** — x86/x64, ARMv7/ARMv8, RISC-V; RandomX v2, CryptoNight family,
  Argon2, GhostRider, Flex/KCN, Panthera.
* **OpenCL** for AMD GPUs and **CUDA** for NVIDIA GPUs via the external
  [CUDA plugin](https://github.com/xmrig/xmrig-cuda) with `--all-backends`.

## License and funding

XMRig is Copyright (C) 2016-2026 xmrig.com, Copyright (C) 2018-2026 SChernykh,
and the RandomX authors, licensed under **GPL-3.0**. The MoneroOcean additions
are Copyright (C) MoneroOcean. This fork keeps every copyright header and the
licence intact; see [`LICENSE`](LICENSE).

This project is funded by the pool fee, not by donations. If you want to support
it, mine through the pool (or run your own and keep the fee), report a bug with a
measurement attached, or send a patch. There is no donation address in the
miner, and nothing in this tree is wired to one.
