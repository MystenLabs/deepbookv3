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
import { CADENCES, FAR_MARKET_MIN_HORIZON_MS } from "./predictConfig.js";
import { nextDeployableExpiry } from "./cadenceSchedule.js";
import { GRID_BUCKETS, gridBoundaries } from "./inventoryGrid.js";
import { atomicWriteFile } from "./io.js";
import { fetchExactSpot1e9 } from "./marketSource.js";
import { forwardFor, pricerEnvFor, readSnapshot } from "./oracleEnv.js";
import { type Feeds, bootstrapPool, createMarket, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import { definedEnv, flagEnv, requiredEnv, requiredNonnegativeInt } from "./runnerConfig.js";
import { appendTrace, computationOf, errorTag, gasOf } from "./trace.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clockTimestampMs,
  executeAndWait,
  fundAddressDusdcTx,
  initializeInventoryGridTx,
  keeperFlushTx,
  keeperSettleTx,
  readActiveMarketIds,
  readMarketExpiry,
  rebalanceExpiryCashTx,
} from "../../devtools/ts/runtime.js";

// Prod testnet cadence set: 1m / 5m / 1h (deployment.testnet.json @ predict-testnet-6-24). The
// keeper enables and rolls all three; each windowSize is a count of periods in
// the future deployment horizon, not a target number of live markets.
const CADENCE_IDS = Object.keys(CADENCES)
  .map(Number)
  .sort((a, b) => a - b);
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = requiredNonnegativeInt("DURATION_MS"); // 0 = until killed
const INSTANCE_DIR = requiredEnv("INSTANCE_DIR");
const MARKETS_PATH = `${INSTANCE_DIR}/markets.json`;
const TRADER_ADDRESSES = definedEnv("TRADER_ADDRESSES").split(",").filter(Boolean);
const TRADER_DUSDC = BigInt(requiredEnv("TRADER_DUSDC"));
// Cut and re-cut inventory grids. Off by default: the grid is keeper policy, not
// a contract requirement at the zero rate every other strategy runs at, and the
// extra PTB per market per tick would move their measured baselines.
const INVENTORY_GRID = flagEnv("KEEPER_INVENTORY_GRID");

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
// Markets whose inventory grid has been cut. `initialize` only accepts an empty
// book, so a market enters this set on the tick it is rolled and leaves it when
// it settles; everything after that is a `refresh`.
const gridded = new Set<string>();
// Markets that can no longer be cut. `initialize` requires an empty book, so a
// market that took an order before its grid landed is permanently un-griddable
// and retrying it every tick would just burn a transaction per tick forever.
const ungriddable = new Set<string>();

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

// The durable settlement lane: settle every currently-past-expiry active market, each in its own PTB
// (insert exact spot -> try_settle -> rebalance_expiry_cash sweep). Needs only the exact Pyth
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
      expiryCache.delete(m.id); funded.delete(m.id); gridded.delete(m.id); // swept off-chain; forget
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

// Initialize each far market's ratio ladder once (`KEEPER_INVENTORY_GRID=1`).
// Dollar rungs are `ratio × F_live` on every quote, so later ticks do not
// re-cut. A market is initialized on the tick it is rolled, because
// `initialize` only accepts an empty book.
//
// Scoped to markets at least FAR_MARKET_MIN_HORIZON_MS out, which is the same
// set a capacity strategy fills. A near-expiry market cannot be partitioned
// into equal-mass buckets — its quantiles collapse onto the forward, and the
// ones that do not sit on a surface whose roll-down is fast enough that clock
// skew between this process and the on-chain `Clock` fails the mass check.
async function cutGrids(feeds: Feeds, lifecycleCapId: string, live: Mkt[]): Promise<void> {
  const snapshot = readSnapshot(INSTANCE_DIR);
  const horizon = Date.now() + FAR_MARKET_MIN_HORIZON_MS;
  for (const m of live) {
    if (gridded.has(m.id) || ungriddable.has(m.id) || m.expiryMs <= horizon) continue;
    const env = pricerEnvFor(snapshot, m.expiryMs, Date.now());
    if (!env) continue; // cold snapshot for this expiry — retried next tick
    const ratios = gridBoundaries(env.svi, forwardFor(env));
    // Near expiry the quantiles collapse onto the forward and adjacent ratios
    // round to one value, which the contract rejects. Skipping leaves the
    // market un-gridded until a later tick can invert a non-degenerate surface.
    if (!ratios) continue;
    try {
      const result = await executeAndWait(
        initializeInventoryGridTx({
          ...feeds,
          expiryMarketId: m.id,
          protocolConfigId: PROTOCOL_CONFIG_ID,
          lifecycleCapId,
          ratios,
        }),
        "grid-init",
      );
      gridded.add(m.id);
      appendTrace("keeper", {
        type: "gridInit",
        market: m.id,
        expiryMs: m.expiryMs,
        buckets: GRID_BUCKETS,
        gas: gasOf(result),
        compGas: computationOf(result),
      });
    } catch (e) {
      const tag = errorTag(e);
      // A keeper restart re-reads the active set from chain, so a market whose
      // grid was cut by the previous process reports back as un-gridded. The
      // contract's own already-initialized guard is the authority on that.
      if (tag === "strike_exposure:9") gridded.add(m.id);
      // EInventoryGridBookNotEmpty: an order beat the cut, so this market can
      // never be gridded. Give up on it rather than retrying every tick.
      if (tag === "strike_exposure:8") ungriddable.add(m.id);
      appendTrace("keeper", { type: "fail", lane: "grid-init", market: m.id, tag });
      console.warn(`[keeper] grid init deferred ${m.id.slice(0, 10)}: ${e instanceof Error ? e.message.slice(0, 120) : e}`);
    }
  }
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
  //     the flush inserts its exact-expiry observation and calls try_settle before value_expiry,
  //     instead of tripping dynamic_field on a missing obs. These commands are the
  //     race-avoidance ONLY; the durable settlement is 1a (a BS outage reverts the flush's inserts but
  //     can't block 1a, so no brick). A flush OOG here is a capacity BREAKPOINT (analyze.py
  //     excludes it), NOT a stall — logged as a plain flush fail.
  if (didSettle && settledOk) {
    try {
      const nowClock = Number(await clockTimestampMs());
      const flush: Mkt[] = [];
      for (const id of await readActiveMarketIds()) flush.push({ id, expiryMs: await expiryOf(id) });
      const settlements: { marketId: string; expiryMs: bigint; price: bigint }[] = [];
      for (const m of flush) {
        if (m.expiryMs <= nowClock) settlements.push({ marketId: m.id, expiryMs: BigInt(m.expiryMs), price: await fetchExactSpot1e9(m.expiryMs) });
      }
      const fr = await executeAndWait(
        keeperFlushTx({ feeds, marketIds: flush.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "flush",
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

  // Re-filter against a FRESH clock so a market that expired during step 1 is not passed to
  // `load_live_pricer` (pricing:9) by the funding or roll lanes below.
  const liveClock = Number(await clockTimestampMs());
  const live = active.filter((m) => m.expiryMs > liveClock);

  // 2. Fund: rebalance every active market not yet confirmed funded (retries a roll whose
  //    rebalance failed, or a market picked up from chain after a restart). Isolated per market.
  for (const m of live) {
    if (funded.has(m.id)) continue;
    try {
      await executeAndWait(
        rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: m.id }),
        "rebalance",
      );
      funded.add(m.id);
    } catch (e) {
      appendTrace("keeper", { type: "fail", tag: errorTag(e) });
      console.warn(`[keeper] rebalance retry skipped ${m.id.slice(0, 10)}: ${e instanceof Error ? e.message.slice(0, 80) : e}`);
    }
  }

  // 3. Roll: keep each cadence's window of live markets ahead of now. The market is ADVERTISED
  //    (pushed to `live`) only AFTER its rebalance succeeds — so traders never see an unfunded
  //    market. GATED on settledOk: during a settlement outage the flush defers, so minting more
  //    markets would grow the active set past the single-PTB flush gas wall and brick it.
  if (settledOk) {
    for (const c of CADENCE_IDS) {
      const expectedExpiry = nextDeployableExpiry(live, c, liveClock, CADENCE_IDS);
      if (expectedExpiry === null) continue;
      try {
        const { marketId, expiryMs } = await createMarket(lifecycleCapId, c);
        if (Number(expiryMs) !== expectedExpiry) {
          throw new Error(`keeper cadence schedule drift c${c}: expected ${expectedExpiry}, created ${expiryMs}`);
        }
        await executeAndWait(
          rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId }),
          "rebalance",
        );
        funded.add(marketId);
        expiryCache.set(marketId, Number(expiryMs));
        live.push({ id: marketId, expiryMs: Number(expiryMs) });
        console.log(`[keeper] rolled c${c}: market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))}`);
      } catch (e) {
        appendTrace("keeper", { type: "fail", tag: errorTag(e) });
        console.warn(`[keeper] roll c${c} skipped: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
      }
    }
  }

  // 4. Inventory grids, before the markets are advertised: a market rolled this tick must be
  //    gridded while its book is still empty, which is the only state `initialize` accepts.
  if (INVENTORY_GRID) await cutGrids(feeds, lifecycleCapId, live.filter((m) => funded.has(m.id)));

  // Publish only the FUNDED live markets for the trade generator (never advertise unfunded).
  // Under KEEPER_INVENTORY_GRID a market must also be gridded first: one order landing before
  // the cut makes the market permanently un-griddable, which silently costs the run its
  // measurement target. That narrows the advertised set to the far markets the grid lane cuts,
  // which is the set the strategy asking for grids draws from anyway.
  const advertised = live.filter((m) => funded.has(m.id) && (!INVENTORY_GRID || gridded.has(m.id)));
  atomicWriteFile(MARKETS_PATH, JSON.stringify(advertised.map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

async function main() {
  console.log(`[keeper] cadences=${CADENCE_IDS.join(",")} windows=${CADENCE_IDS.map((c) => CADENCES[c].windowSize).join(",")} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms inventoryGrid=${INVENTORY_GRID} inventoryImpactMaxRate=${process.env.INVENTORY_IMPACT_MAX_RATE ?? "0"}`);
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig(CADENCE_IDS);
  await bootstrapPool(lifecycleCapId);
  for (const addr of TRADER_ADDRESSES) {
    await executeAndWait(fundAddressDusdcTx(addr, TRADER_DUSDC), `fund-trader-${addr.slice(0, 8)}`);
  }
  console.log(`[keeper] bootstrapped (PLP minted, feeds.json published); funded ${TRADER_ADDRESSES.length} trader(s); rolling markets...`);

  const startedAt = Date.now();
  const deadline = DURATION_MS > 0 ? startedAt + DURATION_MS : 0;
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
