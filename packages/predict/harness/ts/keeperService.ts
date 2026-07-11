// Predict lifecycle keeper. On an oracle-ready localnet WITH the updater streaming, run a
// tick loop that SETTLES expired markets (own PTBs), FLUSHES the active pool (own PTB),
// liquidates, and rolls the cadence. The "conditional cron" is off-chain: each tick reconciles
// the active market set from CHAIN (plp::active_expiry_markets) and assembles the due PTBs.
//
// Reconciling from chain (not an in-memory list) is what makes the keeper crash/restart
// safe: a lost create response or a restart can never desync the flush set from
// finish_flush's all-active-valued assertion. Live valuation reads the updater-maintained
// fresh on-chain feed (one stream); settlement is a SEPARATE PTB run before the flush (the
// keeper fetches each expiry's EXACT spot from the Pyth Lazer history endpoint), so a BS
// live-pricing outage defers only the flush, never settlement. Each tick step is isolated so
// one transient sub-step abort can't skip the rest of the tick.
import { CADENCES } from "./predictConfig.js";
import { atomicWriteFile } from "./io.js";
import { fetchExactSpot1e9 } from "./marketSource.js";
import { type Feeds, bootstrapPool, createMarket, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import { appendTrace, computationOf, errorTag, gasOf } from "./trace.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clockTimestampMs,
  executeAndWait,
  fundAddressDusdcTx,
  keeperFlushTx,
  keeperLiquidateTx,
  keeperSettleTx,
  readActiveMarketIds,
  readMarketExpiry,
  rebalanceExpiryCashTx,
} from "./runtime.js";

// Prod testnet cadence set: 1m / 5m / 1h (deployment.testnet.json @ predict-testnet-6-24). The
// keeper enables and rolls all three; each keeps its own CADENCES[c].windowSize markets ahead.
const CADENCE_IDS = [0, 1, 2];
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = until killed
const MARKETS_PATH = `${process.env.INSTANCE_DIR}/markets.json`;
const TRADER_ADDRESSES = (process.env.TRADER_ADDRESSES ?? "").split(",").filter(Boolean);
const TRADER_DUSDC = BigInt(process.env.TRADER_DUSDC ?? "1000000000000"); // $1M default; campaign overrides per strategy
const LIQ_BUDGET = 24n; // trade_liquidation_budget
// Flush gas budget. The SINGLE dense market (nav-stress) OOGs at the per-tx COMPUTATION cap
// (5e9 MIST), not the budget; the pool total binds earlier on the object-runtime cached-objects
// limit (C-1) at ~16-50% of that cap. Either way the budget only needs headroom above the 5e9 cap.
// Set to 15e9 (3x): still lets the single-market flush reach the 5e9 wall, but far below the old
// 50e9 — because
// signExecThreaded pins ONE gas coin per sender and Sui requires that coin >= the budget, a 50e9
// floor starved the keeper's shrinking pinned coin (batch run 2026-07-06: 219 gas-starved flushes).
// 15e9 ~triples the coin's runway. Mitigation, not a full fix — a long enough run still drains the
// pinned coin; the real fix is topping it up (deferred).
const FLUSH_GAS_BUDGET = 15_000_000_000n;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// id -> expiry(ms) cache. The active SET is always chain truth (readActiveMarketIds); this
// only avoids re-reading each market's immutable expiry every tick. Misses (orphans from a
// lost create response, or a restart) are filled from chain via readMarketExpiry.
const expiryCache = new Map<string, number>();
let consecutiveSettleDefers = 0; // ticks in a row with an unsettled expired market — the brick signal
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

// Recover a market's cadence from its expiry. Cadence isn't stored on-chain, but the contract's
// rank partition (1h owns :00:00, 5m owns 5-min marks off-the-hour, 1m owns the rest) makes this
// exact for the enabled {1m,5m,1h} set — so it holds for chain-reconciled + post-restart markets.
function cadenceOf(expiryMs: number): number {
  if (expiryMs % 3_600_000 === 0) return 2; // 1h
  if (expiryMs % 300_000 === 0) return 1; // 5m
  return 0; // 1m
}

// The durable settlement lane: settle every currently-past-expiry active market, each in its own PTB
// (insert exact spot + rebalance_expiry_cash -> ensure_settled -> sweep). Needs only the exact Pyth
// spot, NOT live BS pricing, so a BS outage that defers the flush can never back settlement up (no
// beyond-retention brick). Reads a fresh clock + chain active set. Returns ok / last error / count.
async function settleExpired(feeds: Feeds): Promise<{ ok: boolean; lastErr: string; count: number }> {
  const clock = Number(await clockTimestampMs());
  const expired: Mkt[] = [];
  for (const id of await readActiveMarketIds()) {
    const e = await expiryOf(id);
    if (e <= clock) expired.push({ id, expiryMs: e });
  }
  let ok = true;
  let lastErr = "";
  for (const m of expired) {
    try {
      const price = await fetchExactSpot1e9(m.expiryMs);
      await executeAndWait(
        keeperSettleTx({ pythFeedId: feeds.pythFeedId, expiryMs: BigInt(m.expiryMs), price, marketId: m.id, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID }),
        "settle",
      );
      expiryCache.delete(m.id); funded.delete(m.id); // swept off-chain; forget
      appendTrace("keeper", { type: "settle", market: m.id, expiryMs: m.expiryMs });
    } catch (e) {
      ok = false;
      lastErr = errorTag(e);
      appendTrace("keeper", { type: "fail", lane: "settle", tag: lastErr });
      console.warn(`[keeper] settle deferred ${m.id.slice(0, 10)}: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
    }
  }
  return { ok, lastErr, count: expired.length };
}

async function tick(feeds: Feeds, lifecycleCapId: string) {
  // Reconcile the active set from CHAIN — never an in-memory list. Used by liquidate / rebalance /
  // roll below; settlement (step 1) re-reads a fresh set of its own each pass.
  const active: Mkt[] = [];
  for (const id of await readActiveMarketIds()) active.push({ id, expiryMs: await expiryOf(id) });

  // 1a. Durable settlement lane (single pass): settle + sweep every market past-expiry now. Decoupled
  //     from the flush so a BS outage can never back it up (brick fix). One bad settle fails alone.
  const s1 = await settleExpired(feeds);
  const settledOk = s1.ok;
  const didSettle = s1.count > 0;
  if (settledOk) consecutiveSettleDefers = 0;
  else if (++consecutiveSettleDefers >= 8) {
    // A real settlement stall (NOT a flush OOG): expired markets are not settling. Report the ACTUAL
    // error tag — this is the brick signal the bug oracle exists to catch.
    appendTrace("keeper", { type: "keeper-stall", consecutiveDefers: consecutiveSettleDefers, lastError: s1.lastErr });
    console.error(`[keeper] *** settlement STALLED ${consecutiveSettleDefers} ticks (lastError=${s1.lastErr}) — expired markets not settling; roll paused ***`);
  }

  // 1b. Pool flush (own PTB): value every active market. The 1a lane swept the markets past-expiry when
  //     it ran; a market that expired SINCE (a boundary-race straggler) is still active + unsettled, so
  //     the flush inserts its exact-expiry observation inline — value_expiry then settles it via
  //     ensure_settled instead of tripping dynamic_field on a missing obs. These inserts are the
  //     race-avoidance ONLY; the durable settlement is 1a (a BS outage reverts the flush's inserts but
  //     can't block 1a, so no brick). A flush OOG here is the nav-stress BREAKPOINT (analyze.py
  //     excludes it), NOT a stall — logged as a plain flush fail.
  if (didSettle && settledOk) {
    try {
      const nowClock = Number(await clockTimestampMs());
      const flush: Mkt[] = [];
      for (const id of await readActiveMarketIds()) flush.push({ id, expiryMs: await expiryOf(id) });
      const settlements: { expiryMs: bigint; price: bigint }[] = [];
      for (const m of flush) {
        if (m.expiryMs <= nowClock) settlements.push({ expiryMs: BigInt(m.expiryMs), price: await fetchExactSpot1e9(m.expiryMs) });
      }
      const fr = await executeAndWait(
        keeperFlushTx({ feeds, marketIds: flush.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "flush",
        FLUSH_GAS_BUDGET,
      );
      const fe = fr.events?.find((e: any) => e.type?.includes("FlushExecuted"))?.parsedJson;
      appendTrace("keeper", {
        type: "flush", marketCount: fe ? Number(fe.market_count) : flush.length, stragglers: settlements.length,
        poolValue: fe ? Number(fe.pool_value) / 1e6 : 0, totalSupply: fe ? Number(fe.total_supply) : 0,
        activeNav: fe ? Number(fe.active_market_nav) / 1e6 : 0, gas: gasOf(fr), compGas: computationOf(fr),
      });
      console.log(`[keeper] flushed ${flush.length} active market(s)`);
    } catch (e) {
      appendTrace("keeper", { type: "fail", lane: "flush", tag: errorTag(e) });
      console.warn(`[keeper] flush deferred: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
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

  // 4. Roll: keep each cadence's window of live markets ahead of now. The market is ADVERTISED
  //    (pushed to `live`) only AFTER its rebalance succeeds — so traders never see an unfunded
  //    market. GATED on settledOk: during a settlement outage the flush defers, so minting more
  //    markets would grow the active set past the single-PTB flush gas wall and brick it.
  if (settledOk) {
    for (const c of CADENCE_IDS) {
      const windowC = Number(CADENCES[c].windowSize);
      if (live.filter((m) => cadenceOf(m.expiryMs) === c).length >= windowC) continue;
      try {
        const { marketId, expiryMs } = await createMarket(lifecycleCapId, c);
        await executeAndWait(
          rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId, pythFeedId: feeds.pythFeedId }),
          "rebalance",
        );
        funded.add(marketId);
        expiryCache.set(marketId, Number(expiryMs));
        live.push({ id: marketId, expiryMs: Number(expiryMs) });
        console.log(`[keeper] rolled c${c}: market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))}`);
      } catch (e) {
        // ECadenceWindowExceeded (market_manager:5) = window full (skip-edge / post-restart): expected.
        appendTrace("keeper", { type: "fail", tag: errorTag(e) });
        console.warn(`[keeper] roll c${c} skipped: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
      }
    }
  }

  // Publish only the FUNDED live markets for the trade generator (never advertise unfunded).
  atomicWriteFile(MARKETS_PATH, JSON.stringify(live.filter((m) => funded.has(m.id)).map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

async function main() {
  console.log(`[keeper] cadences=${CADENCE_IDS.join(",")} windows=${CADENCE_IDS.map((c) => CADENCES[c].windowSize).join(",")} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig(CADENCE_IDS);
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
