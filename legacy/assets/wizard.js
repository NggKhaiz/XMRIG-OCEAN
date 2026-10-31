// The step-by-step wizard in wizard.html.
//
// Two rules make it worth having next to the quick builder:
//   1. It asks only what the installer cannot decide (wallet, pool, network).
//   2. Every question carries its reason on screen, so the answer is a choice
//      instead of a guess.
//
// The command itself is built by command.js, the same function the home page
// uses, so the two pages can never disagree about a flag.

(function () {
  "use strict";

  var el = function (id) { return document.getElementById(id); };
  var table = window.zmrigPools;
  var command = window.zmrigCommand;

  var form = el("wizard");
  if (!form || !table || !command) return;

  var nodes = {
    steps: Array.prototype.slice.call(document.querySelectorAll(".w-step")),
    stepper: el("w-stepper"),
    progress: el("w-progress"),
    wallet: el("w-wallet"),
    walletHint: el("w-wallet-hint"),
    rig: el("w-rig"),
    poolGrid: el("w-pool-grid"),
    host: el("w-host"),
    hostField: el("w-host-field"),
    hostHint: el("w-host-hint"),
    tls: el("w-tls"),
    tlsHint: el("w-tls-hint"),
    failover: el("w-failover"),
    profile: el("w-profile"),
    cpu: el("w-cpu"),
    noautotune: el("w-noautotune"),
    nicehash: el("w-nicehash"),
    cloudflare: el("w-cloudflare"),
    proxy: el("w-proxy"),
    proxyField: el("w-proxy-field"),
    proxyUrl: el("w-proxy-url"),
    wspath: el("w-wspath"),
    wspathField: el("w-wspath-field"),
    msr: el("w-msr"),
    notune: el("w-notune"),
    nohealth: el("w-nohealth"),
    output: el("w-output"),
    summary: el("w-summary"),
    status: el("w-status"),
    warn: el("w-warn"),
    blocked: el("w-blocked"),
    next: el("w-next"),
    back: el("w-back"),
    copy: el("w-copy"),
    copyPlan: el("w-copy-plan"),
    copyLink: el("w-copy-link"),
    restart: el("w-restart"),
    remove: el("w-remove"),
  };

  var TOTAL = nodes.steps.length;
  var step = 1;
  var last = null;

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function engineChoice() {
    var checked = form.querySelector('input[name="w-engine"]:checked');
    return checked ? checked.value : "auto";
  }

  // --- pool cards ---------------------------------------------------------
  function renderPools() {
    var cards = table.list.map(function (pool) {
      var tag = pool.tag === "best" ? " thuận lợi nhất" : pool.tag === "steady" ? " ổn định" : "";
      return (
        '<label class="pool-card" data-pool="' + pool.id + '">' +
        '<input type="radio" name="w-pool" value="' + pool.id + '">' +
        '<span class="pc-top"><b>' + escapeHtml(pool.name) + "</b>" +
        '<span class="tag ' + (pool.fee === 0 ? "ok" : "") + '">' + escapeHtml(table.feeLabel(pool)) + " phí</span></span>" +
        '<span class="pc-facts">min ' + escapeHtml(table.minLabel(pool)) + tag + "</span>" +
        '<span class="pc-why small muted">' + escapeHtml(pool.why) + "</span>" +
        '<span class="pc-host"><code>' + escapeHtml(pool.host) + "</code></span>" +
        "</label>"
      );
    });

    cards.push(
      '<label class="pool-card" data-pool="custom">' +
      '<input type="radio" name="w-pool" value="custom">' +
      '<span class="pc-top"><b>Pool của tôi</b><span class="tag">tự nhập</span></span>' +
      '<span class="pc-facts">host:port</span>' +
      '<span class="pc-why small muted">Pool riêng, pool nội bộ, hoặc pool tự dựng bằng <code>pool/</code> trong repo này.</span>' +
      "</label>"
    );

    nodes.poolGrid.innerHTML = cards.join("");

    var options = ['<option value="">Không có</option>'];
    table.list.forEach(function (pool) {
      options.push('<option value="' + pool.id + '">' + escapeHtml(pool.name) + " — " + escapeHtml(pool.host) + "</option>");
    });
    nodes.failover.innerHTML = options.join("");
  }

  function selectedPool() {
    var checked = form.querySelector('input[name="w-pool"]:checked');
    return checked ? checked.value : "moneroocean";
  }

  function setPool(id) {
    var box = form.querySelector('input[name="w-pool"][value="' + id + '"]');
    if (box) box.checked = true;
    syncPoolUi();
  }

  function syncPoolUi() {
    var id = selectedPool();
    var isCustom = !table.find(id);

    nodes.hostField.hidden = !isCustom;
    Array.prototype.forEach.call(nodes.poolGrid.querySelectorAll(".pool-card"), function (card) {
      card.classList.toggle("selected", card.getAttribute("data-pool") === id);
    });

    var pool = table.find(id);
    if (isCustom) {
      nodes.tlsHint.textContent = "Chỉ bật nếu pool của bạn có TLS trên đúng cổng này.";
    } else if (pool.tlsPort) {
      nodes.tlsHint.textContent = "Cổng TLS của " + pool.name + ": " + pool.tlsPort + ".";
    } else {
      nodes.tlsHint.textContent = pool.name + " không công bố cổng TLS riêng — không nên bật.";
      if (nodes.tls.checked) nodes.tls.checked = false;
    }

    // Never offer the pool itself as its own backup.
    Array.prototype.forEach.call(nodes.failover.options, function (option) {
      option.disabled = option.value !== "" && option.value === id;
    });
    if (nodes.failover.value === id) nodes.failover.value = "";
  }

  // --- state --------------------------------------------------------------
  function state() {
    return {
      wallet: nodes.wallet.value,
      rig: nodes.rig.value,
      engine: engineChoice(),
      profile: nodes.profile.value,
      pool: selectedPool(),
      host: nodes.host.value,
      failover: nodes.failover.value ? [nodes.failover.value] : [],
      tls: nodes.tls.checked,
      cloudflare: nodes.cloudflare.checked,
      wsPath: nodes.wspath.value,
      proxy: nodes.proxy.checked,
      proxyUrl: nodes.proxyUrl.value,
      msr: nodes.msr.checked,
      nicehash: nodes.nicehash.checked,
      notune: nodes.notune.checked,
      autotuneOff: nodes.noautotune.checked,
      noHealthRestart: nodes.nohealth.checked,
      cpu: Number(nodes.cpu.value),
    };
  }

  function applyState(params) {
    if (params.get("pool")) setPool(params.get("pool"));
    var engine = params.get("engine");
    if (engine) {
      var box = form.querySelector('input[name="w-engine"][value="' + engine + '"]');
      if (box) box.checked = true;
    }
    if (params.get("profile")) nodes.profile.value = params.get("profile");
    if (params.get("tls") === "1") nodes.tls.checked = true;
    if (params.get("cf") === "1") nodes.cloudflare.checked = true;
    if (params.get("fo")) nodes.failover.value = params.get("fo");
  }

  function shareParams() {
    var params = new URLSearchParams();
    params.set("pool", selectedPool());
    if (engineChoice() !== "auto") params.set("engine", engineChoice());
    if (nodes.profile.value !== "auto") params.set("profile", nodes.profile.value);
    if (nodes.tls.checked) params.set("tls", "1");
    if (nodes.cloudflare.checked) params.set("cf", "1");
    if (nodes.failover.value) params.set("fo", nodes.failover.value);
    return params;
  }

  // --- rendering ----------------------------------------------------------
  function summaryHtml(result) {
    var rows = [];
    var fee = result.pool.fee;

    rows.push(["Pool", escapeHtml(result.pool.name)]);
    if (fee !== null && fee !== undefined) {
      rows.push(["Phí", escapeHtml(table.feeLabel({ fee: fee }))]);
    }
    rows.push(["Endpoint", "<code>" + escapeHtml(result.pool.endpoint || "—") + "</code>"]);
    if (result.failover.length) rows.push(["Dự phòng", "<code>" + escapeHtml(result.failover[0]) + "</code>"]);
    rows.push(["Engine", escapeHtml(result.engine === "auto" ? "tự nhận diện" : result.engine)]);
    rows.push(["Chế độ", escapeHtml(result.profile === "auto" ? "tự nhận diện" : result.profile)]);
    rows.push(["Cờ thêm", result.flags.length ? "<code>" + escapeHtml(result.flags.join(" ")) + "</code>" : "—"]);

    return rows
      .map(function (row) { return "<li><span>" + row[0] + "</span><span>" + row[1] + "</span></li>"; })
      .join("");
  }

  function update() {
    var result = command.build(state());
    last = result;

    nodes.output.textContent = result.install;
    nodes.summary.innerHTML = summaryHtml(result);

    var wallet = result.wallet;
    nodes.walletHint.textContent = wallet.message;
    nodes.walletHint.className = "hint" + (wallet.empty ? "" : wallet.ok ? " good" : " bad");

    nodes.warn.textContent = result.warnings.join(" ");
    nodes.warn.hidden = result.warnings.length === 0;
    nodes.warn.className = "hint warnate";

    if (nodes.remove) {
      nodes.remove.textContent = "sudo ./oneclick.sh purge --dry-run\nsudo ./oneclick.sh purge";
    }

    return result;
  }

  // What a step still needs before it can be left. Only two steps can block:
  // the wallet (a command with a placeholder is a footgun) and a custom pool
  // without a host. Everything else has a safe default.
  function stepProblem(n) {
    if (n === 1) {
      var wallet = command.walletState(nodes.wallet.value.trim());
      if (wallet.empty) return "Nhập địa chỉ ví để đi tiếp.";
      if (!wallet.ok) return wallet.message;
    }

    if (n === 2) {
      var endpoint = command.build(state()).pool.endpoint;
      if (!endpoint) return "Cần host:port của pool.";
      if (!command.hostState(endpoint).ok) return command.hostState(endpoint).message;
    }

    return null;
  }

  function show(n) {
    step = n;

    nodes.steps.forEach(function (panel) {
      panel.hidden = Number(panel.getAttribute("data-panel")) !== step;
    });

    Array.prototype.forEach.call(nodes.stepper.children, function (item) {
      var value = Number(item.getAttribute("data-step"));
      item.classList.toggle("done", value < step);
      item.classList.toggle("current", value === step);
      item.querySelector("button").setAttribute("aria-current", value === step ? "step" : "false");
    });

    nodes.progress.style.width = (step / TOTAL) * 100 + "%";
    nodes.back.hidden = step === 1;
    nodes.next.hidden = step === TOTAL;
    nodes.blocked.textContent = "";

    if (step === TOTAL) update();

    var heading = nodes.steps[step - 1].querySelector("h2");
    if (heading) {
      heading.setAttribute("tabindex", "-1");
      heading.focus({ preventScroll: true });
    }

    try { window.scrollTo({ top: 0, behavior: "smooth" }); } catch (_) {}
  }

  function goto(target, push) {
    var next = Math.max(1, Math.min(TOTAL, Number(target) || 1));

    // Moving forward walks the steps in between, so the stepper cannot be used
    // to jump past an empty wallet field. A deep link (?step=4) is a restore,
    // not a claim that the earlier steps are complete, so it is not validated.
    if (push !== false && next > step) {
      for (var check = 1; check < next; check += 1) {
        var problem = stepProblem(check);
        if (problem) {
          show(check);
          nodes.blocked.textContent = problem;
          return false;
        }
      }
    }

    show(next);

    if (push !== false) {
      var query = shareParams().toString();
      window.history.replaceState(null, "", "?step=" + step + (query ? "&" + query : ""));
    }

    return true;
  }

  function copyText(text, okMessage) {
    var done = function (ok) {
      nodes.status.textContent = ok ? okMessage : "Không copy được — bôi đen và Ctrl+C.";
      nodes.status.className = "status " + (ok ? "ok" : "bad");
      setTimeout(function () { nodes.status.textContent = ""; nodes.status.className = "status"; }, 2000);
    };

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      return;
    }

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

  // --- wiring -------------------------------------------------------------
  renderPools();

  var params = new URLSearchParams(window.location.search);
  var wanted = params.get("pool");
  var valid = wanted && (table.find(wanted) || wanted === "custom");
  setPool(valid ? wanted : "moneroocean");
  applyState(params);

  var start = Number(params.get("step")) || 1;
  goto(start, false);
  if (start !== 1) update();

  // A form with a text input submits on Enter. If it ever did, the wallet would
  // end up in the address bar and in the history. Enter moves to the next step
  // instead, and a submit can never happen.
  form.addEventListener("submit", function (event) { event.preventDefault(); });
  form.addEventListener("input", function () { if (step === TOTAL) update(); });
  form.addEventListener("change", function () { syncPoolUi(); if (step === TOTAL) update(); });
  form.addEventListener("keydown", function (event) {
    if (event.key === "Enter" && event.target.tagName !== "TEXTAREA") {
      event.preventDefault();
      if (step < TOTAL) goto(step + 1);
    }
  });

  nodes.next.addEventListener("click", function () { goto(step + 1); });
  nodes.back.addEventListener("click", function () { goto(step - 1); });

  Array.prototype.forEach.call(nodes.stepper.querySelectorAll("[data-goto]"), function (button) {
    button.addEventListener("click", function () { goto(button.getAttribute("data-goto")); });
  });

  nodes.wallet.addEventListener("blur", function () {
    var wallet = command.walletState(nodes.wallet.value.trim());
    nodes.walletHint.textContent = wallet.message;
    nodes.walletHint.className = "hint" + (wallet.empty ? "" : wallet.ok ? " good" : " bad");
  });

  nodes.copy.addEventListener("click", function () {
    if (!last || last.blocked) return;
    copyText(last.install, "Đã copy. Dán vào terminal của máy cần cài.");
  });

  nodes.copyPlan.addEventListener("click", function () { copyText(last.plan, "Đã copy lệnh xem trước (không cài gì)."); });

  nodes.copyLink.addEventListener("click", function () {
    var url = window.location.origin + window.location.pathname + "?" + "step=2&" + shareParams().toString();
    copyText(url, "Đã copy liên kết — không chứa địa chỉ ví.");
  });

  nodes.restart.addEventListener("click", function () {
    nodes.wallet.value = "";
    nodes.rig.value = "";
    nodes.cpu.value = "100";
    nodes.profile.value = "auto";
    setPool("moneroocean");
    nodes.failover.value = "";
    nodes.tls.checked = false;
    nodes.cloudflare.checked = false;
    nodes.proxy.checked = false;
    nodes.msr.checked = false;
    nodes.notune.checked = false;
    nodes.nohealth.checked = false;
    nodes.noautotune.checked = false;
    nodes.nicehash.checked = false;
    var auto = form.querySelector('input[name="w-engine"][value="auto"]');
    if (auto) auto.checked = true;
    goto(1);
  });

  window.addEventListener("popstate", function () {
    var params = new URLSearchParams(window.location.search);
    goto(Number(params.get("step")) || 1, false);
  });
})();
