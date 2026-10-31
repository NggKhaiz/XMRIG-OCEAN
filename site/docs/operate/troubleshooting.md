---
title: Troubleshooting
description: A symptom-to-cause table for the failures that actually happen, the bugs that were fixed so they cannot happen again, and what to include in a bug report.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Troubleshooting

## Symptom → cause

| Symptom | Usual cause | What to do |
| --- | --- | --- |
| `dataset ready` takes 20–30 s | normal: building 2 GiB | not a fault; `--mode light` takes 0.6 s but keeps 9 % of the hashrate |
| 20–30 % below expected hashrate | huge pages were not granted | `grep HugePages /proc/meminfo`; the log must say `huge pages 2336 MB` |
| the process is killed, exit 137 | out of RAM while building the dataset (huge pages already hold the rest) | fix the huge-page reservation, or use `--mode light` |
| `cannot read …: check the path or run as root` | the config is root-only | run with `sudo` |
| `config ok` but nothing mines | no `-c`, or no pool given | `--check` only inspects the file it was given |
| `login failed: …` repeats | wrong wallet or pool, banned IP, wrong TLS mode | read the line after it; try `--transport tcp` to rule TLS out |
| `connection lost` repeatedly | a CDN or NAT dropping a silent socket | `--keepalive-interval 60`, `--idle-timeout 120` |
| `share rejected: …` | stale job or difficulty, or the machine clock drifting | check `timedatectl`; read the pool's own message |
| API returns 401 | an access token is configured | send `Authorization: Bearer TOKEN` |
| API unreachable from another machine | it binds `127.0.0.1` by design | do not expose it; use an SSH tunnel |
| `--tls-ca` has no effect | the file is in `/tmp` and the unit uses `PrivateTmp` | put it at `/etc/zmrig/tls-ca.pem` |

## Bugs that were fixed, so you do not have to meet them

- **`--background` was ignored** and the miner stayed in the foreground. It now
  forks, calls `setsid` and closes stdio.
- **Reconnects were slow and then a storm.** It waited the full `--retry-pause`
  after every drop and reset its counter on pool rotation, so a dead pool was
  hammered. Now: reconnect immediately after a session that had logged in, then
  200 ms → 500 ms → 1 s → `--retry-pause`, with a counter that does not reset.
- **Log files contained ANSI colour escapes.** Files are plain text; stdout keeps
  colour.
- **Command-line flags used to overwrite config values with defaults.**
  `zmrig -c config.json --verbose` reset `mode`, `huge-pages`, `retries`. Only
  flags you actually type override now.
- **`report.enabled` in the config started `--report`** (measure, print, exit)
  instead of only writing the report file. The two are separate now.
- **`--tls` used to imply "do not verify the certificate".** It only selects the
  transport; verification stays on.
- **One very long line from a pool killed the session.** The line is dropped and
  warned about once when the session ends.
- **`--http-port` never reached the config.** Fixed; the installer writes the
  `enabled` boolean correctly.
- **Ctrl-C hung while waiting for a login.** The monitor closes the socket so the
  main thread can exit.
- **A client that opened the API socket and went silent blocked the API thread.**
  Every connection now has a 5-second timeout.

## Questions that come up

**Is `--mode light` usable on a 1 GB VPS?**
It runs, at about 9 % of the hashrate (76 H/s against 814 H/s). Fine for keeping
a connection or testing a config; for real mining, pick a VPS with at least
2.5 GB.

**How many threads?**
`L3 cache / 2 MiB` is right most of the time. If the VPS is throttled, drop one
thread and measure again.

**Should a local pool use TLS?**
On the same machine or a private network, TLS costs CPU and adds no real
security. Use it over the internet or through a CDN.

**Can it mine to several pools at once?**
Yes: several `-o` flags, or several entries in `pools[]`. It tries them in order
and fails over after `--retries` failures.

**Does the API slow the miner down?**
No. It reads atomics that are updated once a second and never locks a worker.

**How long until the first share?**
Depends on pool difficulty: seconds on a test pool, minutes to hours on a real
one with a small machine. A slow share is not a fault — check the hashrate and
look for `pool has been silent`.

**How do I know the miner is mining to the right wallet?**
`zmrig --check` prints `user=…`, the API returns `connection.pool`, and the
startup log prints `wallet: …`. Compare with the dashboard of the pool.

## Reporting a bug

```bash
zmrig --version
sudo ./oneclick.sh status
sudo ./oneclick.sh logs 80
sed 's/"user": *"[^"]*"/"user": "REDACTED"/' /etc/zmrig/config.json
```

Redact the wallet and any token before pasting. The log alone usually shows
whether the failure is transport, TLS or the pool itself.
