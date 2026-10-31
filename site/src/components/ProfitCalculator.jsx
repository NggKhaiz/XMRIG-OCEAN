import React, { useEffect, useMemo, useState } from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import {
  DEFAULTS,
  decodeMany,
  compute,
  totals,
  PREFIX,
} from "../lib/report.mjs";
import { translate } from "../lib/messages.mjs";
import CoinMatrix from "./CoinMatrix";

const STORAGE_KEY = "zmrig.calc.v2";

// Three machines that actually exist in the wild: a mini PC someone already
// owns, a small VPS and an old desktop. They are labelled as samples, and the
// numbers are the kind the miner itself prints.
const SAMPLE = [
  {
    id: "mini-pc",
    ver: "6.32.1",
    cpu: "Intel N100",
    thr: 4,
    algo: "rx/0",
    mode: "fast",
    hs: [742, 748, 745, 751],
    hp: [1234, 1234],
    shares: [412, 58, 2],
    up: 5400,
    pw: 12,
    pwsrc: "user",
  },
  {
    id: "vps-sg-02",
    ver: "6.32.1",
    cpu: "AMD EPYC 7B13",
    thr: 2,
    algo: "rx/0",
    mode: "fast",
    hs: [1461, 1470, 1466, 1478],
    hp: [1234, 1234],
    shares: [806, 121, 5],
    up: 86400,
    pw: 22,
    pwsrc: "rapl",
  },
  {
    id: "office-xeon",
    ver: "6.32.0",
    cpu: "Xeon E5-2670 v3",
    thr: 8,
    algo: "rx/0",
    mode: "fast",
    hs: [3760, 3792, 3771, 3806],
    hp: [1234, 1234],
    shares: [1904, 302, 12],
    up: 172800,
    pw: 96,
    pwsrc: "user",
  },
];

function encodeRig(rig) {
  const json = JSON.stringify(rig);
  const bytes = new TextEncoder().encode(json);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return (
    PREFIX +
    btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  );
}

function loadState() {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function money(value, locale) {
  if (value === null || value === undefined || !Number.isFinite(value))
    return "—";
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 4,
  }).format(value);
}

// Electricity is quoted per kWh and the useful digits are the third one: a
// break-even of 0.012 $/kWh rounded to cents reads as "0.01", which is wrong by
// 20 %.
function price(value, locale) {
  if (value === null || value === undefined || !Number.isFinite(value))
    return "—";
  return (
    "$" +
    new Intl.NumberFormat(locale, { maximumFractionDigits: 4 }).format(value) +
    "/kWh"
  );
}

function hash(value, locale) {
  if (value === null || value === undefined || !Number.isFinite(value))
    return "—";
  return (
    new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(value) +
    " H/s"
  );
}

function fixed(value, digits, locale) {
  if (value === null || value === undefined || !Number.isFinite(value))
    return "—";
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

export default function ProfitCalculator() {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const t = (key, params) => translate(locale, key, params);

  const [text, setText] = useState("");
  const [errors, setErrors] = useState([]);
  const [rows, setRows] = useState([]);
  const [overrides, setOverrides] = useState({});
  const [settings, setSettings] = useState({ ...DEFAULTS });
  const [ready, setReady] = useState(false);

  // Restore the last session. Kept in localStorage only: there is no server to
  // send a fleet listing to, and there never will be.
  useEffect(() => {
    const saved = loadState();
    if (saved) {
      if (saved.settings)
        setSettings((prev) => ({ ...prev, ...saved.settings }));
      if (Array.isArray(saved.codes) && saved.codes.length > 0) {
        const decoded = decodeMany(saved.codes.join("\n"));
        setRows(
          decoded.rigs.map((rig, index) => ({
            key: `${rig.id}-${index}`,
            rig,
          })),
        );
      }
      if (saved.overrides) setOverrides(saved.overrides);
    }
    setReady(true);
  }, []);

  useEffect(() => {
    if (!ready) return;
    try {
      window.localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          settings,
          overrides,
          codes: rows.map((row) => encodeRig(row.rig)),
        }),
      );
    } catch {
      /* storage full or blocked: the calculator still works for this visit */
    }
  }, [ready, settings, overrides, rows]);

  const computed = useMemo(
    () =>
      rows.map((row) => ({
        key: row.key,
        rig: row.rig,
        result: compute(row.rig, settings, overrides[row.key]),
      })),
    [rows, settings, overrides],
  );

  const sum = useMemo(() => totals(computed), [computed]);

  function add() {
    const decoded = decodeMany(text);
    setErrors(decoded.errors);
    if (decoded.rigs.length > 0) {
      setRows((prev) => [
        ...prev,
        ...decoded.rigs.map((rig, index) => ({
          key: `${rig.id}-${Date.now()}-${index}`,
          rig,
        })),
      ]);
      setText("");
    }
  }

  function loadSample() {
    setRows(
      SAMPLE.map((rig, index) => ({
        key: `sample-${index}`,
        rig: decodeManyJson(rig),
      })),
    );
    setErrors([]);
  }

  function decodeManyJson(raw) {
    return decodeMany(encodeRig(raw)).rigs[0];
  }

  function setSetting(key) {
    return (event) => {
      const value = event.target.value;
      setSettings((prev) => ({
        ...prev,
        [key]:
          typeof DEFAULTS[key] === "number"
            ? value === ""
              ? ""
              : Number(value)
            : value,
      }));
    };
  }

  function exportJson() {
    const payload = JSON.stringify(
      { settings, rigs: rows.map((row) => row.rig) },
      null,
      2,
    );
    const blob = new Blob([payload], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "zmrig-fleet.json";
    link.click();
    URL.revokeObjectURL(url);
  }

  const windows = [
    { index: 0, label: t("calc.w10") },
    { index: 1, label: t("calc.w60") },
    { index: 2, label: t("calc.w15") },
    { index: 3, label: t("calc.wBest") },
  ];

  return (
    <div className="zm-calc">
      <p className="zm-caption">{t("calc.intro")}</p>

      <div className="zm-calc__input">
        <label htmlFor="zm-calc-paste" className="zm-label">
          {t("calc.paste")}
        </label>
        <textarea
          id="zm-calc-paste"
          className="zm-input zm-input--area"
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="ZMRIG1.…"
          spellCheck="false"
        />
        <p className="zm-hint">{t("calc.pasteHint")}</p>
        <div className="zm-btn-row">
          <button
            type="button"
            className="zm-btn zm-btn--primary"
            onClick={add}
          >
            {t("calc.add")}
          </button>
          <button type="button" className="zm-btn" onClick={loadSample}>
            {t("calc.sample")}
          </button>
          <button
            type="button"
            className="zm-btn"
            onClick={exportJson}
            disabled={rows.length === 0}
          >
            {t("calc.export")}
          </button>
          <button
            type="button"
            className="zm-btn"
            onClick={() => {
              setRows([]);
              setOverrides({});
              setErrors([]);
              setText("");
            }}
          >
            {t("calc.clear")}
          </button>
          <label className="zm-btn zm-btn--file">
            {t("calc.import")}
            <input
              type="file"
              accept="application/json,.json"
              onChange={async (event) => {
                const file = event.target.files?.[0];
                if (!file) return;
                try {
                  const parsed = JSON.parse(await file.text());
                  const list = Array.isArray(parsed)
                    ? parsed
                    : parsed.rigs || [parsed];
                  const added = [];
                  for (const item of list) {
                    const decoded = decodeMany(encodeRig(item));
                    if (decoded.rigs[0]) added.push(decoded.rigs[0]);
                  }
                  setRows((prev) => [
                    ...prev,
                    ...added.map((rig, index) => ({
                      key: `${rig.id}-f-${Date.now()}-${index}`,
                      rig,
                    })),
                  ]);
                  if (parsed.settings)
                    setSettings((prev) => ({ ...prev, ...parsed.settings }));
                  setErrors([]);
                } catch {
                  setErrors([{ code: file.name, reason: "JSON" }]);
                }
                event.target.value = "";
              }}
            />
          </label>
        </div>
      </div>

      {errors.length > 0 ? (
        <div className="zm-alert">
          <strong>{t("calc.errors")}</strong>
          <ul>
            {errors.map((error, index) => (
              <li key={index}>
                <code>{error.code}</code> — {error.reason}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <details className="zm-details" open={rows.length === 0}>
        <summary>{t("calc.settings")}</summary>
        <div className="zm-grid">
          <label className="zm-field">
            <span>{t("calc.price")}</span>
            <input
              type="number"
              step="0.001"
              min="0"
              className="zm-input"
              value={settings.price}
              onChange={setSetting("price")}
            />
          </label>
          <label className="zm-field">
            <span>{t("calc.psu")}</span>
            <input
              type="number"
              step="1"
              min="50"
              max="100"
              className="zm-input"
              value={settings.psuEff}
              onChange={setSetting("psuEff")}
            />
          </label>
          <label className="zm-field">
            <span>{t("calc.base")}</span>
            <input
              type="number"
              step="1"
              min="0"
              className="zm-input"
              value={settings.baseW}
              onChange={setSetting("baseW")}
            />
          </label>
          <label className="zm-field">
            <span>{t("calc.xmrPrice")}</span>
            <input
              type="number"
              step="1"
              min="0"
              className="zm-input"
              value={settings.xmrPrice}
              onChange={setSetting("xmrPrice")}
            />
          </label>
          <label className="zm-field">
            <span>{t("calc.window")}</span>
            <select
              className="zm-input"
              value={settings.window}
              onChange={(event) =>
                setSettings((prev) => ({
                  ...prev,
                  window: Number(event.target.value),
                }))
              }
            >
              {windows.map((item) => (
                <option key={item.index} value={item.index}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
          <label className="zm-field">
            <span>{t("calc.payout")}</span>
            <select
              className="zm-input"
              value={settings.payoutMode}
              onChange={(event) =>
                setSettings((prev) => ({
                  ...prev,
                  payoutMode: event.target.value,
                }))
              }
            >
              <option value="pool">{t("calc.payoutPool")}</option>
              <option value="network">{t("calc.payoutNetwork")}</option>
            </select>
          </label>
          {settings.payoutMode === "pool" ? (
            <label className="zm-field">
              <span>{t("calc.xmrPerKhsDay")}</span>
              <input
                type="number"
                step="0.000001"
                min="0"
                className="zm-input"
                value={settings.xmrPerKhsDay}
                onChange={setSetting("xmrPerKhsDay")}
              />
            </label>
          ) : (
            <>
              <label className="zm-field">
                <span>{t("calc.networkHash")}</span>
                <input
                  type="number"
                  step="0.1"
                  min="0.1"
                  className="zm-input"
                  value={settings.networkHash / 1e9}
                  onChange={(event) =>
                    setSettings((prev) => ({
                      ...prev,
                      networkHash: Number(event.target.value) * 1e9,
                    }))
                  }
                />
              </label>
              <label className="zm-field">
                <span>{t("calc.blockReward")}</span>
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  className="zm-input"
                  value={settings.blockReward}
                  onChange={setSetting("blockReward")}
                />
              </label>
              <label className="zm-field">
                <span>{t("calc.poolFee")}</span>
                <input
                  type="number"
                  step="0.1"
                  min="0"
                  className="zm-input"
                  value={settings.poolFee}
                  onChange={setSetting("poolFee")}
                />
              </label>
            </>
          )}
        </div>
      </details>

      {/* The saved fleet is restored in an effect, so the first paint always has
          zero rows. Showing "nothing here yet" for that one frame reads as a
          flicker; the empty state waits until the restore has run. Server-side
          this renders nothing at all, which is also what the first client
          render produces — no hydration mismatch. */}
      {!ready ? null : rows.length === 0 ? (
        <p className="zm-empty">{t("calc.empty")}</p>
      ) : (
        <>
          <div className="zm-cards">
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.totalHashrate")}</span>
              <strong>{hash(sum.hashrate, locale)}</strong>
              <span className="zm-card__sub">
                {sum.machines} {t("calc.machines")}
              </span>
            </div>
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.totalWatts")}</span>
              <strong>{fixed(sum.wallWatts, 0, locale)} W</strong>
              <span className="zm-card__sub">
                {fixed(sum.kwhDay, 2, locale)} {t("calc.kwh")}
              </span>
            </div>
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.totalRevenue")}</span>
              <strong>{money(sum.revenueDay, locale)}</strong>
              <span className="zm-card__sub">
                {fixed(sum.xmrDay, 6, locale)} XMR
              </span>
            </div>
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.totalProfit")}</span>
              <strong className={sum.profitDay < 0 ? "is-bad" : "is-ok"}>
                {money(sum.profitDay, locale)}
              </strong>
              <span className="zm-card__sub">
                {money(sum.profitMonth, locale)} {t("calc.perMonth")}
              </span>
            </div>
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.efficiency")}</span>
              <strong>
                {sum.efficiency ? fixed(sum.efficiency, 2, locale) : "—"}
              </strong>
              <span className="zm-card__sub">H/W</span>
            </div>
            <div className="zm-card">
              <span className="zm-card__label">{t("calc.breakEven")}</span>
              <strong>{price(sum.breakEvenPrice, locale)}</strong>
              <span className="zm-card__sub">{t("calc.breakEvenSub")}</span>
            </div>
          </div>

          <div className="zm-table-wrap">
            <table className="zm-table zm-table--calc">
              <thead>
                <tr>
                  <th>{t("calc.machine")}</th>
                  <th className="zm-num">{t("calc.hashrate")}</th>
                  <th className="zm-num">{t("calc.override")}</th>
                  <th className="zm-num">{t("calc.kwh")}</th>
                  <th className="zm-num">{t("calc.cost")}</th>
                  <th className="zm-num">{t("calc.xmr")}</th>
                  <th className="zm-num">{t("calc.revenue")}</th>
                  <th className="zm-num">{t("calc.profit")}</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {computed.map((row) => (
                  <tr key={row.key}>
                    <th scope="row">
                      <span className="zm-rig-name">{row.rig.id}</span>
                      <span className="zm-rig-meta">
                        {row.rig.cpu} · {row.rig.threads} thr · {row.rig.algo}
                      </span>
                    </th>
                    <td className="zm-num">
                      {hash(row.result.hashrate, locale)}
                    </td>
                    <td className="zm-num">
                      <input
                        type="number"
                        min="0"
                        className="zm-input zm-input--tiny"
                        value={overrides[row.key] ?? ""}
                        placeholder={
                          row.result.wallWatts
                            ? fixed(row.result.wallWatts, 0, locale)
                            : "—"
                        }
                        onChange={(event) => {
                          const value = event.target.value;
                          setOverrides((prev) => ({
                            ...prev,
                            [row.key]: value,
                          }));
                        }}
                        aria-label={`${row.rig.id} ${t("calc.override")}`}
                      />
                    </td>
                    <td className="zm-num">
                      {fixed(row.result.kwhDay, 2, locale)}
                    </td>
                    <td className="zm-num">
                      {money(row.result.costDay, locale)}
                    </td>
                    <td className="zm-num">
                      {fixed(row.result.xmrDay, 6, locale)}
                    </td>
                    <td className="zm-num">
                      {money(row.result.revenueDay, locale)}
                    </td>
                    <td
                      className={
                        row.result.profitDay < 0 ? "zm-num is-bad" : "zm-num"
                      }
                    >
                      {money(row.result.profitDay, locale)}
                    </td>
                    <td className="zm-num">
                      <button
                        type="button"
                        className="zm-icon-btn"
                        aria-label={t("calc.remove")}
                        onClick={() =>
                          setRows((prev) =>
                            prev.filter((item) => item.key !== row.key),
                          )
                        }
                      >
                        ×
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {sum.unknownPower > 0 ? (
            <p className="zm-hint is-bad">
              {t("calc.unknownPower", { n: sum.unknownPower })}
            </p>
          ) : null}
        </>
      )}

      <p className="zm-caption">{t("calc.note")}</p>

      {/* The fleet total is handed straight in: "which coin pays best for *this*
          hardware" is the question the calculator exists to answer, and the
          comparison is where it gets answered. */}
      <h2 id="coins">{t("coins.title")}</h2>
      <CoinMatrix hashrate={sum.hashrate > 0 ? sum.hashrate : undefined} />
    </div>
  );
}
