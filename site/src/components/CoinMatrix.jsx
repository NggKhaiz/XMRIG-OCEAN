import React, { useEffect, useMemo, useState } from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import Link from "@docusaurus/Link";
import {
  COINS,
  findCoin,
  mergePrices,
  priceRequest,
  rankCoins,
} from "../lib/coins.mjs";
import { translate } from "../lib/messages.mjs";

const STORAGE_KEY = "zmrig.coins.v1";
const FIELDS = [
  "reward",
  "blockTime",
  "networkHashrate",
  "price",
  "rigHashrate",
];
const PRICE_TIMEOUT_MS = 8000;

// The numbers the table works from are the user's, so they are kept between
// visits. Only the figures — no address, no identifier, nothing that leaves the
// browser. A malformed or foreign object is ignored rather than merged: this is
// the one place where a stale shape could paint wrong money on the screen.
function loadRows() {
  if (typeof window === "undefined") return {};
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return {};
    const out = {};
    for (const coin of COINS) {
      const row = parsed[coin.id];
      if (!row || typeof row !== "object") continue;
      const clean = {};
      for (const field of FIELDS) {
        const value = row[field];
        if (typeof value === "number" && Number.isFinite(value))
          clean[field] = String(value);
        else if (typeof value === "string" && value.trim() !== "")
          clean[field] = value;
      }
      if (Object.keys(clean).length > 0) out[coin.id] = clean;
    }
    return out;
  } catch {
    return {};
  }
}

function saveRows(rows) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(rows));
  } catch {
    // Private mode, or the quota is full: the page still works, it just forgets.
  }
}

const usd = (value) => {
  if (value === null || value === undefined) return "—";
  const digits = value >= 1 ? 2 : value >= 0.01 ? 4 : 6;
  return "$" + value.toFixed(digits);
};

const coins = (value) => {
  if (value === null || value === undefined) return "—";
  if (value >= 1) return value.toFixed(4);
  return value.toPrecision(4);
};

const rate = (value) => {
  if (!Number.isFinite(value) || value <= 0) return "—";
  if (value >= 1e6) return (value / 1e6).toFixed(2) + " MH/s";
  if (value >= 1e3) return (value / 1e3).toFixed(2) + " kH/s";
  return value.toFixed(0) + " H/s";
};

export default function CoinMatrix({ hashrate }) {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const t = (key, params) => translate(locale, key, params);

  const [rows, setRows] = useState({});
  const [typed, setTyped] = useState({});
  const [prices, setPrices] = useState("idle"); // idle | loading | ok | error
  const [priceCount, setPriceCount] = useState(0);

  // The calculator above can hand in the fleet's total hashrate. It follows the
  // fleet until the moment somebody types their own figure, and then it stops:
  // silently overwriting a typed number would change an answer under their eyes.
  const fleet = Number(hashrate);
  // The calculator page hands in the fleet total; the standalone page does not,
  // so it starts from a visible assumption (4 kH/s, the size of one small box)
  // that the visitor can overwrite. It is in the field, not hidden in the
  // arithmetic: every figure on this page has to be one you can see and change.
  const [ownHashrate, setOwnHashrate] = useState("4000");
  const [followFleet, setFollowFleet] = useState(true);

  useEffect(() => {
    setRows(loadRows());
  }, []);

  // `null` — not 4000 — when nothing is typed and no fleet was handed in: an
  // empty field has to produce an empty ranking, or the page answers a question
  // about a machine that does not exist.
  const effectiveHashrate = useMemo(() => {
    const own = Number(ownHashrate);
    if (!followFleet && ownHashrate !== "" && Number.isFinite(own)) return own;
    if (Number.isFinite(fleet) && fleet > 0) return fleet;
    if (ownHashrate !== "" && Number.isFinite(own)) return own;
    return null;
  }, [followFleet, ownHashrate, fleet]);

  const merged = useMemo(() => {
    const list = COINS.map((coin) => ({
      id: coin.id,
      ...(rows[coin.id] || {}),
    }));
    return list;
  }, [rows]);

  const ranking = useMemo(
    () => rankCoins(merged, effectiveHashrate),
    [merged, effectiveHashrate],
  );

  const setField = (coinId, field) => (event) => {
    const value = event.target.value;
    setRows((prev) => {
      const next = {
        ...prev,
        [coinId]: { ...(prev[coinId] || {}), [field]: value },
      };
      saveRows(next);
      return next;
    });
  };

  const setHashrate = (event) => {
    const value = event.target.value;
    setOwnHashrate(value);
    setFollowFleet(false);
    setTyped((prev) => ({ ...prev, hashrate: true }));
  };

  async function fetchPrices() {
    const request = priceRequest();
    if (!request) return;
    setPrices("loading");
    const controller =
      typeof AbortController === "function" ? new AbortController() : null;
    const timer = controller
      ? setTimeout(() => controller.abort(), PRICE_TIMEOUT_MS)
      : null;
    try {
      const response = await fetch(request.url, {
        signal: controller ? controller.signal : undefined,
        headers: { accept: "application/json" },
      });
      if (!response.ok) throw new Error(String(response.status));
      const payload = await response.json();
      const answered = mergePrices(payload);
      if (answered.length === 0) throw new Error("empty");
      setRows((prev) => {
        const next = { ...prev };
        for (const item of answered) {
          next[item.id] = {
            ...(next[item.id] || {}),
            price: String(item.price),
          };
        }
        saveRows(next);
        return next;
      });
      setPriceCount(answered.length);
      setPrices("ok");
    } catch {
      // No network, a blocked host or a rate limit all end here. The prices the
      // user typed stay exactly as they were, and the message says what failed.
      setPrices("error");
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  function resetRows() {
    setRows({});
    saveRows({});
    setOwnHashrate("4000");
    setFollowFleet(true);
    setTyped({});
    setPrices("idle");
  }

  const best = ranking.best;
  const bestCoin = best ? findCoin(best.id) : null;
  const missingLabel = {
    reward: "coins.missingReward",
    blockTime: "coins.missingBlockTime",
    network: "coins.missingNetwork",
    price: "coins.missingPrice",
    hashrate: "coins.missingHashrate",
  };

  const statusHint =
    prices === "loading"
      ? t("coins.pricesLoading")
      : prices === "ok"
        ? t("coins.pricesOk", { n: priceCount })
        : prices === "error"
          ? t("coins.pricesError")
          : t("coins.pricesHint");

  return (
    <section className="zm-coins" id="zm-coins">
      <p className="zm-caption">{t("coins.lead")}</p>

      <div className="zm-calc__input">
        <label htmlFor="zm-coins-hashrate" className="zm-label">
          {t("coins.hashrate")}
        </label>
        <input
          id="zm-coins-hashrate"
          type="number"
          min="0"
          step="100"
          className="zm-input zm-input--tiny"
          value={
            !typed.hashrate && Number.isFinite(fleet) && fleet > 0
              ? Math.round(fleet)
              : ownHashrate
          }
          onChange={setHashrate}
        />
        <p className="zm-hint">{t("coins.hashrateHint")}</p>
        <div className="zm-btn-row">
          <button
            type="button"
            className="zm-btn zm-btn--primary"
            onClick={fetchPrices}
            disabled={prices === "loading"}
          >
            {prices === "loading"
              ? t("coins.pricesLoading")
              : t("coins.prices")}
          </button>
          <button type="button" className="zm-btn" onClick={resetRows}>
            {t("coins.reset")}
          </button>
        </div>
        <p className={prices === "error" ? "zm-hint is-bad" : "zm-hint"}>
          {statusHint}
        </p>
      </div>

      <div className={best ? "zm-best" : "zm-best is-empty"}>
        <span className="zm-card__label">{t("coins.best")}</span>
        {best ? (
          <>
            <span className="zm-best__value">
              {best.name} ({best.symbol})
            </span>
            <p className="zm-best__line">
              {t("coins.bestLine", {
                coin: best.name,
                revenue: usd(best.revenueDay),
                hashrate: rate(best.rigHashrate),
                coinDay: coins(best.coinDay),
                symbol: best.symbol,
              })}
            </p>
            <Link
              className="zm-btn zm-btn--primary"
              to={`/docs/install/builder?coin=${best.id}`}
            >
              {t("coins.build", { coin: best.name })}
            </Link>
          </>
        ) : (
          <p className="zm-best__line">{t("coins.bestEmpty")}</p>
        )}
      </div>

      <div className="zm-table-wrap">
        <table className="zm-table zm-table--coins">
          <thead>
            <tr>
              <th>{t("coins.tableCoin")}</th>
              <th>{t("coins.tableRevenue")}</th>
              <th>{t("coins.tableCoinDay")}</th>
              <th>{t("coins.tableStatus")}</th>
            </tr>
          </thead>
          <tbody>
            {ranking.ranked.map((row) => (
              <tr
                key={row.id}
                className={best && row.id === best.id ? "is-best" : undefined}
              >
                <td>
                  <span className="zm-rig-name">{row.name}</span>
                  <span className="zm-rig-meta">
                    {row.symbol} · {row.algo}
                  </span>
                </td>
                <td className="zm-num">
                  {row.revenueDay === null ? "—" : usd(row.revenueDay)}
                </td>
                <td className="zm-num">
                  {row.coinDay === null ? "—" : coins(row.coinDay)}
                </td>
                <td>
                  {row.missing.length === 0 ? (
                    <span className="zm-hint is-ok">{t("coins.ready")}</span>
                  ) : (
                    <span className="zm-hint">
                      {t("coins.needs", {
                        fields: row.missing
                          .map((field) => t(missingLabel[field] || field))
                          .join(", "),
                      })}
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <details className="zm-coins__edit">
        <summary>{t("coins.edit")}</summary>
        <div className="zm-coins__grid">
          {COINS.map((coin) => (
            <fieldset className="zm-fieldset" key={coin.id}>
              <legend>
                {coin.name} ({coin.symbol}) · {coin.algo}
              </legend>
              <div className="zm-coins__fields">
                {[
                  ["reward", "coins.fieldReward", coin.network.reward],
                  ["blockTime", "coins.fieldBlockTime", coin.network.blockTime],
                  [
                    "networkHashrate",
                    "coins.fieldNetwork",
                    coin.network.hashrate,
                  ],
                  ["price", "coins.fieldPrice", coin.network.price],
                  ["rigHashrate", "coins.fieldRig", null],
                ].map(([field, label, fallback]) => (
                  <label key={field} className="zm-coins__field">
                    <span className="zm-label">{t(label)}</span>
                    <input
                      type="number"
                      min="0"
                      className="zm-input zm-input--tiny"
                      value={
                        rows[coin.id]?.[field] ??
                        (fallback === null ? "" : String(fallback))
                      }
                      onChange={setField(coin.id, field)}
                    />
                  </label>
                ))}
              </div>
            </fieldset>
          ))}
        </div>
      </details>

      <p className="zm-hint">{t("coins.note")}</p>
      <p className="zm-caption">{t("coins.source")}</p>
      {bestCoin && bestCoin.pools.length === 0 ? (
        <p className="zm-caption">
          {t("builder.coinNoPools", { coin: bestCoin.name })}
        </p>
      ) : null}
    </section>
  );
}
