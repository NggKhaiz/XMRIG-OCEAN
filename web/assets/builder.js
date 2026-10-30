// The quick builder on the home page.
//
// All of the rules live in command.js; this file only reads the form, calls
// `zmrigCommand.build()`, and paints the result. Keeping it that way is what
// lets the wizard and this page produce byte-identical commands.

(function () {
  "use strict";

  var el = function (id) { return document.getElementById(id); };

  var nodes = {
    wallet: el("b-wallet"),
    walletHint: el("b-wallet-hint"),
    rig: el("b-rig"),
    engine: el("b-engine"),
    pool: el("b-pool"),
    failover: el("b-failover"),
    poolInfo: el("b-pool-info"),
    poolTag: el("b-pool-tag"),
    summary: el("b-summary"),
    profile: el("b-profile"),
    host: el("b-host"),
    hostHint: el("b-host-hint"),
    hostField: el("b-host-field"),
    wsPath: el("b-wspath"),
    wsPathField: el("b-wspath-field"),
    tls: el("b-tls"),
    tlsHint: el("b-tls-hint"),
    cpu: el("b-cpu"),
    noautotune: el("b-noautotune"),
    nohealth: el("b-nohealth"),
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
    warn: el("b-warn"),
    copy: el("b-copy"),
    copyPlan: el("b-copy-plan"),
    reset: el("b-reset"),
  };

  if (!nodes.output || !nodes.pool) return;

  var table = window.zmrigPools;
  var last = { args: [], wallet: { ok: false } };

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // --- populate the pool controls from the one pool table ------------------
  function fillPools() {
    nodes.pool.innerHTML = table.list
      .map(function (pool) {
        var fee = table.feeLabel(pool);
        return (
          '<option value="' + pool.id + '">' + escapeHtml(pool.name) +
          " — " + escapeHtml(pool.host) + " · " + escapeHtml(fee) + "</option>"
        );
      })
      .join("") + '<option value="custom">Khác — tôi tự nhập host</option>';

    if (nodes.failover) {
      nodes.failover.innerHTML = table.list
        .map(function (pool) {
          return (
            '<label class="pill"><input type="checkbox" data-failover="' + pool.id + '"> ' +
            "<span>" + escapeHtml(pool.short) + "</span></label>"
          );
        })
        .join("");
    }
  }

  function failoverChoice() {
    if (!nodes.failover) return [];
    return Array.prototype.slice
      .call(nodes.failover.querySelectorAll("input[data-failover]"))
      .filter(function (box) { return box.checked; })
      .map(function (box) { return box.getAttribute("data-failover"); });
  }

  function state() {
    return {
      wallet: nodes.wallet.value,
      rig: nodes.rig.value,
      engine: nodes.engine.value,
      profile: nodes.profile ? nodes.profile.value : "auto",
      pool: nodes.pool.value,
      host: nodes.host.value,
      failover: failoverChoice(),
      tls: nodes.tls ? nodes.tls.checked : false,
      cloudflare: nodes.cloudflare.checked,
      wsPath: nodes.wsPath.value,
      proxy: nodes.proxy.checked,
      proxyUrl: nodes.proxyUrl ? nodes.proxyUrl.value : "",
      msr: nodes.msr && nodes.msr.checked,
      nicehash: nodes.nicehash && nodes.nicehash.checked,
      notune: nodes.notune.checked,
      autotuneOff: nodes.noautotune && nodes.noautotune.checked,
      noHealthRestart: nodes.nohealth && nodes.nohealth.checked,
      force: nodes.force.checked,
      clone: nodes.clone.checked,
      cpu: Number(nodes.cpu.value),
    };
  }

  function poolInfoHtml() {
    var pool = table.find(nodes.pool.value);

    if (!pool) {
      return (
        '<p class="small"><strong>Pool tự nhập.</strong> Kiểm tra phí và minimum trên trang của họ: ' +
        "hai thứ đó quyết định thu nhập nhiều hơn hashrate. Nếu bạn tự dựng pool trong repo này " +
        '(<code>pool/</code>), hãy bật WebSocket + TLS.</p>'
      );
    }

    var rows = [
      "<span><b>Phí</b> " + escapeHtml(table.feeLabel(pool)) + "</span>",
      "<span><b>Minimum</b> " + escapeHtml(table.minLabel(pool)) + "</span>",
      "<span><b>Trả</b> " + escapeHtml(pool.cadence) + "</span>",
      "<span><b>Endpoint</b> <code>" + escapeHtml(pool.host) + "</code></span>",
    ];

    return (
      '<p class="small" style="margin:0 0 6px">' + escapeHtml(pool.why) + "</p>" +
      '<div class="pool-facts">' + rows.join("") + "</div>"
    );
  }

  function summaryHtml(result) {
    var rows = [];

    rows.push(["Pool", escapeHtml(result.pool.name)]);
    if (result.pool.fee !== null && result.pool.fee !== undefined) {
      rows.push(["Phí pool", escapeHtml(table.feeLabel({ fee: result.pool.fee }))]);
    }
    rows.push(["Endpoint", "<code>" + escapeHtml(result.pool.endpoint || "—") + "</code>"]);
    if (result.failover.length) {
      rows.push(["Dự phòng", result.failover.map(function (f) { return "<code>" + escapeHtml(f) + "</code>"; }).join("<br>")]);
    }
    rows.push(["Engine", escapeHtml(result.engine === "auto" ? "tự nhận diện" : result.engine)]);
    rows.push(["Chế độ", escapeHtml(result.profile === "auto" ? "tự nhận diện" : result.profile)]);

    return rows
      .map(function (row) {
        return "<li><span>" + row[0] + "</span><span>" + row[1] + "</span></li>";
      })
      .join("");
  }

  function updateValidation(result) {
    var state_ = result.wallet;
    nodes.walletHint.textContent = state_.message;
    nodes.walletHint.className = "hint" + (state_.empty ? "" : state_.ok ? " good" : " bad");
    nodes.wallet.setAttribute("aria-invalid", state_.ok || state_.empty ? "false" : "true");

    if (nodes.hostHint) {
      var host = window.zmrigCommand.hostState(result.pool.endpoint);
      nodes.hostHint.textContent = host.message;
      nodes.hostHint.className = "hint" + (host.empty ? "" : host.ok ? " good" : " bad");
    }
  }

  function update() {
    var choice = nodes.pool.value;
    var isCustom = !table.find(choice);

    nodes.hostField.hidden = !isCustom;
    if (!isCustom) nodes.host.value = "";
    if (isCustom) {
      nodes.host.placeholder = "pool.example.com:3333";
    }

    nodes.wsPathField.hidden = !nodes.cloudflare.checked;
    nodes.proxyUrl.hidden = !nodes.proxy.checked;

    // Index by value, not by position: the option order is a presentation
    // detail and has already changed once.
    var xmrigOption = nodes.engine.querySelector('option[value="xmrig"]');
    if (xmrigOption) xmrigOption.disabled = nodes.cloudflare.checked || nodes.proxy.checked;
    if (nodes.cloudflare.checked || nodes.proxy.checked) nodes.engine.value = "zmrig";

    var result = window.zmrigCommand.build(state());
    last = result;

    nodes.poolInfo.innerHTML = poolInfoHtml();
    nodes.summary.innerHTML = summaryHtml(result);
    nodes.output.textContent = result.install;

    var pool = table.find(choice);
    nodes.poolTag.textContent = pool ? pool.name + " · " + table.feeLabel(pool) : "tự nhập";

    updateValidation(result);

    var messages = {
      "empty-wallet": "Nhập địa chỉ ví để có lệnh chạy được.",
      "bad-wallet": "Địa chỉ ví chưa đúng — kiểm tra lại.",
      "bad-host": "Cần host:port của pool để cài được.",
      "no-proxy": "Đã chọn proxy nhưng chưa nhập địa chỉ proxy.",
    };

    if (result.blocked) {
      nodes.status.textContent = messages[result.blocked] || "Còn thiếu thông tin.";
      nodes.status.className = "status bad";
    } else {
      nodes.status.textContent = "";
      nodes.status.className = "status";
    }

    // Copying a command that cannot work is worse than no button at all: the
    // wallet would be planted in a systemd unit as-is.
    if (nodes.copy) nodes.copy.disabled = Boolean(result.blocked);
    if (nodes.copyPlan) nodes.copyPlan.disabled = result.wallet.empty;

    nodes.note.textContent = result.notes.length
      ? result.notes.join(" ")
      : "Địa chỉ ví chỉ nằm trong lệnh và file cấu hình trên máy bạn.";
    nodes.warn.textContent = result.warnings.join(" ");
    nodes.warn.className = result.warnings.length ? "hint warnate" : "hint";
    nodes.warn.hidden = result.warnings.length === 0;

    if (nodes.tlsHint) {
      nodes.tlsHint.textContent = pool && pool.tlsPort
        ? "Cổng TLS của " + pool.name + ": " + pool.tlsPort + "."
        : isCustom
          ? "Chỉ bật nếu pool của bạn có TLS trên cổng này, nếu không sẽ bị từ chối ngay khi login."
          : "Pool này không công bố cổng TLS riêng.";
    }

    return result;
  }

  function copy(text, okMessage) {
    var done = function (ok) {
      nodes.status.textContent = ok ? okMessage : "Không copy được — bôi đen khung lệnh và Ctrl+C.";
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
    if (nodes.tls) nodes.tls.checked = false;
    if (nodes.noautotune) nodes.noautotune.checked = false;
    if (nodes.nohealth) nodes.nohealth.checked = false;
    nodes.cloudflare.checked = false;
    nodes.proxy.checked = false;
    nodes.proxyUrl.value = "";
    nodes.notune.checked = false;
    nodes.force.checked = false;
    nodes.clone.checked = false;
    if (nodes.failover) {
      nodes.failover.querySelectorAll("input").forEach(function (box) { box.checked = false; });
    }
    update();
    nodes.wallet.focus();
  }

  // The comparison table under the builder. It reads the same table the
  // controls do, so a fee can only be changed in one file.
  function fillPoolTable() {
    var body = el("pool-table");
    if (!body) return;

    body.innerHTML = table.list
      .map(function (pool) {
        var tag = pool.tag === "best" ? ' <span class="tag ok">nhiều nhất</span>'
          : pool.tag === "steady" ? ' <span class="tag">ổn định</span>'
            : pool.tag === "p2p" ? ' <span class="tag">phi tập trung</span>' : "";

        return (
          "<tr>" +
          '<td><a href="wizard.html?pool=' + pool.id + '">' + escapeHtml(pool.name) + "</a>" + tag + "</td>" +
          '<td class="num">' + escapeHtml(table.feeLabel(pool)) + "</td>" +
          '<td class="num">' + escapeHtml(table.minLabel(pool)) + "</td>" +
          "<td>" + escapeHtml(pool.cadence) + "</td>" +
          "<td><code>" + escapeHtml(pool.host) + "</code></td>" +
          '<td>' + (pool.switching ? "chuyển thuật toán" : "") + "</td>" +
          "</tr>"
        );
      })
      .join("");
  }

  fillPools();
  fillPoolTable();

  ["input", "change"].forEach(function (event) {
    document.querySelectorAll("#builder input, #builder select").forEach(function (node) {
      node.addEventListener(event, update);
    });
  });

  nodes.copy.addEventListener("click", function () { copy(last.install, "Đã copy lệnh cài."); });
  if (nodes.copyPlan) nodes.copyPlan.addEventListener("click", function () { copy(last.plan, "Đã copy lệnh xem trước."); });
  if (nodes.reset) nodes.reset.addEventListener("click", reset);

  // A link from the pool table or the wizard can preselect a pool:
  // index.html?pool=c3pool#builder
  var wanted = new URLSearchParams(window.location.search).get("pool");
  if (wanted && table.find(wanted)) nodes.pool.value = wanted;

  if (window.location.hash === "#builder") {
    setTimeout(function () { nodes.wallet.focus(); }, 250);
  }

  update();
})();
