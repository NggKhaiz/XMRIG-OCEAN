// The pool table, in one place.
//
// The documentation table, the command builder, the failover picker and the
// site's tests all read this file. `site/tests/pools.test.mjs` compares it
// against `oneclick.sh`'s presets and against `doc/POOLS.md`, so a fee or an
// endpoint cannot be right in one place and stale in another.
//
// Figures checked October 2026 against each pool's own pages (fee, minimum
// payout, port list). Fees change; hostnames and ban policies change less.

export const POOLS = [
  {
    id: "moneroocean",
    name: "MoneroOcean",
    host: "gulf.moneroocean.stream:10001",
    tlsHost: "gulf.moneroocean.stream:443",
    fee: 0,
    min: 0.003,
    switching: true,
    tag: "highest",
    why: {
      en: "Pays the most per hash: the pool moves the rig to whichever RandomX coin is paying best and settles in XMR. Needs --algo=auto, which is the default.",
      vi: "Trả nhiều nhất trên mỗi hash: pool tự chuyển rig sang đồng RandomX đang trả cao nhất rồi quyết toán bằng XMR. Cần --algo=auto, đây là mặc định.",
    },
  },
  {
    id: "supportxmr",
    name: "SupportXMR",
    host: "pool.supportxmr.com:3333",
    tlsHost: "pool.supportxmr.com:443",
    fee: 0.6,
    min: 0.1,
    switching: false,
    tag: "steady",
    why: {
      en: "The largest pool, so blocks are found often and the daily number moves less. Pick it when you want a steady figure rather than the maximum.",
      vi: "Pool lớn nhất nên tìm block thường xuyên, con số hằng ngày ít dao động. Chọn khi cần thu nhập đều hơn là tối đa.",
    },
  },
  {
    id: "c3pool",
    name: "C3Pool",
    host: "c3pool.com:3333",
    tlsHost: null,
    fee: 0,
    min: 0.003,
    switching: false,
    tag: "",
    why: {
      en: "Zero fee and a low minimum like MoneroOcean, without algorithm switching. The best failover pool because the infrastructure is completely different.",
      vi: "Phí 0 % và minimum thấp như MoneroOcean nhưng không chuyển thuật toán. Là pool dự phòng tốt nhất vì hạ tầng khác hẳn.",
    },
  },
  {
    id: "herominers",
    name: "HeroMiners",
    host: "monero.herominers.com:10191",
    tlsHost: null,
    fee: 0.9,
    min: 0.01,
    switching: false,
    tag: "",
    why: {
      en: "The lowest minimum (0.01 XMR) among the fee-charging pools. Fine for a small rig, but 0.9 % comes out of the payout.",
      vi: "Minimum thấp nhất (0.01 XMR) trong nhóm pool có phí. Hợp với rig nhỏ, nhưng 0,9 % bị trừ vào payout.",
    },
  },
  {
    id: "xmrpool",
    name: "xmrpool.eu",
    host: "xmrpool.eu:3333",
    tlsHost: "xmrpool.eu:443",
    fee: 0.9,
    min: 0.07,
    switching: false,
    tag: "",
    why: {
      en: "Has its own TLS port on 443 for filtered networks, but the strictest ban policy of the group: three bad shares means ten minutes, then an hour. zmrig stops before that line.",
      vi: "Có cổng TLS 443 riêng cho mạng bị chặn, nhưng chính sách ban chặt nhất: ba share sai là 10 phút, sau đó là 1 giờ. zmrig tự dừng trước mốc đó.",
    },
  },
  {
    id: "p2pool",
    name: "P2Pool mini",
    host: "pool.xmr.pub:3333",
    tlsHost: null,
    fee: 0,
    min: 0.0004,
    switching: false,
    tag: "p2p",
    why: {
      en: "No pool owner and no fee; pays out with every block found. The most frequent payouts and the most variance.",
      vi: "Không có chủ pool, không có phí, trả theo từng block tìm được. Payout thường xuyên nhất nhưng biến động nhất.",
    },
  },
  {
    id: "p2pool-nano",
    name: "P2Pool nano",
    host: "pool.xmr.pub:3334",
    tlsHost: null,
    fee: 0,
    min: 0.0004,
    switching: false,
    tag: "p2p",
    why: {
      en: "The even lighter P2Pool sidechain: fits a 1 vCPU VPS, but fewer shares mean smaller, scarcer payouts.",
      vi: "Sidechain P2Pool còn nhẹ hơn: hợp VPS 1 vCPU, đổi lại ít share hơn nên payout nhỏ và thưa hơn.",
    },
  },
];

const byId = new Map(POOLS.map((pool) => [pool.id, pool]));

/** Accepts a short id, a host:port, or a tls:// URL (including a tlsHost). */
export function findPool(value) {
  if (!value) return null;
  const key = String(value).toLowerCase().replace(/^tls:\/\//, "");
  if (byId.has(key)) return byId.get(key);
  return (
    POOLS.find((pool) => pool.host === key) ??
    POOLS.find((pool) => pool.tlsHost === key) ??
    null
  );
}

/** The host:port the installer will be given for a preset. */
export function presetEndpoint(id) {
  const pool = byId.get(String(id || "").toLowerCase());
  return pool ? pool.host : "";
}

/** Short names `oneclick.sh --pool=` accepts, in table order. */
export function presetNames() {
  return POOLS.map((pool) => pool.id);
}

/** Locale-aware fee label: "0 %", "0,6 %" (vi), "0.6 %" (en). */
export function feeLabel(pool, locale = "en") {
  if (!pool || typeof pool.fee !== "number") return "";
  const text = Number.isInteger(pool.fee) ? String(pool.fee) : pool.fee.toFixed(1);
  return (locale === "vi" ? text.replace(".", ",") : text) + " %";
}

/** Locale-aware minimum payout label. */
export function minLabel(pool, locale = "en") {
  if (!pool || typeof pool.min !== "number") return "";
  const text = String(pool.min);
  return (locale === "vi" ? text.replace(".", ",") : text) + " XMR";
}
