// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Show everything in a PredictManager: DUSDC balance, P&L, open directional
// positions, and open range positions — all sourced from the public indexer.
//
// Read-only: no signer needed.

import { predictObjectID } from "../../config/constants.js";

// === Manager to inspect =============================================
const CONFIG = {
  MANAGER_ID:
    "0x51f082104ca41498acdbd6181786978117ae4cc34a72a9a847083ecffe0011ea",
};
// Env var MANAGER_ID overrides CONFIG.
// ====================================================================

const SERVER =
  process.env.PREDICT_SERVER ?? "https://predict-server.testnet.mystenlabs.com";
const PRICE_SCALE = 1_000_000_000n;
const DUSDC_SCALE = 1_000_000n;

const fmtUsd = (
  raw: number | string | bigint | null | undefined,
  scale = DUSDC_SCALE,
): string => {
  if (raw === null || raw === undefined) return "—";
  const n = Number(BigInt(raw as any)) / Number(scale);
  return n.toLocaleString(undefined, { maximumFractionDigits: 4 });
};

const fmtStrike = (raw: number | string | bigint): string =>
  Number(BigInt(raw)) / Number(PRICE_SCALE) >= 1
    ? `$${(Number(BigInt(raw)) / Number(PRICE_SCALE)).toLocaleString()}`
    : `$${Number(BigInt(raw)) / Number(PRICE_SCALE)}`;

const fmtTime = (ms: number | string): string =>
  new Date(Number(ms)).toISOString();

const get = async (path: string): Promise<any> => {
  const res = await fetch(`${SERVER}${path}`);
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${res.statusText}`);
  return res.json();
};

(async () => {
  const managerId = process.env.MANAGER_ID ?? CONFIG.MANAGER_ID;
  console.log(`Server:  ${SERVER}`);
  console.log(`Manager: ${managerId}\n`);

  // 1. Headline numbers
  const summary = await get(`/managers/${managerId}/summary`);
  console.log("=== Summary ===");
  console.log(`Owner:                  ${summary.owner}`);
  for (const b of summary.balances ?? []) {
    console.log(
      `Balance:                $${fmtUsd(b.balance)} (${b.quote_asset.split("::").pop()})`,
    );
  }
  console.log(`Trading balance:        $${fmtUsd(summary.trading_balance)}`);
  console.log(`Open exposure:          $${fmtUsd(summary.open_exposure)}`);
  console.log(`Account value:          $${fmtUsd(summary.account_value)}`);
  console.log(`Realized P&L:           $${fmtUsd(summary.realized_pnl)}`);
  console.log(`Unrealized P&L:         $${fmtUsd(summary.unrealized_pnl)}`);
  console.log(`Open positions:         ${summary.open_positions}`);
  console.log(
    `Awaiting settlement:    ${summary.awaiting_settlement_positions}`,
  );

  // 2. Directional positions
  const positions: any[] = await get(
    `/managers/${managerId}/positions/summary`,
  );
  const open = positions.filter((p) => Number(p.open_quantity) > 0);

  console.log(`\n=== Open directional positions (${open.length}) ===`);
  for (const p of open) {
    const dir = p.is_up ? "UP  " : "DOWN";
    const expiry = fmtTime(p.expiry);
    const strike = fmtStrike(p.strike);
    const qty = fmtUsd(p.open_quantity);
    const entry = (
      Number(BigInt(p.average_entry_price)) / Number(PRICE_SCALE)
    ).toFixed(4);
    const mark = p.mark_price
      ? (Number(BigInt(p.mark_price)) / Number(PRICE_SCALE)).toFixed(4)
      : "—";
    const upnl = fmtUsd(p.unrealized_pnl);
    console.log(
      `  ${dir} ${strike} @ ${p.underlying_asset} exp ${expiry}\n` +
        `       qty=$${qty}  entry=${entry}  mark=${mark}  uPnL=$${upnl}\n` +
        `       oracle=${p.oracle_id}`,
    );
  }
  if (open.length === 0) console.log("  (none)");

  // 3. Ranges: reconstruct net open quantity from mint/redeem events
  type RangeEvent = {
    oracle_id: string;
    underlying_asset?: string;
    expiry: number | string;
    lower_strike: number | string;
    higher_strike: number | string;
    quantity: number | string;
  };
  const mints: RangeEvent[] = await get(
    `/ranges/minted?manager_id=${managerId}`,
  ).catch(() => []);
  const redeems: RangeEvent[] = await get(
    `/ranges/redeemed?manager_id=${managerId}`,
  ).catch(() => []);

  const netRanges = new Map<string, { row: RangeEvent; qty: bigint }>();
  const keyOf = (e: RangeEvent) =>
    `${e.oracle_id}|${e.expiry}|${e.lower_strike}|${e.higher_strike}`;

  for (const m of mints) {
    const k = keyOf(m);
    const cur = netRanges.get(k);
    const delta = BigInt(m.quantity);
    if (cur) cur.qty += delta;
    else netRanges.set(k, { row: m, qty: delta });
  }
  for (const r of redeems) {
    const k = keyOf(r);
    const cur = netRanges.get(k);
    if (cur) cur.qty -= BigInt(r.quantity);
  }
  const openRanges = [...netRanges.values()].filter((r) => r.qty > 0n);

  console.log(`\n=== Open vertical ranges (${openRanges.length}) ===`);
  for (const { row, qty } of openRanges) {
    console.log(
      `  (${fmtStrike(row.lower_strike)}, ${fmtStrike(row.higher_strike)}]  ${row.underlying_asset ?? "?"} exp ${fmtTime(row.expiry)}\n` +
        `       qty=$${fmtUsd(qty)}  oracle=${row.oracle_id}`,
    );
  }
  if (openRanges.length === 0) console.log("  (none)");

  console.log(
    `\nFor full P&L history: ${SERVER}/managers/${managerId}/pnl?range=ALL`,
  );
  console.log(`Predict: ${predictObjectID.testnet}`);
})();
