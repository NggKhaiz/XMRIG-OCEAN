// Command builder.
//
// Assembles the exact install command for the options on the page, so nobody
// has to remember the flags. Everything is computed here: no network requests,
// the wallet never leaves the browser.
//
// The flags mirror oneclick.sh. If a flag is added there, add it here too.

(function () {
  "use strict";

  var RAW_URL = "https://raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh";

  var POOLS = {
    moneroocean: { pool: "gulf.moneroocean.stream:10001", wsPath: null },
    supportxmr: { pool: "pool.supportxmr.com:3333", wsPath: null },
    ocean: { pool: "", wsPath: "/stratum" },
    custom: { pool: "", wsPath: "/stratum" }
  };

  var el = function (id) { return document.getElementById(id); };

  var nodes = {
    wallet: el("b-wallet"),
    walletHint: el("b-wallet-hint"),
    rig: el("b-rig"),
    engine: el("b-engine"),
    pool: el("b-pool"),
    profile: el("b-profile"),
    host: el("b-host"),
    hostField: el("b-host-field"),
    wsPath: el("b-wspath"),
    wsPathField: el("b-wspath-field"),
    cpu: el("b-cpu"),
    cloudflare: el("b-cloudflare"),
    proxy: el("b-proxy"),
    msr: el("b-msr"),
    nicehash: el("b-nicehash"),
    proxyUrl: el("b-proxy-url"),
    notune: el("b-notune"),
    force: el("b-force"),
    clone: el("b-clone"),
    output: el("b-output"),
    status: el("b-status"),
    note: el("b-note"),
    copy: el("b-copy"),
    reset: el("b-reset")
  };

  if (!nodes.output) return;

  function shellQuote(value) {
    if (value === "") return "''";
    if (/^[A-Za-z0-9._:\/@%+=,-]+$/.test(value)) return value;

    return "'" + value.replace(/'/g, "'\\''") + "'";
  }

  // Monero addresses: 95 characters (4… primary, 8… subaddress) or 106 for an
  // integrated address. Base58 excludes 0, O, I and l.
  function walletState(value) {
    if (!value) return { ok: false, empty: true, message: "Ví chính bắt đầu bằng 4, subaddress bằng 8. Không nhập seed hay private key." };

    if (!/^[48][1-9A-HJ-NP-Za-km-z]+$/.test(value)) {
      return { ok: false, empty: false, message: "Ký tự không hợp lệ — địa chỉ Monero dùng base58 (không có 0, O, I, l)." };
    }

    if (value.length === 95) return { ok: true, message: "Địa chỉ hợp lệ (95 ký tự)." };
    if (value.length === 106 && value[0] === "4") return { ok: true, message: "Địa chỉ tích hợp (106 ký tự)." };

    return { ok: false, empty: false, message: "Độ dài " + value.length + " — địa chỉ thường dài 95 ký tự." };
  }

  function currentPool() {
    var choice = nodes.pool.value;
    var preset = POOLS[choice] || POOLS.custom;
    var host = nodes.host.value.trim();

    var value = host || preset.pool;

    if (!value && choice === "ocean") value = "";
    if (!value && choice === "custom") value = "";

    return { choice: choice, value: value, wsPath: preset.wsPath };
  }

  function build() {
    var wallet = nodes.wallet.value.trim();
    var rig = nodes.rig.value.trim();
    var cloudflare = nodes.cloudflare.checked;
    var proxy = nodes.proxy.checked ? nodes.proxyUrl.value.trim() : "";
    var cpu = Number(nodes.cpu.value);
    var pool = currentPool();

    // The C++ frontend has no WebSocket client and no proxy support; the
    // installer refuses those combinations, so do not offer them.
    if (cloudflare || proxy) nodes.engine.value = "zmrig";
    var engine = nodes.engine.value;

    var args = ["install"];
    args.push("--wallet", wallet || "YOUR_WALLET");
    if (rig) args.push("--rig-id", rig);
    // "auto" means "let the installer decide", and the installer can only
    // decide if the flag is absent. Saying --engine auto would also work, but
    // the shortest correct command is the point of the builder.
    if (engine !== "auto") args.push("--engine", engine);
    // Without a host, say so in the command instead of silently falling back to
    // the installer default pool.
    args.push("--pool", pool.value || "YOUR_POOL_HOST");

    if (cloudflare) {
      args.push("--cloudflare");
      var wsPath = (nodes.wsPath.value.trim() || "/stratum");
      if (wsPath[0] !== "/") wsPath = "/" + wsPath;
      args.push("--ws-path", wsPath);
    }

    // Same rule for the profile: absent means "detect it".
    var profile = nodes.profile ? nodes.profile.value : "auto";
    if (profile !== "auto") args.push("--profile", profile);

    if (proxy) args.push("--proxy", proxy);
    // MSR is on by default for a root install; this switch exists for hosts
    // that refuse the write (most VMs and containers).
    if (nodes.msr && nodes.msr.checked) args.push("--no-msr");
    if (nodes.nicehash && nodes.nicehash.checked) args.push("--nicehash");
    if (Number.isFinite(cpu) && cpu > 0 && cpu < 100) args.push("--cpu-hint", String(Math.round(cpu)));
    if (nodes.notune.checked) args.push("--no-tune");
    if (nodes.force.checked) args.push("--force");
    args.push("--yes");

    var quoted = args.map(function (arg) {
      return /^--/.test(arg) ? arg : shellQuote(arg);
    }).join(" ");

    var install = nodes.clone.checked
      ? "sudo ./oneclick.sh " + quoted
      : "curl -fsSL " + RAW_URL + " \\\n  | sudo bash -s -- " + quoted;

    var lines = [
      "# 1. cài đặt, build, tune, tạo service (một lệnh)",
      install,
      "",
      "# 2. xem dịch vụ và log — cần cho mọi lần gỡ lỗi",
      "sudo systemctl status xmrig-ocean --no-pager -l",
      "sudo journalctl -u xmrig-ocean -n 40 --no-pager"
    ];

    return { text: lines.join("\n"), args: args, wallet: wallet, pool: pool, cloudflare: cloudflare, engine: engine, profile: profile };
  }

  function updateValidation() {
    var state = walletState(nodes.wallet.value.trim());

    nodes.walletHint.textContent = state.message;
    nodes.walletHint.className = "hint" + (state.empty ? "" : (state.ok ? " good" : " bad"));
    nodes.wallet.setAttribute("aria-invalid", state.ok || state.empty ? "false" : "true");

    return state;
  }

  function update() {
    var choice = nodes.pool.value;
    var needsHost = choice === "custom" || (choice === "ocean" && !POOLS.ocean.pool);

    // The host is only needed when the preset does not name one, or when the
    // WebSocket path has to be dialled by hostname.
    nodes.hostField.hidden = !(needsHost || (nodes.cloudflare.checked && choice === "custom"));

    if (nodes.hostField.hidden === false) {
      nodes.host.placeholder = choice === "ocean" ? "pool.example.com" : "pool.example.com:3333";
    }

    nodes.wsPathField.hidden = !nodes.cloudflare.checked;
    nodes.proxyUrl.hidden = !nodes.proxy.checked;

    // Index by value, not by position: the option order on the page is a
    // presentation detail and has already changed once.
    var xmrigOption = nodes.engine.querySelector('option[value="xmrig"]');
    if (xmrigOption) xmrigOption.disabled = nodes.cloudflare.checked || nodes.proxy.checked;

    if (nodes.cloudflare.checked || nodes.proxy.checked) nodes.engine.value = "zmrig";

    var state = updateValidation();
    var result = build();

    nodes.output.textContent = result.text;

    var blocked = !state.ok || (result.cloudflare && !result.pool.value);

    if (!state.ok) {
      nodes.status.textContent = state.empty ? "Nhập địa chỉ ví để có lệnh chạy được." : "Địa chỉ ví chưa đúng — kiểm tra lại.";
      nodes.status.className = "status bad";
    } else if (result.cloudflare && !result.pool.value) {
      nodes.status.textContent = "Cần host của pool để dùng WebSocket.";
      nodes.status.className = "status bad";
    } else {
      nodes.status.textContent = "";
      nodes.status.className = "status";
    }

    // Copying a command that cannot work is worse than no button at all: the
    // wallet would be planted in a systemd unit as-is.
    if (nodes.copy) nodes.copy.disabled = blocked;

    var notes = [];
    if (result.cloudflare) notes.push("WebSocket trên 443: cần engine zmrig (C++ không có client WS).");
    if (nodes.notune.checked) notes.push("Không tune hệ thống: mất khoảng 20–30% hashrate do huge pages.");
    if (result.engine === "auto") notes.push("Engine để auto: cài đặt tự chọn theo pool và CPU.");
    if (result.engine === "xmrig") notes.push("Engine C++: dùng được mọi thuật toán, không hỗ trợ --cloudflare/--proxy.");
    if (result.profile === "watt") notes.push("Chế độ watt: giữ governor tiết kiệm điện và bớt thread SMT, hashrate thấp hơn vài % nhưng H/W cao hơn.");
    if (result.profile === "free") notes.push("Chế độ free: dùng hết CPU, chỉ hợp với máy dùng điện free.");
    nodes.note.textContent = notes.length ? notes.join(" ") : "Địa chỉ ví chỉ nằm trong lệnh và file cấu hình trên máy bạn.";

    return result;
  }

  function copyOutput() {
    var text = nodes.output.textContent;

    var done = function (ok) {
      nodes.status.textContent = ok ? "Đã copy lệnh." : "Không copy được — bôi đen khung lệnh và Ctrl+C.";
      nodes.status.className = "status " + (ok ? "ok" : "bad");
      setTimeout(function () { update(); }, 1800);
    };

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      return;
    }

    // http:// previews and very old browsers: fall back to a selection.
    var area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.top = "-1000px";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (_) {}
    document.body.removeChild(area);
    done(ok);
  }

  function reset() {
    nodes.wallet.value = "";
    nodes.rig.value = "";
    nodes.engine.value = "auto";
    if (nodes.profile) nodes.profile.value = "auto";
    nodes.pool.value = "moneroocean";
    nodes.host.value = "";
    nodes.wsPath.value = "/stratum";
    nodes.cpu.value = "100";
    nodes.cloudflare.checked = false;
    nodes.proxy.checked = false;
    nodes.proxyUrl.value = "";
    nodes.notune.checked = false;
    nodes.force.checked = false;
    nodes.clone.checked = false;
    update();
    nodes.wallet.focus();
  }

  ["input", "change"].forEach(function (event) {
    document.querySelectorAll("#builder input, #builder select").forEach(function (node) {
      node.addEventListener(event, update);
    });
  });

  nodes.copy.addEventListener("click", copyOutput);

  if (nodes.reset) nodes.reset.addEventListener("click", reset);

  // Deep link: index.html#builder pre-fills nothing, but scrolling there with
  // the wallet field focused saves a click on phones.
  if (window.location.hash === "#builder") {
    setTimeout(function () { nodes.wallet.focus(); }, 250);
  }

  update();
})();
