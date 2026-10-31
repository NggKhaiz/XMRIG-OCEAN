// The pool table, in one place.
//
// The wizard, the quick builder on the home page and the failover picker all
// read from here, so a fee or an endpoint can never be right in one place and
// stale in another. `web/tests/pools.test.js` compares this file against
// doc/POOLS.md and against oneclick.sh's `pool_preset()`; if the three drift,
// the test fails instead of a visitor pasting the wrong host.
//
// Figures checked October 2026 against the pools' own pages (fees, minimum
// payout, port list). Fees change; hostnames and ban policies change less.

(function (root) {
  "use strict";

  var POOLS = [
    {
      id: "moneroocean",
      name: "MoneroOcean",
      short: "MO",
      host: "gulf.moneroocean.stream:10001",
      tlsPort: "gulf.moneroocean.stream:443",
      fee: 0,
      min: 0.003,
      switching: true,
      tag: "best",
      why: "Trả nhiều nhất trên CPU: tự chuyển rig sang đồng RandomX đang đắt nhất rồi trả bằng XMR. Cần --algo=auto, đây là mặc định.",
      cadence: "khi vượt 0.003 XMR"
    },
    {
      id: "supportxmr",
      name: "SupportXMR",
      short: "SX",
      host: "pool.supportxmr.com:3333",
      tlsPort: "pool.supportxmr.com:443",
      fee: 0.6,
      min: 0.1,
      switching: false,
      tag: "steady",
      why: "Pool lớn nhất, tìm block thường xuyên nên thu nhập ít dao động. Chọn khi cần con số hằng ngày ổn định hơn là tối đa.",
      cadence: "mỗi 0.1 XMR — lâu hơn, nhưng đều"
    },
    {
      id: "c3pool",
      name: "C3Pool",
      short: "C3",
      host: "c3pool.com:3333",
      tlsPort: null,
      fee: 0,
      min: 0.003,
      switching: false,
      tag: "",
      why: "0 % phí, minimum thấp như MoneroOcean nhưng không chuyển thuật toán. Pool dự phòng tốt nhất vì khác hẳn hạ tầng.",
      cadence: "mỗi 0.003 XMR"
    },
    {
      id: "herominers",
      name: "HeroMiners",
      short: "HM",
      host: "monero.herominers.com:10191",
      tlsPort: null,
      fee: 0.9,
      min: 0.01,
      switching: false,
      tag: "",
      why: "Minimum 0.01 XMR — thấp nhất trong nhóm pool tập trung có phí. Hợp với rig nhỏ, nhưng phí 0.9 % ăn vào thu nhập.",
      cadence: "mỗi 0.01 XMR"
    },
    {
      id: "xmrpool",
      name: "xmrpool.eu",
      short: "EU",
      host: "xmrpool.eu:3333",
      tlsPort: "xmrpool.eu:443",
      fee: 0.9,
      min: 0.07,
      switching: false,
      tag: "",
      why: "Có cổng 443 TLS riêng cho mạng chặn, nhưng chính sách ban chặt nhất: 3 share sai là 10 phút, tiếp theo là 1 giờ. zmrig đã tự dừng trước mốc đó.",
      cadence: "mỗi 0.07 XMR"
    },
    {
      id: "p2pool",
      name: "P2Pool mini",
      short: "P2",
      host: "pool.xmr.pub:3333",
      tlsPort: null,
      fee: 0,
      min: 0.0004,
      switching: false,
      tag: "p2p",
      why: "Không có chủ pool, không có phí, trả theo từng block tìm được. Nhận payout thường xuyên nhất nhưng biến động nhất.",
      cadence: "theo block, ~0.0004 XMR"
    },
    {
      id: "p2pool-nano",
      name: "P2Pool nano",
      short: "PN",
      host: "pool.xmr.pub:3334",
      tlsPort: null,
      fee: 0,
      min: 0.0004,
      switching: false,
      tag: "p2p",
      why: "Bản nano còn nhẹ hơn mini — hợp VPS 1 vCPU, đổi lại ít share hơn nên payout nhỏ lẻ hơn.",
      cadence: "theo block, ~0.0004 XMR"
    }
  ];

  var byId = {};
  for (var i = 0; i < POOLS.length; i += 1) byId[POOLS[i].id] = POOLS[i];

  // A short name or a host:port from the URL, a link or a bookmark.
  function find(id) {
    if (!id) return null;
    var key = String(id).toLowerCase();
    if (byId[key]) return byId[key];
    for (var i = 0; i < POOLS.length; i += 1) {
      if (POOLS[i].host.toLowerCase() === key) return POOLS[i];
    }
    return null;
  }

  function endpoint(id) {
    var pool = find(id);
    return pool ? pool.host : "";
  }

  function feeLabel(pool) {
    if (!pool) return "";
    return pool.fee === 0 ? "0 %" : String(pool.fee).replace(".", ",") + " %";
  }

  function minLabel(pool) {
    if (!pool) return "";
    return String(pool.min).replace(".", ",") + " XMR";
  }

  root.zmrigPools = {
    list: POOLS,
    byId: byId,
    find: find,
    endpoint: endpoint,
    feeLabel: feeLabel,
    minLabel: minLabel
  };

  if (typeof module === "object" && module.exports) module.exports = root.zmrigPools;
})(typeof globalThis !== "undefined" ? globalThis : this);
