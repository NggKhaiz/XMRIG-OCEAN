// Minimal, dependency-free Markdown renderer for the documentation pages.
// Supported: headings, fenced code, tables, lists, blockquotes, rules,
// paragraphs and inline code / bold / emphasis / links / images.
// Everything is HTML-escaped before any markup is produced.

(function () {
  "use strict";

  function escapeHtml(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function slugify(text) {
    return text
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .replace(/đ/g, "d").replace(/Đ/g, "D")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60);
  }

  // Links may only point at something a documentation page can legitimately
  // reach: another page, an anchor, http(s), or mail. Anything else (notably
  // `javascript:`) is rendered as plain text rather than as a live link.
  function safeHref(href) {
    if (/^(https?:|mailto:|#|\.{0,2}\/)/i.test(href)) return true;
    return /^[\w./-]+(#.*)?$/.test(href);
  }

  // Images are allowed from the same places, and only those: an `src` that
  // could not be a static asset is left as text.
  function safeSrc(src) {
    if (/^(https?:|\.{0,2}\/)/i.test(src)) return true;
    return /^[\w./-]+$/.test(src);
  }

  function inline(text) {
    // Code spans are cut out first and put back last: nothing inside them may
    // be reformatted, and a label like [`doc/DONATE.md`](…), where the label is
    // itself a code span, still has to survive as a link.
    var codes = [];
    var masked = text.replace(/`([^`]+)`/g, function (_, code) {
      codes.push("<code>" + escapeHtml(code) + "</code>");
      return "\u0000" + (codes.length - 1) + "\u0000";
    });

    var out = escapeHtml(masked);

    // Images first: `![alt](src)` contains a link's shape.
    out = out.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, function (match, alt, src) {
      if (!safeSrc(src)) return match;
      return '<img src="' + src + '" alt="' + alt + '" loading="lazy">';
    });

    out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, label, href) {
      if (!safeHref(href)) return label;
      var external = /^https?:/i.test(href);
      return '<a href="' + href + '"' + (external ? ' target="_blank" rel="noreferrer"' : "") + ">" + label + "</a>";
    });

    out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    out = out.replace(/(^|[\s(])\*([^*\n]+)\*/g, "$1<em>$2</em>");

    return out.replace(/\u0000(\d+)\u0000/g, function (_, index) {
      return codes[Number(index)];
    });
  }

  function isTableSeparator(line) {
    return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);
  }

  function splitRow(line) {
    var trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
    return trimmed.split("|").map(function (cell) { return cell.trim(); });
  }

  function render(source) {
    var lines = source.replace(/\r\n?/g, "\n").split("\n");
    var html = [];
    var headings = [];
    var i = 0;

    function closeList(stack) {
      while (stack.length) html.push(stack.pop());
    }

    var listStack = [];

    while (i < lines.length) {
      var line = lines[i];

      // Fenced code
      var fence = line.match(/^\s*```\s*([\w+-]*)\s*$/);
      if (fence) {
        closeList(listStack);
        var lang = fence[1];
        var buf = [];
        i++;
        while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) {
          buf.push(lines[i]);
          i++;
        }
        i++; // closing fence
        html.push('<pre><code' + (lang ? ' class="lang-' + lang + '"' : "") + ">" +
          escapeHtml(buf.join("\n")) + "</code></pre>");
        continue;
      }

      // Heading
      var heading = line.match(/^(#{1,4})\s+(.*)$/);
      if (heading) {
        closeList(listStack);
        var level = heading[1].length;
        var text = heading[2].trim();
        var id = slugify(text);
        var suffix = 2;
        while (headings.some(function (h) { return h.id === id; })) {
          id = slugify(text) + "-" + suffix++;
        }
        headings.push({ level: level, text: text, id: id });
        html.push("<h" + level + ' id="' + id + '">' + inline(text) +
          '<a class="anchor" href="#' + id + '" aria-hidden="true">#</a></h' + level + ">");
        i++;
        continue;
      }

      // Horizontal rule
      if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) {
        closeList(listStack);
        html.push("<hr>");
        i++;
        continue;
      }

      // Table: header line followed by a separator line
      if (line.indexOf("|") !== -1 && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
        closeList(listStack);
        var head = splitRow(line);
        var aligns = splitRow(lines[i + 1]).map(function (cell) {
          if (/^:-+:$/.test(cell)) return "center";
          if (/-+:$/.test(cell)) return "right";
          return "left";
        });

        var rows = [];
        i += 2;
        while (i < lines.length && lines[i].indexOf("|") !== -1 && lines[i].trim() !== "") {
          rows.push(splitRow(lines[i]));
          i++;
        }

        var table = ['<div class="table-wrap"><table><thead><tr>'];
        head.forEach(function (cell, index) {
          table.push('<th' + (aligns[index] === "right" ? ' class="num"' : "") + ">" + inline(cell) + "</th>");
        });
        table.push("</tr></thead><tbody>");
        rows.forEach(function (row) {
          table.push("<tr>");
          head.forEach(function (_, index) {
            var cell = row[index] === undefined ? "" : row[index];
            table.push("<td" + (aligns[index] === "right" ? ' class="num"' : "") + ">" + inline(cell) + "</td>");
          });
          table.push("</tr>");
        });
        table.push("</tbody></table></div>");
        html.push(table.join(""));
        continue;
      }

      // Blockquote
      if (/^\s*>\s?/.test(line)) {
        closeList(listStack);
        var quote = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
          quote.push(lines[i].replace(/^\s*>\s?/, ""));
          i++;
        }
        html.push("<blockquote><p>" + inline(quote.join(" ")) + "</p></blockquote>");
        continue;
      }

      // Lists (one nested level is enough for this documentation)
      var item = line.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
      if (item) {
        var indent = item[1].length;
        var ordered = /\d+\./.test(item[2]);
        var tag = ordered ? "ol" : "ul";

        if (indent >= 2 && listStack.length === 1) {
          html.push("<" + tag + ">");
          listStack.push("</" + tag + ">");
        } else if (listStack.length === 0) {
          html.push("<" + tag + ">");
          listStack.push("</" + tag + ">");
        } else if (listStack.length > 1) {
          html.push(listStack.pop());
        }

        html.push("<li>" + inline(item[3]) + "</li>");
        i++;
        continue;
      }

      // Blank line ends a list, an indented continuation is folded in.
      if (line.trim() === "") {
        closeList(listStack);
        i++;
        continue;
      }

      if (listStack.length && /^\s{2,}\S/.test(line)) {
        // Continuation of the previous list item.
        var last = html.length - 1;
        html[last] = html[last].replace(/<\/li>$/, " " + inline(line.trim()) + "</li>");
        i++;
        continue;
      }

      // Paragraph
      closeList(listStack);
      var para = [line];
      i++;
      while (
        i < lines.length &&
        lines[i].trim() !== "" &&
        !/^\s*(#{1,4}\s|```|\||>|[-*+]\s|\d+\.\s)/.test(lines[i]) &&
        !/^\s*(-{3,}|\*{3,})\s*$/.test(lines[i])
      ) {
        para.push(lines[i]);
        i++;
      }
      html.push("<p>" + inline(para.join(" ")) + "</p>");
    }

    closeList(listStack);

    return { html: html.join("\n"), headings: headings };
  }

  window.zmrigMarkdown = { render: render, escapeHtml: escapeHtml };
})();
