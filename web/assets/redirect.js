// Two publishing modes, two URL shapes, one site:
//
//   Source: GitHub Actions      the artifact is web/, so  /ZMRIG/docs.html
//   Source: Deploy from branch  the branch root is served, so  /ZMRIG/web/docs.html
//
// After the mode is switched, links that still carry the other prefix land on
// the 404 page. Strip the extra /web/ once and reload. The session flag stops a
// loop when the page is genuinely missing.

(function () {
  "use strict";

  var FLAG = "zmrig-stripped-web";

  if (sessionStorage.getItem(FLAG)) return;

  var parts = location.pathname.split("/");
  var index = parts.indexOf("web");
  if (index <= 0) return;

  sessionStorage.setItem(FLAG, "1");
  parts.splice(index, 1);
  location.replace(parts.join("/") + location.search + location.hash);
})();
