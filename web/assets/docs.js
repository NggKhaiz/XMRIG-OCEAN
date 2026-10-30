// Documentation shell: loads content/<lang>/index.json, renders one page at a
// time from Markdown, keeps the URL hash in sync and searches across all pages.

(function () {
  "use strict";

  var BASE = "content/vi/";
  var manifest = null;
  var cache = {};       // slug -> { html, text, headings, page }
  var current = null;
  var nav = null;
  var article = null;
  var pager = null;
  var search = null;
  var searchResults = null;

  function fetchText(url) {
    return fetch(url, { cache: "no-cache" }).then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status + " — " + url);
      return response.text();
    });
  }

  function loadPage(page) {
    if (cache[page.slug]) return Promise.resolve(cache[page.slug]);

    return fetchText(BASE + page.file).then(function (markdown) {
      var rendered = window.zmrigMarkdown.render(markdown);
      var entry = {
        html: rendered.html,
        headings: rendered.headings,
        page: page,
        text: markdown
          .replace(/```[\s\S]*?```/g, " ")
          .replace(/[#>*`|_-]/g, " ")
          .replace(/\s+/g, " ")
      };
      cache[page.slug] = entry;
      return entry;
    });
  }

  function buildNav() {
    var groups = [];
    var byGroup = {};

    manifest.pages.forEach(function (page) {
      if (!byGroup[page.group]) {
        byGroup[page.group] = [];
        groups.push(page.group);
      }
      byGroup[page.group].push(page);
    });

    var html = groups.map(function (group) {
      var links = byGroup[group].map(function (page) {
        return '<a href="#' + page.slug + '" data-slug="' + page.slug + '">' +
          window.zmrigMarkdown.escapeHtml(page.title) + "</a>";
      }).join("");

      return "<h4>" + window.zmrigMarkdown.escapeHtml(group) + '</h4><div class="side-links">' + links + "</div>";
    }).join("");

    nav.innerHTML = html;
  }

  function markActive(slug) {
    var links = nav.querySelectorAll("a[data-slug]");
    for (var i = 0; i < links.length; i++) {
      if (links[i].dataset.slug === slug) {
        links[i].classList.add("active");
        links[i].setAttribute("aria-current", "page");
      } else {
        links[i].classList.remove("active");
        links[i].removeAttribute("aria-current");
      }
    }
  }

  function renderPager(index) {
    var previous = manifest.pages[index - 1];
    var next = manifest.pages[index + 1];

    pager.innerHTML =
      (previous ? '<a class="btn small" href="#' + previous.slug + '">← ' + window.zmrigMarkdown.escapeHtml(previous.title) + "</a>" : "<span></span>") +
      (next ? '<a class="btn small" href="#' + next.slug + '">' + window.zmrigMarkdown.escapeHtml(next.title) + " →</a>" : "<span></span>");
  }

  function showPage(slug, anchor) {
    var index = manifest.pages.findIndex(function (page) { return page.slug === slug; });
    if (index === -1) {
      // Unknown hash: maybe it is a heading inside the current page.
      if (current && document.getElementById(slug)) {
        document.getElementById(slug).scrollIntoView();
        return;
      }
      index = 0;
      slug = manifest.pages[0].slug;
    }

    var page = manifest.pages[index];
    markActive(page.slug);
    renderPager(index);

    if (current && current.slug === slug) {
      if (anchor) scrollToAnchor(anchor);
      return;
    }

    article.innerHTML = '<p class="muted">Đang tải…</p>';

    loadPage(page).then(function (entry) {
      current = page;
      article.innerHTML = entry.html;
      document.title = page.title + " — ZMRIG";
      window.zmrigAddCopyButtons(article);
      scrollToAnchor(anchor);
    }).catch(function (error) {
      article.innerHTML = '<h1>Không tải được tài liệu</h1>' +
        '<p class="muted">' + window.zmrigMarkdown.escapeHtml(error.message) + "</p>" +
        "<p>Trang này đọc file Markdown bằng <code>fetch()</code>, nên phải chạy qua HTTP server. " +
        "Mở trực tiếp bằng <code>file://</code> sẽ bị trình duyệt chặn. " +
        "Chạy <code>python3 -m http.server -d web 8080</code> rồi mở " +
        '<code>http://localhost:8080/docs.html</code>.</p>';
    });
  }

  function scrollToAnchor(anchor) {
    if (!anchor) {
      window.scrollTo({ top: 0, behavior: "instant" in window ? "instant" : "auto" });
      return;
    }

    var target = document.getElementById(anchor);
    if (target) {
      target.scrollIntoView();
    } else {
      window.scrollTo({ top: 0 });
    }
  }

  function route() {
    var hash = decodeURIComponent((location.hash || "").replace(/^#/, ""));
    if (!hash) {
      showPage(manifest.pages[0].slug);
      return;
    }

    var parts = hash.split("#");
    var slug = parts[0];
    var anchor = parts[1];

    if (manifest.pages.some(function (page) { return page.slug === slug; })) {
      showPage(slug, anchor);
      return;
    }

    // A heading id on its own, e.g. #benchmark
    if (current && document.getElementById(slug)) {
      document.getElementById(slug).scrollIntoView();
      return;
    }

    showPage(manifest.pages[0].slug);
  }

  function runSearch(query) {
    var needle = query.trim().toLowerCase();
    if (needle.length < 2) {
      searchResults.innerHTML = "";
      searchResults.hidden = true;
      return;
    }

    searchResults.hidden = false;
    searchResults.innerHTML = '<p class="muted small">Đang tìm…</p>';

    Promise.all(manifest.pages.map(loadPage)).then(function (entries) {
      var hits = [];

      entries.forEach(function (entry) {
        var text = entry.text;
        var index = text.toLowerCase().indexOf(needle);
        if (index === -1 && entry.page.title.toLowerCase().indexOf(needle) === -1) return;

        var snippet = "";
        if (index !== -1) {
          var start = Math.max(0, index - 60);
          var end = Math.min(text.length, index + needle.length + 80);
          var before = text.slice(start, index);
          var match = text.slice(index, index + needle.length);
          var after = text.slice(index + needle.length, end);
          snippet = (start > 0 ? "…" : "") + window.zmrigMarkdown.escapeHtml(before) +
            "<b>" + window.zmrigMarkdown.escapeHtml(match) + "</b>" +
            window.zmrigMarkdown.escapeHtml(after) + (end < text.length ? "…" : "");
        }

        hits.push({ page: entry.page, snippet: snippet });
      });

      if (!hits.length) {
        searchResults.innerHTML = '<p class="muted small">Không có kết quả cho “' +
          window.zmrigMarkdown.escapeHtml(query) + "”.</p>";
        return;
      }

      searchResults.innerHTML = hits.slice(0, 12).map(function (hit) {
        return '<a class="search-hit" href="#' + hit.page.slug + '"><strong>' +
          window.zmrigMarkdown.escapeHtml(hit.page.title) + "</strong><br>" +
          '<span class="small muted">' + (hit.snippet || "khớp tiêu đề") + "</span></a>";
      }).join("");
    }).catch(function (error) {
      searchResults.innerHTML = '<p class="muted small">Lỗi tìm kiếm: ' + window.zmrigMarkdown.escapeHtml(error.message) + "</p>";
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    nav = document.getElementById("doc-nav");
    article = document.getElementById("doc-article");
    pager = document.getElementById("doc-pager");
    search = document.getElementById("doc-search");
    searchResults = document.getElementById("doc-search-results");

    search.addEventListener("input", function () {
      clearTimeout(search.timer);
      search.timer = setTimeout(function () { runSearch(search.value); }, 120);
    });

    window.addEventListener("hashchange", route);

    fetchText(BASE + "index.json").then(function (text) {
      manifest = JSON.parse(text);
      buildNav();
      route();
    }).catch(function (error) {
      article.innerHTML = '<h1>Không tải được mục lục</h1>' +
        '<p class="muted">' + window.zmrigMarkdown.escapeHtml(error.message) + "</p>" +
        '<p>Chạy một HTTP server tại thư mục <code>web/</code>: <code>python3 -m http.server 8080</code>.</p>';
    });
  });
})();
