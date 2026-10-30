// Dashboard: paste report codes, keep a fleet in localStorage, price it.
// All computation is local. The only network request is the optional price
// refresh, and it fails loudly instead of guessing.

(function () {
  "use strict";

  var STORAGE_KEY = "zmrig.dashboard.v1";
  var rigApi = window.zmrigRig;
  var fmt = window.zmrigFormat;

  var state = {
    rigs: [],          // [{ ...snapshot, wallOverride: number|null }]
    settings: Object.assign({}, rigApi.DEFAULTS),
    sort: { key: "profit", dir: -1 }
  };

  var els = {};

  function $(id) { return document.getElementById(id); }

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function load() {
    var raw = null;
    try { raw = localStorage.getItem(STORAGE_KEY); } catch (_) {}
    if (!raw) return;

    try {
      var saved = JSON.parse(raw);
      if (saved && Array.isArray(saved.rigs)) {
        state.rigs = saved.rigs.map(function (rig) {
          var copy = Object.assign({}, rig);
          copy.wallOverride = typeof rig.wallOverride === "number" ? rig.wallOverride : null;
          return copy;
        });
      }
      if (saved && saved.settings) state.settings = rigApi.mergeSettings(saved.settings);
    } catch (_) {
      // A corrupt entry must not brick the page: start clean and say so.
      setStatus("Dữ liệu đã lưu bị hỏng, đã bắt đầu lại từ đầu.", "bad");
    }
  }

  function save() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ v: 1, rigs: state.rigs, settings: state.settings }));
    } catch (_) {
      setStatus("Không lưu được vào localStorage (chế độ riêng tư?). Dữ liệu chỉ còn trong tab này.", "bad");
    }
  }

  function setStatus(text, kind) {
    if (!els.status) return;
    els.status.textContent = text || "";
    els.status.className = "status" + (kind ? " " + kind : "");
    clearTimeout(setStatus.timer);
    if (text) setStatus.timer = setTimeout(function () { els.status.textContent = ""; els.status.className = "status"; }, 6000);
  }

  function rigKey(rig) {
    return rig.id + "|" + (rig.cpu || "unknown");
  }

  function addRigs(rigs, quiet) {
    var added = 0;
    var replaced = 0;

    rigs.forEach(function (rig) {
      var key = rigKey(rig);
      var index = state.rigs.findIndex(function (existing) { return rigKey(existing) === key; });

      if (index === -1) {
        state.rigs.push(Object.assign({}, rig, { wallOverride: null }));
        added++;
        return;
      }

      var existing = state.rigs[index];
      if ((rig.ts || 0) >= (existing.ts || 0)) {
        var keepOverride = existing.wallOverride;
        state.rigs[index] = Object.assign({}, rig, { wallOverride: keepOverride });
        replaced++;
      }
    });

    save();
    render();

    if (!quiet) {
      var parts = [];
      if (added) parts.push("thêm " + added + " máy");
      if (replaced) parts.push("cập nhật " + replaced + " máy");
      if (!parts.length) parts.push("không có gì mới");
      setStatus(parts.join(", ") + ".", added + replaced > 0 ? "ok" : "");
    }
  }

  function handlePaste(text, quiet) {
    var decoded = rigApi.decodeMany(text);
    if (decoded.rigs.length === 0) {
      setStatus("Không đọc được mã nào. " + (decoded.errors[0] || ""), "bad");
      return;
    }

    addRigs(decoded.rigs, quiet);
    if (decoded.errors.length) setStatus(decoded.errors.length + " mã lỗi đã bị bỏ qua.", "bad");
  }

  // --- settings ----------------------------------------------------------

  function applySettingsToForm() {
    var s = state.settings;
    if (els.window) els.window.value = String(s.window);
    if (els.price) els.price.value = s.price;
    if (els.psu) els.psu.value = s.psuEff;
    if (els.base) els.base.value = s.baseW;
    if (els.mode) els.mode.value = s.payoutMode;
    if (els.xmrKhs) els.xmrKhs.value = s.xmrPerKhsDay;
    if (els.xmrPrice) els.xmrPrice.value = s.xmrPrice;
    if (els.netHash) els.netHash.value = s.networkHash / 1e9;
    if (els.reward) els.reward.value = s.blockReward;
    if (els.fee) els.fee.value = s.poolFee;
    if (els.poolFields) els.poolFields.hidden = s.payoutMode !== "pool";
    if (els.networkFields) els.networkFields.hidden = s.payoutMode !== "network";
  }

  function readNumber(input, fallback) {
    if (!input) return fallback;
    var value = Number(input.value);
    return isFinite(value) ? value : fallback;
  }

  function bindSettings() {
    function onChange() {
      state.settings = rigApi.mergeSettings({
        window: Number(els.window.value),
        price: readNumber(els.price, 0.10),
        psuEff: readNumber(els.psu, 87),
        baseW: readNumber(els.base, 25),
        payoutMode: els.mode.value,
        xmrPerKhsDay: readNumber(els.xmrKhs, 0.000096),
        xmrPrice: readNumber(els.xmrPrice, 300),
        networkHash: readNumber(els.netHash, 4.5) * 1e9,
        blockReward: readNumber(els.reward, 0.6),
        poolFee: readNumber(els.fee, 0)
      });
      if (els.poolFields) els.poolFields.hidden = state.settings.payoutMode !== "pool";
      if (els.networkFields) els.networkFields.hidden = state.settings.payoutMode !== "network";
      save();
      render();
    }

    ["window", "price", "psu", "base", "mode", "xmrKhs", "xmrPrice", "netHash", "reward", "fee"].forEach(function (key) {
      if (els[key]) {
        els[key].addEventListener("input", onChange);
        els[key].addEventListener("change", onChange);
      }
    });
  }

  function fetchPrice() {
    var button = $("fetch-price");
    if (button) button.disabled = true;
    setStatus("Đang lấy giá XMR…");

    // Six seconds, then give up. Mining networks are exactly the ones that
    // block or black-hole an API call, and a spinner that never stops looks
    // like a broken page. The manual field is always there.
    var stop = typeof AbortController === "function" ? new AbortController() : null;
    var timer = stop ? setTimeout(function () { stop.abort(); }, 6000) : null;

    fetch("https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=usd", stop ? { signal: stop.signal } : undefined)
      .then(function (response) {
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.json();
      })
      .then(function (data) {
        var price = data && data.monero && data.monero.usd;
        if (!price) throw new Error("thiếu trường monero.usd");
        state.settings.xmrPrice = price;
        if (els.xmrPrice) els.xmrPrice.value = price;
        save();
        render();
        setStatus("Đã cập nhật giá XMR: $" + Number(price).toFixed(2) + ".", "ok");
      })
      .catch(function (error) {
        var reason = error && error.name === "AbortError" ? "quá 6 giây không trả lời" : error.message;
        setStatus("Không lấy được giá (" + reason + "). Nhập tay ở ô \"Giá XMR\" — số liệu vẫn tính đúng.", "bad");
      })
      .finally(function () {
        if (timer) clearTimeout(timer);
        if (button) button.disabled = false;
      });
  }

  // --- rendering ---------------------------------------------------------

  function rows() {
    return state.rigs.map(function (rig) {
      var override = typeof rig.wallOverride === "number" ? rig.wallOverride : null;
      return {
        rig: rig,
        key: rigKey(rig),
        result: rigApi.compute(rig, state.settings, override),
        override: override
      };
    });
  }

  function sortRows(list) {
    var key = state.sort.key;
    var dir = state.sort.dir;

    list.sort(function (a, b) {
      var left;
      var right;

      if (key === "name") {
        left = a.rig.id.toLowerCase();
        right = b.rig.id.toLowerCase();
        return left < right ? -dir : left > right ? dir : 0;
      }
      if (key === "hashrate") { left = a.result.hashrate; right = b.result.hashrate; }
      else if (key === "power") { left = a.result.wallWatts || 0; right = b.result.wallWatts || 0; }
      else if (key === "eff") { left = a.result.efficiency || 0; right = b.result.efficiency || 0; }
      else if (key === "cost") { left = a.result.costDay || 0; right = b.result.costDay || 0; }
      else if (key === "revenue") { left = a.result.revenueDay || 0; right = b.result.revenueDay || 0; }
      else if (key === "xmr") { left = a.result.xmrDay || 0; right = b.result.xmrDay || 0; }
      else { left = a.result.profitDay === null ? -1e9 : a.result.profitDay; right = b.result.profitDay === null ? -1e9 : b.result.profitDay; }

      return (left - right) * dir;
    });

    return list;
  }

  function render() {
    var list = sortRows(rows());
    var sum = rigApi.totals(list);

    // Show which column is sorted, and in which direction.
    document.querySelectorAll("th[data-sort]").forEach(function (th) {
      var active = th.dataset.sort === state.sort.key;
      th.classList.toggle("sorted", active);
      th.classList.toggle("sorted-desc", active && state.sort.dir === -1);
      th.setAttribute("aria-sort", active ? (state.sort.dir === 1 ? "ascending" : "descending") : "none");
    });

    if (els.body) {
      els.body.innerHTML = list.map(function (row) {
        var rig = row.rig;
        var result = row.result;
        var powerCell =
          '<input class="power-input" type="number" min="1" step="1" inputmode="numeric" ' +
          'data-key="' + escapeHtml(row.key) + '" value="' + (row.override === null ? "" : row.override) + '" ' +
          'placeholder="' + (result.wallWatts === null ? "—" : Math.round(result.wallWatts)) + '" ' +
          'aria-label="Công suất tiêu thụ của ' + escapeHtml(rig.id) + ' (W)">';

        var powerNote = rig.power === null
          ? '<span class="tag warn">chưa đo</span>'
          : '<span class="tag">' + escapeHtml(rig.powerSource === "user" ? "nhập tay" : rig.powerSource) + "</span>";

        var profitClass = result.profitDay === null ? "" : result.profitDay >= 0 ? "style=\"color:var(--ok)\"" : "style=\"color:var(--bad)\"";

        return "<tr>" +
          "<td><strong>" + escapeHtml(rig.id) + "</strong><br><span class=\"small faint\">" + escapeHtml(rig.cpu) + "</span></td>" +
          "<td>" + escapeHtml(rig.algo) + "<br><span class=\"small faint\">" + escapeHtml(rig.mode) + ", " + rig.threads + "T</span></td>" +
          '<td class="num">' + fmt.hashrate(result.hashrate) + "</td>" +
          '<td class="num">' + powerCell + "<br>" + powerNote + "</td>" +
          '<td class="num">' + (result.efficiency ? result.efficiency.toFixed(2) : "—") + "</td>" +
          '<td class="num">' + (result.kwhDay === null ? "—" : result.kwhDay.toFixed(2)) + "</td>" +
          '<td class="num">' + fmt.money(result.costDay, "$") + "</td>" +
          '<td class="num">' + fmt.xmr(result.xmrDay) + "</td>" +
          '<td class="num">' + fmt.money(result.revenueDay, "$") + "</td>" +
          "<td class=\"num\" " + profitClass + ">" + fmt.money(result.profitDay, "$") + "</td>" +
          '<td><div class="rig-actions"><button data-remove="' + escapeHtml(row.key) + '" title="Xoá máy này" aria-label="Xoá ' + escapeHtml(rig.id) + '">Xoá</button></div></td>' +
          "</tr>";
      }).join("");
    }

    if (els.empty) els.empty.hidden = list.length > 0;
    if (els.table) els.table.hidden = list.length === 0;
    if (els.totals) els.totals.hidden = list.length === 0;

    if (els.totalRow) {
      els.totalRow.innerHTML =
        "<td>Tổng (" + sum.machines + " máy)</td>" +
        "<td></td>" +
        '<td class="num">' + fmt.hashrate(sum.hashrate) + "</td>" +
        '<td class="num">' + (sum.wallWatts ? sum.wallWatts.toFixed(0) + " W" : "—") + "</td>" +
        '<td class="num">' + (sum.efficiency ? sum.efficiency.toFixed(2) : "—") + "</td>" +
        '<td class="num">' + sum.kwhDay.toFixed(2) + "</td>" +
        '<td class="num">' + fmt.money(sum.costDay, "$") + "</td>" +
        '<td class="num">' + fmt.xmr(sum.xmrDay) + "</td>" +
        '<td class="num">' + fmt.money(sum.revenueDay, "$") + "</td>" +
        '<td class="num">' + fmt.money(sum.profitDay, "$") + "</td>" +
        "<td></td>";
    }

    setText("stat-hashrate", fmt.hashrate(sum.hashrate));
    setText("stat-power", sum.wallWatts ? Math.round(sum.wallWatts) : 0);
    setText("stat-kwh", sum.kwhDay.toFixed(1));
    setText("stat-cost", fmt.money(sum.costDay, "$"));
    setText("stat-revenue", fmt.money(sum.revenueDay, "$"));
    setText("stat-profit", fmt.money(sum.profitDay, "$"));
    setText("stat-profit-month", fmt.money(sum.profitMonth, "$"));
    setText("stat-eff", sum.efficiency ? sum.efficiency.toFixed(2) : "—");
    setText("stat-count", sum.machines);

    var profitStat = $("stat-profit-card");
    if (profitStat) {
      profitStat.classList.remove("pos", "neg");
      if (sum.profitDay > 0) profitStat.classList.add("pos");
      if (sum.profitDay < 0) profitStat.classList.add("neg");
    }

    if (els.unknownNote) {
      els.unknownNote.hidden = sum.unknownPower === 0;
      if (sum.unknownPower > 0) {
        els.unknownNote.textContent = sum.unknownPower + " máy chưa có số điện: nhập W đo bằng ổ điện (hoặc thêm --power W khi chạy --report) để tính đủ chi phí.";
      }
    }

    if (els.breakEven) {
      var prices = list.map(function (row) { return row.result.breakEvenPrice; }).filter(function (v) { return v !== null && isFinite(v); });
      if (prices.length) {
        var min = Math.min.apply(null, prices);
        var max = Math.max.apply(null, prices);
        els.breakEven.textContent = "Hoà vốn ở giá điện " + min.toFixed(3) +
          (max - min > 0.0005 ? "–" + max.toFixed(3) : "") + " $/kWh (giá đang dùng: " + state.settings.price.toFixed(3) + ").";
      } else {
        els.breakEven.textContent = "";
      }
    }
  }

  function setText(id, value) {
    var el = $(id);
    if (el) el.textContent = value;
  }

  // --- actions -----------------------------------------------------------

  function removeRig(key) {
    var before = state.rigs.length;
    state.rigs = state.rigs.filter(function (rig) { return rigKey(rig) !== key; });
    if (state.rigs.length !== before) {
      save();
      render();
      setStatus("Đã xoá máy.", "ok");
    }
  }

  function exportJson() {
    var payload = JSON.stringify({ v: 1, exported: new Date().toISOString(), rigs: state.rigs, settings: state.settings }, null, 2);
    var blob = new Blob([payload], { type: "application/json" });
    var url = URL.createObjectURL(blob);
    var link = document.createElement("a");
    link.href = url;
    link.download = "zmrig-fleet-" + new Date().toISOString().slice(0, 10) + ".json";
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
    setStatus("Đã tải file JSON (" + state.rigs.length + " máy).", "ok");
  }

  function importJson(file) {
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(String(reader.result));
        var incoming = Array.isArray(data) ? data : data.rigs;
        if (!Array.isArray(incoming)) throw new Error("thiếu mảng \"rigs\"");

        var normalised = incoming.map(function (item) {
          var rig = rigApi.normalise(item);
          rig.wallOverride = typeof item.wallOverride === "number" ? item.wallOverride : null;
          return rig;
        });

        addRigs(normalised, true);
        if (data.settings) {
          state.settings = rigApi.mergeSettings(data.settings);
          applySettingsToForm();
          save();
          render();
        }
        setStatus("Đã nhập " + normalised.length + " máy từ file.", "ok");
      } catch (error) {
        setStatus("File không hợp lệ: " + error.message, "bad");
      }
    };
    reader.readAsText(file);
  }

  function share() {
    if (!state.rigs.length) {
      setStatus("Chưa có máy nào để chia sẻ.", "bad");
      return;
    }

    var codes = state.rigs.map(function (rig) {
      // Re-encode a minimal report from the stored snapshot.
      return encodeSnapshot(rig);
    });

    if (location.protocol === "file:") {
      setStatus("Đang mở bằng file:// — dùng \"Xuất JSON\" thay vì liên kết.", "bad");
      return;
    }

    var url = location.origin + location.pathname + "#rigs=" + codes.join(",");
    if (url.length > 8000) {
      setStatus("Danh sách quá dài cho một liên kết (" + url.length + " ký tự). Dùng \"Xuất JSON\" để chia sẻ.", "bad");
      return;
    }

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(url).then(function () {
        setStatus("Đã copy liên kết chia sẻ.", "ok");
      }, function () {
        setStatus("Không copy được. Liên kết: " + url, "bad");
      });
    } else {
      setStatus("Liên kết: " + url);
    }
  }

  function encodeSnapshot(rig) {
    var payload = {
      v: 1, id: rig.id, ver: rig.version, cpu: rig.cpu, arch: rig.arch,
      cores: rig.cores, thr: rig.threads, algo: rig.algo, mode: rig.mode,
      hs: rig.hs, hp: rig.hugePages, shares: rig.shares, hash: rig.hashes,
      up: rig.uptime, pw: rig.power, pwsrc: rig.powerSource, pool: rig.pool, ts: rig.ts,
      health: rig.health || undefined, hw: rig.hashesPerWatt === null ? undefined : rig.hashesPerWatt
    };
    var bytes = new TextEncoder().encode(JSON.stringify(payload));
    var binary = "";
    bytes.forEach(function (byte) { binary += String.fromCharCode(byte); });
    return rigApi.PREFIX + btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function addSample() {
    var now = Math.floor(Date.now() / 1000);
    var samples = [
      {
        v: 1, id: "vps-hn-01", ver: "6.32.0", cpu: "AMD EPYC 7B13 64-Core Processor", arch: "x86_64",
        cores: 32, thr: 16, algo: "rx/0", mode: "fast", hs: [9620.4, 9588.1, 9510.7, 9712.0],
        hp: [1168, 1168], shares: [412, 1, 0], hash: 8123456789, up: 86400,
        pw: 118.4, pwsrc: "rapl", pool: "gulf.moneroocean.stream", ts: now
      },
      {
        v: 1, id: "vps-sg-02", ver: "6.32.0", cpu: "Intel(R) Xeon(R) Gold 6248 CPU @ 2.50GHz", arch: "x86_64",
        cores: 20, thr: 8, algo: "rx/0", mode: "fast", hs: [4180.2, 4162.9, 4130.3, 4201.5],
        hp: [1168, 1168], shares: [180, 0, 0], hash: 3214567890, up: 43200,
        pw: 74.0, pwsrc: "hwmon", pool: "gulf.moneroocean.stream", ts: now
      },
      {
        v: 1, id: "mini-pc", ver: "6.32.0", cpu: "Intel(R) N100", arch: "x86_64",
        cores: 4, thr: 4, algo: "rx/0", mode: "light", hs: [312.6, 305.8, 301.4, 318.0],
        hp: [0, 0], shares: [21, 0, 0], hash: 18651234, up: 7200,
        pw: null, pwsrc: "none", pool: "gulf.moneroocean.stream", ts: now
      }
    ];

    addRigs(samples.map(rigApi.normalise), true);
    setStatus("Đã thêm 3 máy mẫu. Xoá bằng nút Xoá hoặc \"Xoá tất cả\".", "ok");
  }

  function bind() {
    els = {
      status: $("status"),
      body: $("rig-body"),
      empty: $("rig-empty"),
      table: $("rig-table"),
      totals: $("rig-totals"),
      totalRow: $("total-row"),
      unknownNote: $("unknown-note"),
      breakEven: $("break-even"),
      window: $("set-window"),
      price: $("set-price"),
      psu: $("set-psu"),
      base: $("set-base"),
      mode: $("set-mode"),
      xmrKhs: $("set-xmr-khs"),
      xmrPrice: $("set-xmr-price"),
      netHash: $("set-net-hash"),
      reward: $("set-reward"),
      fee: $("set-fee"),
      poolFields: $("pool-fields"),
      networkFields: $("network-fields")
    };

    bindSettings();

    var addButton = $("add-rigs");
    if (addButton) {
      addButton.addEventListener("click", function () {
        var input = $("rig-input");
        handlePaste(input.value, false);
        if (state.rigs.length) input.value = "";
      });
    }

    var input = $("rig-input");
    if (input) {
      input.addEventListener("paste", function () {
        // Let the paste land in the textarea; a single code can be added at once.
        setTimeout(function () {
          var text = input.value.trim();
          if (/^ZMRIG1\.[A-Za-z0-9_-]+$/.test(text)) {
            handlePaste(text, true);
            input.value = "";
          }
        }, 0);
      });
    }

    var sample = $("sample");
    if (sample) sample.addEventListener("click", addSample);

    var clear = $("clear-rigs");
    if (clear) {
      clear.addEventListener("click", function () {
        if (!state.rigs.length) return;
        if (!confirm("Xoá toàn bộ " + state.rigs.length + " máy khỏi trình duyệt này?")) return;
        state.rigs = [];
        save();
        render();
        setStatus("Đã xoá tất cả.", "ok");
      });
    }

    var exporter = $("export-rigs");
    if (exporter) exporter.addEventListener("click", exportJson);

    var importer = $("import-rigs");
    if (importer) {
      importer.addEventListener("change", function () {
        importJson(importer.files && importer.files[0]);
        importer.value = "";
      });
    }

    var shareButton = $("share-link");
    if (shareButton) shareButton.addEventListener("click", share);
    var fetchButton = $("fetch-price");
    if (fetchButton) fetchButton.addEventListener("click", fetchPrice);

    document.addEventListener("click", function (event) {
      var remove = event.target.closest("[data-remove]");
      if (remove) {
        removeRig(remove.dataset.remove);
        return;
      }

      var th = event.target.closest("th[data-sort]");
      if (th) {
        var key = th.dataset.sort;
        if (state.sort.key === key) {
          state.sort.dir = -state.sort.dir;
        } else {
          state.sort.key = key;
          state.sort.dir = key === "name" ? 1 : -1;
        }
        render();
      }
    });

    document.addEventListener("change", function (event) {
      if (!event.target.classList.contains("power-input")) return;

      var key = event.target.dataset.key;
      var rig = state.rigs.find(function (item) { return rigKey(item) === key; });
      if (!rig) return;

      var value = Number(event.target.value);
      rig.wallOverride = event.target.value !== "" && isFinite(value) && value > 0 ? value : null;
      save();
      render();
      setStatus(rig.wallOverride === null ? "Đã bỏ ghi đè, dùng công suất tự tính." : "Đã ghi đè " + rig.wallOverride + " W cho " + rig.id + ".", "ok");
    });

    // A shared link carries the codes in the hash.
    var hash = location.hash || "";
    if (hash.indexOf("#rigs=") === 0) {
      handlePaste(decodeURIComponent(hash.slice(6)).split(",").join("\n"), true);
      history.replaceState(null, "", location.pathname + location.search);
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    load();
    bind();
    applySettingsToForm();
    render();
  });
})();
