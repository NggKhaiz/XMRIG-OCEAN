// Shared page behaviour: theme, mobile nav, copy buttons.
// Every page includes this file; it has no dependencies.

(function () {
  "use strict";

  var STORAGE_KEY = "zmrig.theme";

  function preferredTheme() {
    var stored = null;
    try { stored = localStorage.getItem(STORAGE_KEY); } catch (_) {}
    if (stored === "light" || stored === "dark") return stored;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    var button = document.querySelector("[data-theme-toggle]");
    if (button) {
      button.setAttribute("aria-label", theme === "dark" ? "Chuyển sang nền sáng" : "Chuyển sang nền tối");
      button.textContent = theme === "dark" ? "☀" : "☾";
    }
  }

  applyTheme(preferredTheme());

  document.addEventListener("click", function (event) {
    var toggle = event.target.closest("[data-theme-toggle]");
    if (toggle) {
      var next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
      try { localStorage.setItem(STORAGE_KEY, next); } catch (_) {}
      applyTheme(next);
      return;
    }

    var copy = event.target.closest(".copy-btn");
    if (copy) {
      var block = copy.closest("pre");
      var text = block ? block.querySelector("code") : null;
      var value = text ? text.innerText.replace(/\n$/, "") : "";
      copyText(value).then(function (ok) {
        copy.textContent = ok ? "Đã copy" : "Không copy được";
        copy.dataset.done = ok ? "1" : "0";
        setTimeout(function () { copy.textContent = "Copy"; delete copy.dataset.done; }, 1400);
      });
    }
  });

  function copyText(value) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(value).then(function () { return true; }, function () { return legacyCopy(value); });
    }
    return Promise.resolve(legacyCopy(value));
  }

  function legacyCopy(value) {
    var area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (_) {}
    document.body.removeChild(area);
    return ok;
  }

  // Code blocks get a copy button. Exposed because the docs render after
  // DOMContentLoaded and add their own <pre> blocks.
  function addCopyButtons(root) {
    (root || document).querySelectorAll("pre").forEach(function (block) {
      if (block.querySelector(".copy-btn")) return;
      var button = document.createElement("button");
      button.type = "button";
      button.className = "copy-btn";
      button.textContent = "Copy";
      block.appendChild(button);
    });
  }

  window.zmrigAddCopyButtons = addCopyButtons;

  document.addEventListener("DOMContentLoaded", function () { addCopyButtons(document); });

  // Small helper other scripts can use.
  window.zmrigFormat = {
    number: function (value, digits) {
      if (value === null || value === undefined || !isFinite(value)) return "—";
      return Number(value).toLocaleString("en-US", {
        minimumFractionDigits: digits === undefined ? 0 : digits,
        maximumFractionDigits: digits === undefined ? 0 : digits
      });
    },
    hashrate: function (value) {
      if (value === null || value === undefined || !isFinite(value)) return "—";
      if (value >= 1e6) return (value / 1e6).toFixed(2) + " MH/s";
      if (value >= 1e3) return (value / 1e3).toFixed(2) + " kH/s";
      return value.toFixed(1) + " H/s";
    },
    money: function (value, currency) {
      if (value === null || value === undefined || !isFinite(value)) return "—";
      var digits = Math.abs(value) >= 100 ? 2 : Math.abs(value) >= 1 ? 2 : Math.abs(value) >= 0.01 ? 3 : 4;
      return (currency || "$") + Number(value).toLocaleString("en-US", {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits
      });
    },
    xmr: function (value) {
      if (value === null || value === undefined || !isFinite(value)) return "—";
      return Number(value).toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 });
    }
  };
})();
