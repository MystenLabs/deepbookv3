// Predict lifecycle keeper. On an oracle-ready localnet WITH the updater streaming, run a
// tick loop that flushes + settles + compacts expired markets, liquidates, and rolls the
// cadence. The "conditional cron" is off-chain: each tick reconciles the active market set
// from CHAIN (plp::active_expiry_markets) and assembles the due PTBs.
//
// Reconciling from chain (not an in-memory list) is what makes the keeper crash/restart
// safe: a lost create response or a restart can never desync the flush set from
// finish_flush's all-active-valued assertion. Live valuation reads the updater-maintained
// fresh on-chain feed (one stream); settlement is independent — the keeper fetches each
// expiry's EXACT spot from the Pyth Lazer history endpoint. Each tick step is isolated so
// one transient sub-step abort can't skip the rest of the tick.
import { CADENCES } from "./predictConfig.js";
import { atomicWriteFile } from "./io.js";
import { fetchExactSpot1e9 } from "./marketSource.js";
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
  readActiveMarketIds,
  readMarketExpiry,
  rebalanceExpiryCashTx,
} from "./runtime.js";

const CADENCE = Number(process.env.KEEPER_CADENCE ?? 0); // default 1m (fast roll)
const WINDOW = Number(CADENCES[CADENCE].windowSize); // markets to keep ahead of now
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = until killed
const MARKETS_PATH = `${process.env.INSTANCE_DIR}/markets.json`;
const TRADER_ADDRESSES = (process.env.TRADER_ADDRESSES ?? "").split(",").filter(Boolean);
const TRADER_DUSDC = BigInt(process.env.TRADER_DUSDC ?? "1000000000000"); // $1M default; campaign overrides per strategy
const LIQ_BUDGET = 24n; // trade_liquidation_budget

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// id -> expiry(ms) cache. The active SET is always chain truth (readActiveMarketIds); this
// only avoids re-reading each market's immutable expiry every tick. Misses (orphans from a
// lost create response, or a restart) are filled from chain via readMarketExpiry.
const expiryCache = new Map<string, number>();
let consecutiveDefers = 0; // flush deferrals in a row — settlement-outage detector
// Markets whose cash rebalance has SUCCEEDED — only these are advertised to traders. Added on a
// successful rebalance, removed when the market settles; any active market not in here is retried
// each tick (a roll whose rebalance failed, or one picked up from chain after a restart).
const funded = new Set<string>();

async function expiryOf(marketId: string): Promise<number> {
  const cached = expiryCache.get(marketId);
  if (cached !== undefined) return cached;
  const e = Number(await readMarketExpiry(marketId));
  expiryCache.set(marketId, e);
  return e;
}

interface Mkt {
  id: string;
  expiryMs: number;
}

async function tick(feeds: Feeds, lifecycleCapId: string) {
  const clock = Number(await clockTimestampMs());
  // Reconcile the active set from CHAIN — never an in-memory list.
  const active: Mkt[] = [];
  for (const id of await readActiveMarketIds()) active.push({ id, expiryMs: await expiryOf(id) });

  // 1. Flush + settle expired markets: fetch each expiry's exact spot (history endpoint),
  //    re-sign + insert it, and value EVERY active market in one flush. Isolated: a
  //    boundary race (a market expiring mid-tick, no obs yet) or a price-not-yet-available
  //    defers the flush one tick rather than killing the tick.
  const expired = active.filter((m) => m.expiryMs <= clock);
  let settledOk = expired.length === 0; // caught up when nothing has expired to settle
  if (expired.length) {
    try {
      const settlements: { expiryMs: bigint; price: bigint }[] = [];
      for (const m of expired) settlements.push({ expiryMs: BigInt(m.expiryMs), price: await fetchExactSpot1e9(m.expiryMs) });
      const fr = await executeAndWait(
        keeperFlushTx({ feeds, marketIds: active.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "flush+settle",
      );
      expired.forEach((m) => { expiryCache.delete(m.id); funded.delete(m.id); }); // compacted off-chain; forget
      settledOk = true;
      consecutiveDefers = 0;
      const fe = fr.events?.find((e: any) => e.type?.includes("FlushExecuted"))?.parsedJson;
      appendTrace("keeper", {
        type: "flush", settled: expired.length, marketCount: fe ? Number(fe.market_count) : 0,
        poolValue: fe ? Number(fe.pool_value) / 1e6 : 0, totalSupply: fe ? Number(fe.total_supply) : 0,
        activeNav: fe ? Number(fe.active_market_nav) / 1e6 : 0, gas: gasOf(fr),
      });
      console.log(`[keeper] settled+compacted ${expired.length} market(s): ${expired.map((m) => isoSec(m.expiryMs)).join(", ")}`);
    } catch (e) {
      consecutiveDefers++;
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.warn(`[keeper] flush deferred (${consecutiveDefers}x): ${e instanceof Error ? e.message.slice(0, 100) : e}`);
      // Sustained outage / beyond-retention miss: settlement can't proceed; surface it loudly.
      if (consecutiveDefers >= 8)
        console.error(`[keeper] *** settlement STALLED ${consecutiveDefers} ticks (Pyth-history outage or beyond-retention miss) — flush blocked; roll paused ***`);
    }
  }

  // 2. Liquidate LIVE markets, re-filtered against a FRESH clock so a market that expired
  //    during step 1 isn't passed to load_live_pricer (pricing:9). Isolated.
  const liveClock = Number(await clockTimestampMs());
  const live = active.filter((m) => m.expiryMs > liveClock);
  if (live.length) {
    try {
      const lr = await executeAndWait(
        keeperLiquidateTx({ feeds, markets: live.map((m) => m.id), protocolConfigId: PROTOCOL_CONFIG_ID, budget: LIQ_BUDGET }),
        "liquidate",
      );
      appendTrace("keeper", { type: "liquidate", markets: live.length, gas: gasOf(lr) });
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.warn(`[keeper] liquidate skipped: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
    }
  }

  // 3. Fund: rebalance every active market not yet confirmed funded (retries a roll whose
  //    rebalance failed, or a market picked up from chain after a restart). Isolated per market.
  for (const m of live) {
    if (funded.has(m.id)) continue;
    try {
      await executeAndWait(
        rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: m.id, pythFeedId: feeds.pythFeedId }),
        "rebalance",
      );
      funded.add(m.id);
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.warn(`[keeper] rebalance retry skipped ${m.id.slice(0, 10)}: ${e instanceof Error ? e.message.slice(0, 80) : e}`);
    }
  }

  // 4. Roll: keep WINDOW live markets ahead of now. The market is ADVERTISED (pushed to `live`)
  //    only AFTER its rebalance succeeds — so traders never see an unfunded market. GATED on
  //    settledOk: during a settlement outage the flush defers, so minting more markets would grow
  //    the active set past the single-PTB flush gas wall and brick it.
  if (settledOk && live.length < WINDOW) {
    try {
      const { marketId, expiryMs } = await createMarket(lifecycleCapId, CADENCE);
      await executeAndWait(
        rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId, pythFeedId: feeds.pythFeedId }),
        "rebalance",
      );
      funded.add(marketId);
      expiryCache.set(marketId, Number(expiryMs));
      live.push({ id: marketId, expiryMs: Number(expiryMs) });
      console.log(`[keeper] rolled: market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))} (live ${live.length}/${WINDOW})`);
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.warn(`[keeper] roll skipped: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
    }
  }

  // Publish only the FUNDED live markets for the trade generator (never advertise unfunded).
  atomicWriteFile(MARKETS_PATH, JSON.stringify(live.filter((m) => funded.has(m.id)).map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

async function main() {
  console.log(`[keeper] cadence=${CADENCE} window=${WINDOW} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig([CADENCE]);
  await bootstrapPool(lifecycleCapId);
  for (const addr of TRADER_ADDRESSES) {
    await executeAndWait(fundAddressDusdcTx(addr, TRADER_DUSDC), `fund-trader-${addr.slice(0, 8)}`);
  }
  console.log(`[keeper] bootstrapped (PLP minted, feeds.json published); funded ${TRADER_ADDRESSES.length} trader(s); rolling markets...`);

  const deadline = DURATION_MS > 0 ? Date.now() + DURATION_MS : 0;
  for (;;) {
    try {
      await tick(feeds, lifecycleCapId);
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.error("[keeper] tick error:", e instanceof Error ? e.message : e);
    }
    if (deadline && Date.now() >= deadline) break;
    await sleep(TICK_MS);
  }
  console.log("[keeper] done");
}

main().then(() => process.exit(0)).catch((e) => {
  appendTrace("keeper", { type: "fail", tag: errorTag(e), fatal: true }); // so a setup crash leaves a trace
  console.error("[keeper] FAIL:", e);
  process.exit(1);
});
