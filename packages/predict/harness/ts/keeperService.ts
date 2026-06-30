// Predict lifecycle keeper. On an oracle-ready localnet WITH the updater streaming, run
// a tick loop that rolls the cadence, flushes + settles + compacts expired markets,
// rebalances, and liquidates. The "conditional cron" is off-chain: each tick reads state
// (an in-memory market list + the on-chain clock) and assembles the due PTBs.
//
// The keeper is the sole market creator (tracks its own markets) and the single setup
// owner (setupFeedsAndConfig publishes feeds.json). It does NO provider/WS work: live
// valuation reads the updater-maintained fresh on-chain feed, and the settlement price
// comes from the updater's shared snapshot.json. One stream, the updater's.
import { readFileSync, writeFileSync } from "node:fs";

import { CADENCES } from "./predictConfig.js";
import { type Feeds, bootstrapPool, createMarket, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import { appendTrace, errorTag, gasOf } from "./trace.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clockTimestampMs,
  executeAndWait,
  fundAddressDusdcTx,
  keeperFlushTx,
  keeperLiquidateTx,
  rebalanceExpiryCashTx,
} from "./runtime.js";

const CADENCE = Number(process.env.KEEPER_CADENCE ?? 0); // default 1m (fast roll)
const WINDOW = Number(CADENCES[CADENCE].windowSize); // markets to keep ahead of now
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = until killed
const SNAPSHOT_PATH = `${process.env.INSTANCE_DIR}/snapshot.json`;
const MARKETS_PATH = `${process.env.INSTANCE_DIR}/markets.json`;
const TRADER_ADDRESSES = (process.env.TRADER_ADDRESSES ?? "").split(",").filter(Boolean);
const TRADER_DUSDC = 1_000_000_000_000n; // $1M DUSDC per trader (publisher owns the cap)
const LIQ_BUDGET = 24n; // trade_liquidation_budget

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Market {
  id: string;
  expiryMs: number;
  settled: boolean;
}

// The settlement price for a market: its EXACT at-expiry Pyth print (snapshot.recent at
// the expiry boundary), or the latest spot as a flagged fallback if that print is missing
// (updater gap). Exact is the norm — the fixed-rate stream lands a print at every boundary.
function settlementPrice(expiryMs: number): { price: bigint; exact: boolean } | null {
  try {
    const snap = JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"));
    const exact = snap.recent?.[String(expiryMs)];
    if (exact != null) return { price: BigInt(exact), exact: true };
    if (snap.spot1e9 != null) return { price: BigInt(snap.spot1e9), exact: false };
    return null;
  } catch {
    return null;
  }
}

async function tick(feeds: Feeds, lifecycleCapId: string, markets: Market[]) {
  const clock = Number(await clockTimestampMs());
  const active = markets.filter((m) => !m.settled);
  const expired = active.filter((m) => m.expiryMs <= clock);
  const live = active.filter((m) => m.expiryMs > clock);

  // 1. Flush + settle (when a market has expired): insert each terminal obs so the flush
  //    settles + sweeps it (cash back to pool); live markets are valued on the updater
  //    feed. One flush values EVERY active market.
  if (expired.length) {
    const settlements: { expiryMs: bigint; price: bigint }[] = [];
    for (const m of expired) {
      const sp = settlementPrice(m.expiryMs);
      if (!sp) break; // no snapshot yet (early startup) — defer the whole flush one tick
      if (!sp.exact) console.warn(`[keeper] WARN settling ${isoSec(m.expiryMs)} with FALLBACK latest spot (no exact-expiry print)`);
      settlements.push({ expiryMs: BigInt(m.expiryMs), price: sp.price });
    }
    if (settlements.length === expired.length) {
      const fr = await executeAndWait(
        keeperFlushTx({ feeds, marketIds: active.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "flush+settle",
      );
      expired.forEach((m) => (m.settled = true));
      const fe = fr.events?.find((e: any) => e.type?.includes("FlushExecuted"))?.parsedJson;
      appendTrace("keeper", {
        type: "flush", settled: expired.length, marketCount: fe ? Number(fe.market_count) : 0,
        poolValue: fe ? Number(fe.pool_value) / 1e6 : 0, totalSupply: fe ? Number(fe.total_supply) : 0,
        activeNav: fe ? Number(fe.active_market_nav) / 1e6 : 0, gas: gasOf(fr),
      });
      console.log(`[keeper] settled+compacted ${expired.length} market(s): ${expired.map((m) => isoSec(m.expiryMs)).join(", ")}`);
    }
  }

  // 2. Liquidate live markets (bounded; a no-op without under-floor leveraged orders).
  if (live.length) {
    const lr = await executeAndWait(
      keeperLiquidateTx({ feeds, markets: live.map((m) => m.id), protocolConfigId: PROTOCOL_CONFIG_ID, budget: LIQ_BUDGET }),
      "liquidate",
    );
    appendTrace("keeper", { type: "liquidate", markets: live.length, gas: gasOf(lr) });
  }

  // 3. Roll: keep WINDOW markets ahead of now, funding each as a separate tx right after
  //    creation (a just-created shared object can't be a later input in the SAME PTB).
  const liveCount = markets.filter((m) => !m.settled && m.expiryMs > clock).length;
  if (liveCount < WINDOW) {
    const { marketId, expiryMs } = await createMarket(lifecycleCapId, CADENCE);
    markets.push({ id: marketId, expiryMs: Number(expiryMs), settled: false });
    await executeAndWait(
      rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId, pythFeedId: feeds.pythFeedId }),
      "rebalance",
    );
    console.log(`[keeper] rolled: market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))} (live ${liveCount + 1}/${WINDOW})`);
  }

  // Publish the current live markets for the trade generator.
  writeFileSync(MARKETS_PATH, JSON.stringify(markets.filter((m) => !m.settled && m.expiryMs > clock).map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

async function main() {
  console.log(`[keeper] cadence=${CADENCE} window=${WINDOW} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig([CADENCE]);
  await bootstrapPool(lifecycleCapId);
  for (const addr of TRADER_ADDRESSES) {
    await executeAndWait(fundAddressDusdcTx(addr, TRADER_DUSDC), `fund-trader-${addr.slice(0, 8)}`);
  }
  console.log(`[keeper] bootstrapped (PLP minted, feeds.json published); funded ${TRADER_ADDRESSES.length} trader(s); rolling markets...`);

  const markets: Market[] = [];
  const deadline = DURATION_MS > 0 ? Date.now() + DURATION_MS : 0;
  for (;;) {
    try {
      await tick(feeds, lifecycleCapId, markets);
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.error("[keeper] tick error:", e instanceof Error ? e.message : e);
    }
    if (deadline && Date.now() >= deadline) break;
    await sleep(TICK_MS);
  }
  const settled = markets.filter((m) => m.settled).length;
  console.log(`[keeper] done — ${markets.length} markets created, ${settled} settled+compacted`);
}

main().then(() => process.exit(0)).catch((e) => { console.error("[keeper] FAIL:", e); process.exit(1); });
