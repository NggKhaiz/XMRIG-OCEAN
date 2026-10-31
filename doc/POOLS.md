# Choosing a pool, and not getting the IP banned

Two costs are missing from every hashrate chart: a pool that quietly pays less
than it advertises, and an IP that cannot connect any more. The first is a
percentage, the second is 100 % of the income.

Everything below was checked against the pools' own pages or their published
stats (`cryptunit`, the pools' port tables, `xmrpool.eu`'s FAQ, `xmr.pub`) in
October 2026. Fees and minimums change; ports and ban policies change less.
`./oneclick.sh plan --pool=<name>` prints what this repository will use.

## The short version

| | Pool | Fee | Min payout | Scheme | Endpoint |
|---|---|---:|---:|---|---|
| **1** | MoneroOcean | 0 % | 0.003 XMR | PPLNS, algo-switching | `gulf.moneroocean.stream:10001` |
| **2** | SupportXMR | 0.6 % | 0.1 XMR | PPLNS | `pool.supportxmr.com:3333` |
| 3 | C3Pool | 0 % | 0.003 XMR | PPLNS | `c3pool.com:3333` |
| — | P2Pool (via `xmr.pub`) | 0 % | ~0.0004 XMR | PPLNS, decentralised | `pool.xmr.pub:3333` mini · `:3334` nano |
| — | HeroMiners | 0.9 % | 0.01 XMR | PPLNS | `monero.herominers.com:10191` |
| — | xmrpool.eu | 0.9 % | 0.07 XMR | PPLNS | `xmrpool.eu:3333`, `:443` for firewalls |

Short names work as `--pool=<name>`: `moneroocean`, `supportxmr`, `c3pool`,
`xmrpool`, `herominers`, `p2pool`, `p2pool-nano`.

Why this order:

1. **MoneroOcean pays the most per hash on a CPU**, because it moves the rig to
   whichever RandomX-family coin is worth more at that moment and pays out in
   XMR. Third-party reviews put the gain at 10–30 % over a single-algorithm
   pool, which is larger than any fee difference in the table. Requires
   `--algo=auto` (the default here) so the pool knows the rig can be moved.
2. **SupportXMR is the low-variance option.** It is the largest pool, finds
   blocks often, and pays 0.6 % for it. Pick it when a predictable daily number
   matters more than the maximum, or as the backup pool behind MoneroOcean.
3. **C3Pool** is 0 % with a 0.003 XMR minimum — the same shape as MoneroOcean
   without the switching. Good second backup.

## Anti-ban rules the software now enforces

Pools ban IPs for three reasons, and all three used to be invisible:

| Cause | What a naive miner does | What this repository does |
|---|---|---|
| Wrong wallet, wrong port, TLS where plain is expected | retries every 5 s, forever, from the same IP | identifies the refusal, **stops retrying that pool for 30 min**, prints the fix (`zmrig/src/stratum.zig`, `proxy/src/upstream.js`) |
| `your IP is banned` | reconnects immediately, which extends the ban | cools that pool for 15 min and moves to the next one |
| Overclocked/broken rig submits invalid shares | keeps submitting, gets a 10 min → 1 h ban (`xmrpool.eu` policy) | after 3 invalid shares, **pauses submissions for 10 min** and says why (`miner.zig`) |
| Twenty rigs rebooting together | identical reconnect timing = login flood | every retry is jittered ±20 % |

The cooldown is per pool, not global: a pool that refused the wallet does not
stop the backup pool from working. `--ban-cooldown=<seconds>` tunes it
(default 900); the wallet/password case is clamped to at least 30 minutes,
because that one never fixes itself by waiting a few seconds.

## Not being blocked — the part nobody tests

In practice a rig loses its connection far more often to **DNS filtering** than
to a pool ban. Documented cases: Quad9 (`9.9.9.9`) returns NXDOMAIN for
`gulf.moneroocean.stream`, and Cloudflare's malware-filtering resolver
(`1.1.1.2`) does the same for `pool.supportxmr.com`. Some ISPs filter mining
domains wholesale, and some corporate/VPS networks block every port except 80
and 443.

Four things survive that, in order of preference:

1. **A backup pool with a different domain.** `--failover=moneroocean,c3pool`
   writes extra pool objects into `config.json`; the miner only uses them when
   the first is unreachable or refuses this IP.
2. **A regional hostname** (same pool, different DNS name — useful when only the
   default alias is filtered). MoneroOcean publishes `us-or`, `us-va`, `us-oh`,
   `de`, `fi`, `fr`, `jp` and `sg` prefixes; SupportXMR has `eu`/`us`/`asia`
   endpoints on its own site.
3. **Port 443 with TLS**, which looks like ordinary HTTPS:
   - MoneroOcean `gulf.moneroocean.stream:443` (also `20128`, `20032`)
   - SupportXMR `pool.supportxmr.com:443` (also `9000`)
   - xmrpool.eu `xmrpool.eu:443` ("for firewall bypass", per their port list)

   Use `--pool=tls://host:443` (or `tls://` in the failover list) so the miner
   knows the port wants TLS.
4. **`--connect-to`** with an IP address the operator resolved elsewhere. This
   keeps TLS SNI and the pool's virtual host correct while bypassing a broken
   resolver:

   ```bash
   dig +short gulf.moneroocean.stream   # from a network that can resolve it
   zmrig -o gulf.moneroocean.stream:10001 --connect-to 1.2.3.4:10001 -u <wallet>
   ```

The last one is a workaround, not a fix: if the address changes, mining stops.
Prefer 1–3.

## What is still not handled

- **Geo-blocking by the pool itself** (a pool refusing whole countries) is not
  detectable from the client — it arrives as a plain refusal. The cooldowns keep
  it from turning into a ban, but nothing can make that pool work.
- **IPv6-only networks**: the miner dials what DNS returns; if the only AAAA
  record is filtered, use option 4.
- **Pool-side rate limits on *shares*** (not logins) exist on some pools; this
  software observes them as rejects and the invalid-share quarantine stops the
  stream, but the correct fix is a lower `--target-share` locally, i.e. fewer,
  larger shares.

## Choosing between MoneroOcean and SupportXMR, concretely

Run both for a week with the proxy's `/status` (see `doc/PROXY.md` §7b) and
compare `xmrPerDay` at the same `hashrate`:

```bash
# week 1
./oneclick.sh install --pool=moneroocean --wallet=<wallet>
# week 2
./oneclick.sh install --pool=supportxmr --wallet=<wallet> --failover=moneroocean
```

MoneroOcean wins when the switching premium is real for this CPU (it varies with
which coins are hot); SupportXMR wins when it is not, and always wins on
variance. Measure, then decide — the numbers move month to month.

## Pools for the other coins

Every row above is a Monero pool. The engines also hash Wownero, ArQmA, Graft,
Safex Cash, YadaCoin and Scala (`--coin`, see `doc/SETUP.md` §5b), and this
repository deliberately keeps **no** endpoint or fee for those: they change, and
a stale hostname sends a rig to a dead pool for a week. Take `host:port` from the
coin's own community and pass it to `--pool`.

```bash
sudo ./oneclick.sh install --coin wow --pool pool.example.org:3333 --wallet=Wo...
```

A switching pool (MoneroOcean and clones) is still the simplest way to end up on
whatever pays best: leave `--coin` off, and the rig advertises the whole RandomX
family at login.
