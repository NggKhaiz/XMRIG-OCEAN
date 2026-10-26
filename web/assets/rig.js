// Report decoding and profitability maths for the dashboard.
// Pure functions only: no DOM, no storage. Safe to test in isolation.

(function () {
  "use strict";

  var PREFIX = "ZMRIG1.";
  var CODE_RE = /ZMRIG1\.[A-Za-z0-9_-]+/g;

  var DEFAULTS = {
    window: 1,              // index into hs: 0 = 10 s, 1 = 60 s, 2 = 15 min
    price: 0.10,            // currency per kWh
    psuEff: 87,             // percent, wall = cpu / (eff/100)
    baseW: 25,              // mainboard, disks, NIC, fan overhead
    payoutMode: "pool",     // "pool" | "network"
    xmrPerKhsDay: 0.000096, // pool payout per 1 kH/s per day
    xmrPrice: 300,
    networkHash: 4.5e9,     // H/s
    blockReward: 0.6,       // XMR per block after the 2022 tail emission
    poolFee: 0,             // percent, network mode only
    currency: "USD"
  };

  function b64urlToText(encoded) {
    var padded = encoded.replace(/-/g, "+").replace(/_/g, "/");
    while (padded.length % 4) padded += "=";
    var binary = atob(padded);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder("utf-8").decode(bytes);
  }

  function toNumber(value, fallback) {
    var number = typeof value === "string" ? Number(value) : value;
    return typeof number === "number" && isFinite(number) ? number : fallback;
  }

  function normalise(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("không phải một đối tượng JSON");
    }

    var hs = Array.isArray(raw.hs) ? raw.hs.map(function (v) { return toNumber(v, 0); }) : null;
    if (!hs || hs.length === 0) throw new Error('thiếu trường "hs" (hashrate)');

    while (hs.length < 4) hs.push(hs[hs.length - 1]);

    var power = raw.pw === null || raw.pw === undefined ? null : toNumber(raw.pw, null);
    if (power !== null && power <= 0) power = null;

    return {
      id: String(raw.id || "zmrig").slice(0, 48),
      version: String(raw.ver || ""),
      cpu: String(raw.cpu || "unknown").slice(0, 96),
      arch: String(raw.arch || ""),
      cores: toNumber(raw.cores, 0),
      threads: toNumber(raw.thr, 0),
      algo: String(raw.algo || "auto"),
      mode: String(raw.mode || "auto"),
      hs: hs.slice(0, 4),
      hugePages: Array.isArray(raw.hp) ? raw.hp.map(function (v) { return toNumber(v, 0); }) : [0, 0],
      shares: Array.isArray(raw.shares) ? raw.shares.map(function (v) { return toNumber(v, 0); }) : [0, 0, 0],
      hashes: toNumber(raw.hash, 0),
      uptime: toNumber(raw.up, 0),
      power: power,
      powerSource: String(raw.pwsrc || "none"),
      pool: String(raw.pool || ""),
      ts: toNumber(raw.ts, 0)
    };
  }

  /// Accepts one code, many codes (newline/space/comma separated) or raw JSON.
  function decodeMany(text) {
    var rigs = [];
    var errors = [];
    var trimmed = String(text || "").trim();
    if (!trimmed) return { rigs: rigs, errors: errors };

    var codes = trimmed.match(CODE_RE) || [];

    if (codes.length > 0) {
      codes.forEach(function (code) {
        try {
          var payload = code.slice(PREFIX.length);
          var json = JSON.parse(b64urlToText(payload));
          rigs.push(normalise(json));
        } catch (error) {
          errors.push(code.slice(0, 18) + "…: " + error.message);
        }
      });
      return { rigs: rigs, errors: errors };
    }

    // Raw JSON, one object or an array of them.
    try {
      var parsed = JSON.parse(trimmed);
      var list = Array.isArray(parsed) ? parsed : [parsed];
      list.forEach(function (item) { rigs.push(normalise(item)); });
    } catch (error) {
      errors.push("không tìm thấy mã ZMRIG1.* và chuỗi không phải JSON hợp lệ");
    }

    return { rigs: rigs, errors: errors };
  }

  function mergeSettings(settings) {
    var merged = Object.assign({}, DEFAULTS);
    Object.keys(settings || {}).forEach(function (key) {
      if (key in merged && settings[key] !== null && settings[key] !== undefined && settings[key] !== "") {
        merged[key] = typeof DEFAULTS[key] === "number" ? toNumber(settings[key], DEFAULTS[key]) : settings[key];
      }
    });
    return merged;
  }

  /// `override` is the wall power the user typed for this machine, if any.
  function compute(rig, settings, override) {
    var s = mergeSettings(settings);
    var hashrate = rig.hs[s.window] || rig.hs[0] || 0;

    // A number typed by the user (or passed with --power) is wall power: that
    // is what an electricity meter shows. A number read from RAPL/hwmon is the
    // CPU package only, so it has to be scaled by the PSU efficiency and the
    // rest of the system.
    var measured = override !== null && override !== undefined ? toNumber(override, null) : rig.power;
    var isWall = override !== null && override !== undefined || rig.powerSource === "user";

    var wallWatts = null;
    if (measured !== null && measured > 0) {
      wallWatts = isWall ? measured : measured / (Math.max(s.psuEff, 1) / 100) + s.baseW;
    }

    var cpuWatts = measured === null ? null : (isWall ? null : measured);

    var kwhDay = wallWatts === null ? null : (wallWatts * 24) / 1000;
    var costDay = kwhDay === null ? null : kwhDay * s.price;

    var xmrDay;
    if (s.payoutMode === "network") {
      var blocks = (hashrate / Math.max(s.networkHash, 1)) * 720;
      xmrDay = blocks * s.blockReward * (1 - s.poolFee / 100);
    } else {
      xmrDay = (hashrate / 1000) * s.xmrPerKhsDay;
    }

    var revenueDay = xmrDay * s.xmrPrice;
    var profitDay = costDay === null ? null : revenueDay - costDay;

    return {
      hashrate: hashrate,
      cpuWatts: cpuWatts,
      wallWatts: wallWatts,
      kwhDay: kwhDay,
      costDay: costDay,
      xmrDay: xmrDay,
      revenueDay: revenueDay,
      profitDay: profitDay,
      profitMonth: profitDay === null ? null : profitDay * 30,
      efficiency: wallWatts ? hashrate / wallWatts : null,
      // Price the electricity would have to be for this machine to break even.
      breakEvenPrice: kwhDay ? revenueDay / kwhDay : null
    };
  }

  function totals(rows) {
    var sum = { hashrate: 0, wallWatts: 0, kwhDay: 0, costDay: 0, xmrDay: 0, revenueDay: 0, profitDay: 0, machines: rows.length, unknownPower: 0 };

    rows.forEach(function (row) {
      sum.hashrate += row.result.hashrate || 0;
      sum.xmrDay += row.result.xmrDay || 0;
      sum.revenueDay += row.result.revenueDay || 0;

      if (row.result.wallWatts === null) {
        sum.unknownPower++;
      } else {
        sum.wallWatts += row.result.wallWatts;
        sum.kwhDay += row.result.kwhDay;
        sum.costDay += row.result.costDay;
        sum.profitDay += row.result.profitDay;
      }
    });

    sum.efficiency = sum.wallWatts ? sum.hashrate / sum.wallWatts : null;
    sum.kwhMonth = sum.kwhDay * 30;
    sum.profitMonth = sum.profitDay * 30;

    return sum;
  }

  window.zmrigRig = {
    PREFIX: PREFIX,
    DEFAULTS: DEFAULTS,
    decodeMany: decodeMany,
    normalise: normalise,
    compute: compute,
    totals: totals,
    mergeSettings: mergeSettings
  };
})();
