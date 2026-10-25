# One-click install

`oneclick.sh` turns a bare Linux machine into a tuned, supervised, fee-free
RandomX miner. One command, no manual steps, safe to re-run.

```bash
# on a fresh machine (clones the repository for you)
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/XMRIG-OCEAN/arena/918a7f95-xmrig-ocean/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress...

# or inside a checkout
sudo ./oneclick.sh --wallet 4YourMoneroAddress...
```

That single command:

1. detects the distribution and installs the build dependencies (cmake, C++,
   libuv, OpenSSL) with `apt`/`dnf`/`pacman`/`zypper`/`apk`/`brew`;
2. builds a Release binary tuned for the exact CPU it runs on;
3. reserves huge pages for the RandomX dataset, sets THP to `madvise`, pins the
   governor to `performance` and enables the MSR module;
4. writes a validated config with your wallet, the pool and safe defaults;
5. installs the binary and a `systemd` service that restarts on failure and a
   oneshot unit that re-applies the tuning on every boot;
6. starts it, waits for the first real hashrate, runs the 0 %-fee audit and
   prints a summary card.

End state:

| Path | What |
|---|---|
| `/usr/local/bin/xmrig-ocean` | the miner |
| `/usr/local/bin/xmrig-ocean-tune` | host tuning (`--status`, `--hugepages 1G`, …) |
| `/usr/local/bin/xmrig-ocean-bench` | reproducible hashrate measurement |
| `/usr/local/bin/xmrig-ocean-verify` | proves the binary has no developer fee |
| `/etc/xmrig-ocean/config.json` | configuration (rewritten by autosave) |
| `xmrig-ocean.service` | supervised miner, `Restart=always`, `Nice=-10` |
| `xmrig-ocean-tune.service` | oneshot tuner, runs before the miner at boot |
| `http://127.0.0.1:18080/2/summary` | live API used by `status` |

```bash
sudo ./oneclick.sh status     # service state, hashrate, accepted shares
sudo ./oneclick.sh logs       # last 40 log lines (journal)
sudo ./oneclick.sh bench      # 180 s RandomX measurement
sudo ./oneclick.sh verify     # fee audit
sudo ./oneclick.sh update     # git pull + rebuild + restart
sudo ./oneclick.sh uninstall  # stop, disable, remove binaries
```

---

## Options

| Option | Meaning |
|---|---|
| `--wallet ADDR` | Monero address (95 chars) or pool login. Asked interactively when omitted. |
| `--pool HOST:PORT` | pool endpoint, default `gulf.moneroocean.stream:10001` |
| `--pass VALUE` | pool password, default `x` |
| `--rig-id NAME` | name shown on the pool dashboard |
| `--algo NAME` | pin one algorithm (`rx/0`, `cn/r`, …). Also **skips the 2-minute calibration**, see below. |
| `--engine NAME` | `xmrig` (default, every algorithm) or `zmrig` (the Zig miner, RandomX only). See [The Zig engine](#the-zig-engine). |
| `--tls` | TLS stratum |
| `--cpu-hint N` | `max-threads-hint`, default `100` |
| `--all-backends` | also build OpenCL/CUDA support |
| `--no-tune` | do not touch huge pages / MSR / governor |
| `--no-service` | configure only, do not install a service |
| `--no-build` | reuse an existing build directory |
| `--build-dir DIR` | where to compile (default `/usr/local/src/xmrig-ocean-build`) |
| `--prefix DIR` | install prefix (default `/usr/local`) |
| `--force` | regenerate the config even if it exists |
| `--yes` | never prompt |

Environment variables for unusual setups: `UV_INCLUDE_DIR`, `UV_LIBRARY`
(locally built libuv), `MINER_REPO_URL`, `MINER_BRANCH`, `MINER_POOL`,
`MINER_PASS`, `MINER_PREFIX`, `MINER_CONFIG_DIR`, `MINER_STATE_DIR`,
`MINER_ENGINE` (same as `--engine`), `MINER_ZIG_VERSION` (default `0.13.0`).

---

## The Zig engine

`--engine zmrig` builds and installs `zmrig`, the Zig miner from `zmrig/`
instead of the C++ frontend. It is the same RandomX engine, the same config
file, the same service and the same helpers — only the process in front of the
hash loop changes.

```bash
sudo ./oneclick.sh install --yes --wallet 4YourAddress... --engine zmrig --algo rx/0
sudo ./oneclick.sh status      # identical output, hashrate comes from the zmrig log
sudo ./oneclick.sh bench       # runs zmrig --bench=N (default 20000 hashes)
sudo ./oneclick.sh verify      # --self-test + strings|grep -c donat
```

Differences worth knowing:

| | `xmrig` (default) | `zmrig` |
|---|---|---|
| algorithms | all backends/algorithms in this fork | RandomX family only (`rx/0`, `rx/2`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada`, `panthera`) |
| build deps | cmake, libuv, OpenSSL, hwloc | `g++`, `ar`, zig 0.13 (installed automatically) |
| binary | `/usr/local/bin/xmrig-ocean` | `/usr/local/bin/zmrig` + `xmrig-ocean` symlink |
| measured | 1075.7 H/s (`scripts/bench.sh`) | 1084–1089 H/s installed, 1.08–1.10 kH/s `--bench` |
| TLS | full (including `--tls-insecure`) | full verification only (Zig 0.13 has no "skip verify") |
| self-test | — | `zmrig --self-test` (vectors + 2 GiB dataset) |

The chosen engine is recorded in `/etc/xmrig-ocean/engine`, so the subcommands
that run later (`status`, `logs`, `bench`, `verify`, `start`, …) pick the same
binary without repeating `--engine`. Passing `--engine` again overrides it.

Host tuning still applies: without huge pages the Zig miner falls back to
`mmap`'d pages and loses ~10%, exactly like the C++ one.

---

## Calibration on first start

MoneroOcean pools choose the most profitable algorithm using the `algo-perf`
table the miner reports at login. On the very first start (and after
`--rebench-algo`) the miner measures every algorithm for ~10 s each, which takes
about two minutes before the first share. The installer detects this and keeps
waiting instead of reporting a failure.

If you pinned an algorithm with `--algo`, that table is never used, so this fork
**skips the calibration** and connects immediately.

The result is stored in `config.json` under `algo-perf`, so later starts are
instant. Re-calibrate only after a hardware change:

```bash
sudo systemctl stop xmrig-ocean
sudo /usr/local/bin/xmrig-ocean -c /etc/xmrig-ocean/config.json --rebench-algo
```

---

## Unattended fleet install

```bash
for host in rig01 rig02 rig03; do
  ssh "$host" "curl -fsSL https://raw.githubusercontent.com/NggKhaiz/XMRIG-OCEAN/arena/918a7f95-xmrig-ocean/oneclick.sh \
    | sudo bash -s -- --yes --wallet 4... --rig-id $host"
done
```

The rig id defaults to the hostname, and the config is never overwritten on a
second run, so re-running the same command is a cheap idempotent "ensure it is
installed and running".

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `libuv headers were not found` | no `libuv1-dev` and no network for the package manager | install it, or build libuv and pass `UV_INCLUDE_DIR`/`UV_LIBRARY` |
| `the miner rejected the generated config` | wallet contains an unescaped character | re-run with a clean wallet, or edit `/etc/xmrig-ocean/config.json` and `systemctl restart xmrig-ocean` |
| `no hashrate after …s` and the log shows `connect error` | pool unreachable / firewall | `sudo ./oneclick.sh config --force --pool another.pool:port ...` |
| `huge pages are not fully allocated` in the log | tuning did not run (non-root, container) | `sudo /usr/local/bin/xmrig-ocean-tune` then restart the service |
| `FAILED TO APPLY MSR MOD` | kernel module missing or a hypervisor that blocks MSR writes | run `modprobe msr`; inside VMs this is expected and harmless |
| service restarts in a loop | config or binary replaced while running | `sudo ./oneclick.sh logs` then `systemctl status xmrig-ocean` |
| systemd is not available (container) | — | the installer falls back to a background process with a pidfile in `/var/lib/xmrig-ocean/` |

`./oneclick.sh status` prints service state, live hashrate, accepted shares, huge
page count and the log tail, which covers most of the table above.

### Benchmarking while the service runs

`./oneclick.sh bench` stops the service, runs the benchmark with the full huge
page reservation, and restarts it. Doing that by hand
(`xmrig --bench=1M` next to a running miner) shares the reservation between two
processes, and XMRig reacts by grabbing *more* pages, which on a small machine
is both slower and risky. Use `oneclick.sh bench` or stop the unit first.
