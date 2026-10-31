import React from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import { useColorMode } from "@docusaurus/theme-common";
import clsx from "clsx";

// Three states, because two is a lie: with a two-state switch, a visitor who
// once clicked "dark" can never get back to "follow the system". Docusaurus
// already stores `null` for "system" — this exposes it.
const OPTIONS = [
  { value: null, label: "System", labelVi: "Hệ thống", icon: "auto" },
  { value: "light", label: "Light", labelVi: "Sáng", icon: "light" },
  { value: "dark", label: "Dark", labelVi: "Tối", icon: "dark" },
];

function Icon({ name }) {
  if (name === "light") {
    return (
      <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
        <circle cx="12" cy="12" r="4.2" fill="currentColor" />
        <g stroke="currentColor" strokeWidth="1.7" strokeLinecap="round">
          <path d="M12 2.4v2.2M12 19.4v2.2M2.4 12h2.2M19.4 12h2.2M5.2 5.2l1.6 1.6M17.2 17.2l1.6 1.6M18.8 5.2l-1.6 1.6M6.8 17.2l-1.6 1.6" />
        </g>
      </svg>
    );
  }
  if (name === "dark") {
    return (
      <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
        <path
          d="M20 14.4A8.4 8.4 0 0 1 9.6 4a8.4 8.4 0 1 0 10.4 10.4Z"
          fill="currentColor"
        />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
      <rect
        x="2.6"
        y="4.2"
        width="18.8"
        height="13"
        rx="2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.7"
      />
      <path d="M8 20.4h8" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
      <path d="M6.2 7h6" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  );
}

export default function ColorModeToggle() {
  const { colorModeChoice, setColorMode } = useColorMode();
  // The locale comes from the site context, not from document.lang: the labels
  // are rendered on the server too, and reading `document` there produced an
  // English switch on every Vietnamese page until hydration.
  const { i18n } = useDocusaurusContext();
  const vi = i18n.currentLocale === "vi";

  return (
    <div className="zm-theme-switch" role="group" aria-label={vi ? "Giao diện" : "Colour scheme"}>
      {OPTIONS.map((option) => {
        const active = colorModeChoice === option.value;
        return (
          <button
            key={String(option.value)}
            type="button"
            className={clsx("zm-theme-switch__btn", active && "is-active")}
            aria-pressed={active}
            title={vi ? option.labelVi : option.label}
            onClick={() => setColorMode(option.value)}
          >
            <Icon name={option.icon} />
            <span className="zm-theme-switch__label">{vi ? option.labelVi : option.label}</span>
          </button>
        );
      })}
    </div>
  );
}
