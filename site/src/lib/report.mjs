// ZMRIG1. report codes and the profitability maths.
//
// Pure functions only: no DOM, no storage, no clock. The calculator renders the
// result; `site/tests/report.test.mjs` checks the arithmetic against numbers
// computed by hand, because a wrong constant here is a wrong payout estimate on
// every machine in the fleet.
//
// What a code contains (and what it cannot): the miner's own measurements —
// hashrate windows, shares, uptime, power if it could read it. No wallet, no
// pool token, no hostname.

export const PREFIX = "ZMRIG1.";
const CODE_RE = /ZMRIG1\.[A-Za-z0-9_-]+/g;

export const DEFAULTS = {
  window: 1, // index into hs: 0 = 10 s, 1 = 60 s, 2 = 15 min, 3 = session best
  price: 0.1, // currency per kWh
  psuEff: 87, // percent; wall = cpu / (eff/100)
  baseW: 25, // mainboard, disks, NIC, fan overhead
  payoutMode: "pool", // "pool" | "network"
  xmrPerKhsDay: 0.000096, // pool payout per 1 kH/s per day
  xmrPrice: 300,
  networkHash: 4.5e9, // H/s
  blockReward: 0.6, // XMR per block after the 2022 tail emission
  poolFee: 0, // percent, network mode only
};

function b64urlToText(encoded) {
  const padded = encoded.replace(/-/g, "+").replace(/_/g, "/");
  const withPad = padded + "=".repeat((4 - (padded.length % 4)) % 4);
  const binary = atob(withPad);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder("utf-8").decode(bytes);
}

function toNumber(value, fallback) {
  const number = typeof value === "string" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) ? number : fallback;
}

export function normalise(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("not a JSON object");
  }

  const hs = Array.isArray(raw.hs) ? raw.hs.map((v) => toNumber(v, 0)) : null;
  if (!hs || hs.length === 0) throw new Error('missing "hs"');

  const windows = hs.slice(0, 4);
  while (windows.length < 4) windows.push(windows[windows.length - 1]);

  let power = raw.pw === null || raw.pw === undefined ? null : toNumber(raw.pw, null);
  if (power !== null && power <= 0) power = null;

  return {
    id: String(raw.id || "zmrig").slice(0, 48),
    version: String(raw.ver || ""),
    cpu: String(raw.cpu || "unknown").slice(0, 96),
    arch: String(raw.arch || ""),
    threads: toNumber(raw.thr, 0),
    algo: String(raw.algo || "auto"),
    mode: String(raw.mode || "auto"),
    hs: windows,
    hugePages: Array.isArray(raw.hp) ? raw.hp.map((v) => toNumber(v, 0)) : [0, 0],
    shares: Array.isArray(raw.shares)
      ? raw.shares.map((v) => toNumber(v, 0))
      : [0, 0, 0],
    uptime: toNumber(raw.up, 0),
    power,
    powerSource: String(raw.pwsrc || "none"),
    health: typeof raw.health === "string" ? raw.health : "",
    hashesPerWatt: raw.hw === null || raw.hw === undefined ? null : toNumber(raw.hw, null),
    pool: String(raw.pool || ""),
    ts: toNumber(raw.ts, 0),
  };
}

/** One code, many codes, or raw JSON. Returns rigs plus per-code errors. */
export function decodeMany(text) {
  const rigs = [];
  const errors = [];
  const trimmed = String(text || "").trim();
  if (!trimmed) return { rigs, errors };

  const codes = trimmed.match(CODE_RE) || [];

  if (codes.length > 0) {
    for (const code of codes) {
      try {
        rigs.push(normalise(JSON.parse(b64urlToText(code.slice(PREFIX.length)))));
      } catch (error) {
        errors.push({ code: code.slice(0, 18) + "…", reason: error.message });
      }
    }
    return { rigs, errors };
  }

  try {
    const parsed = JSON.parse(trimmed);
    for (const item of Array.isArray(parsed) ? parsed : [parsed]) {
      rigs.push(normalise(item));
    }
  } catch {
    errors.push({ code: trimmed.slice(0, 18), reason: "no ZMRIG1. code and not JSON" });
  }

  return { rigs, errors };
}

export function mergeSettings(settings) {
  const merged = { ...DEFAULTS };
  for (const [key, value] of Object.entries(settings || {})) {
    if (!(key in merged) || value === null || value === undefined || value === "") continue;
    merged[key] = typeof DEFAULTS[key] === "number" ? toNumber(value, DEFAULTS[key]) : value;
  }
  return merged;
}

/**
 * One machine: hashrate in, money out.
 *
 * `override` is wall power the user typed for this machine; a number the miner
 * read from RAPL/hwmon is CPU package only and is scaled by PSU efficiency plus
 * the rest of the system. `--power` is wall, by definition.
 */
export function compute(rig, settings, override) {
  const s = mergeSettings(settings);
  const hashrate = rig.hs[s.window] || rig.hs[0] || 0;

  const hasOverride = override !== null && override !== undefined && override !== "";
  const measured = hasOverride ? toNumber(override, null) : rig.power;
  const isWall = hasOverride || rig.powerSource === "user";

  let wallWatts = null;
  if (measured !== null && measured > 0) {
    wallWatts = isWall ? measured : measured / (Math.max(s.psuEff, 1) / 100) + s.baseW;
  }

  const kwhDay = wallWatts === null ? null : (wallWatts * 24) / 1000;
  const costDay = kwhDay === null ? null : kwhDay * s.price;

  let xmrDay;
  if (s.payoutMode === "network") {
    const blocks = (hashrate / Math.max(s.networkHash, 1)) * 720;
    xmrDay = blocks * s.blockReward * (1 - s.poolFee / 100);
  } else {
    xmrDay = (hashrate / 1000) * s.xmrPerKhsDay;
  }

  const revenueDay = xmrDay * s.xmrPrice;
  const profitDay = costDay === null ? null : revenueDay - costDay;

  return {
    hashrate,
    cpuWatts: measured === null || isWall ? null : measured,
    wallWatts,
    kwhDay,
    costDay,
    xmrDay,
    revenueDay,
    profitDay,
    profitMonth: profitDay === null ? null : profitDay * 30,
    efficiency: wallWatts ? hashrate / wallWatts : null,
    // The price electricity would have to be for this machine to break even.
    breakEvenPrice: kwhDay ? revenueDay / kwhDay : null,
  };
}

/** Totals across a fleet. Machines with unknown power are counted, not guessed. */
export function totals(rows) {
  const sum = {
    machines: rows.length,
    hashrate: 0,
    wallWatts: 0,
    kwhDay: 0,
    costDay: 0,
    xmrDay: 0,
    revenueDay: 0,
    profitDay: 0,
    unknownPower: 0,
  };
  let meteredRevenue = 0;

  for (const row of rows) {
    const r = row.result;
    sum.hashrate += r.hashrate || 0;
    sum.xmrDay += r.xmrDay || 0;
    sum.revenueDay += r.revenueDay || 0;
    if (r.wallWatts === null) {
      sum.unknownPower += 1;
    } else {
      sum.wallWatts += r.wallWatts;
      sum.kwhDay += r.kwhDay;
      sum.costDay += r.costDay;
      sum.profitDay += r.profitDay;
      // Revenue of the metered machines only: see breakEvenPrice below.
      meteredRevenue += r.revenueDay;
    }
  }

  sum.efficiency = sum.wallWatts ? sum.hashrate / sum.wallWatts : null;
  sum.kwhMonth = sum.kwhDay * 30;
  sum.profitMonth = sum.profitDay * 30;
  // The electricity price at which the fleet stops making money: revenue of the
  // machines whose power is known, divided by their energy. Using the whole
  // fleet's revenue against only part of its energy would overstate the number,
  // and a fleet with no known power cannot answer at all — null, not 0.
  sum.breakEvenPrice = sum.kwhDay ? meteredRevenue / sum.kwhDay : null;
  return sum;
}
