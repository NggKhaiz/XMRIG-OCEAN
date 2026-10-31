import React from "react";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import { POOLS, feeLabel, minLabel } from "../lib/pools.mjs";
import { translate } from "../lib/messages.mjs";

// The pool table on the page and the pool table in the builder come from the
// same array; `site/tests/pools.test.mjs` also holds it against oneclick.sh.
export default function PoolTable() {
  const { i18n } = useDocusaurusContext();
  const locale = i18n.currentLocale === "vi" ? "vi" : "en";
  const t = (key) => translate(locale, key);

  return (
    <div className="zm-table-wrap">
      <table className="zm-table">
        <thead>
          <tr>
            <th>{t("pooltable.pool")}</th>
            <th className="zm-num">{t("pooltable.fee")}</th>
            <th className="zm-num">{t("pooltable.min")}</th>
            <th>{t("pooltable.endpoint")}</th>
            <th>{t("pooltable.tls")}</th>
            <th>{t("pooltable.note")}</th>
          </tr>
        </thead>
        <tbody>
          {POOLS.map((pool) => (
            <tr key={pool.id}>
              <th scope="row">
                {pool.name}
                {pool.switching ? (
                  <span className="zm-badge">
                    {locale === "vi" ? "chuyển thuật toán" : "switching"}
                  </span>
                ) : null}
              </th>
              <td className="zm-num">{feeLabel(pool, locale)}</td>
              <td className="zm-num">{minLabel(pool, locale)}</td>
              <td>
                <code>{pool.host}</code>
              </td>
              <td>
                {pool.tlsHost ? <code>{pool.tlsHost}</code> : t("pooltable.no")}
              </td>
              <td className="zm-muted">{pool.why[locale]}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="zm-caption">{t("pooltable.checked")}</p>
    </div>
  );
}
