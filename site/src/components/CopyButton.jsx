import React, { useState } from "react";

// A copy button that tells the truth: it only says "Copied" after the clipboard
// call resolved, and it falls back to selecting the text when the browser
// refuses (which happens on http:// origins and in some iframes).
export default function CopyButton({ text, label, copiedLabel, className }) {
  const [state, setState] = useState("idle");

  async function copy(event) {
    try {
      await navigator.clipboard.writeText(text);
      setState("done");
    } catch {
      const pre = event.currentTarget
        .closest(".zm-builder__output, .zm-copy-scope")
        ?.querySelector("code");
      if (pre && window.getSelection) {
        const range = document.createRange();
        range.selectNodeContents(pre);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
      setState("manual");
    }
    setTimeout(() => setState("idle"), 2200);
  }

  const textLabel =
    state === "done" ? copiedLabel : state === "manual" ? "Ctrl+C" : label;

  return (
    <button
      type="button"
      className={className || "zm-btn"}
      onClick={copy}
      data-state={state}
      aria-live="polite"
    >
      {textLabel}
    </button>
  );
}
