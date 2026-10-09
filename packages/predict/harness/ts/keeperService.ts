// Predict lifecycle keeper. On an oracle-ready localnet WITH the updater streaming, run a
// tick loop that SETTLES expired markets (own PTBs), FLUSHES the active pool (own PTB),
// settles markets, flushes LP requests, and rolls the cadence. The "conditional cron" is off-chain: each tick reconciles
// the active market set from CHAIN (plp::active_expiry_markets) and assembles the due PTBs.
// Queued orders are filled by the traders that place them (commit and resolve are
// permissionless). The keeper creates each market's queue, funds the orders' cash need, and
// drives settlement to completion: Predict's try_settle, then the queue's settle_step until its
// refund and payout phases finish, then cleanup and the sweep.
//
// Reconciling from chain (not an in-memory list) is what makes the keeper crash/restart
// safe: a lost create response or a restart can never desync the flush set from
// finish_flush's all-active-valued assertion. Live valuation reads the updater-maintained
// fresh on-chain feed (one stream); settlement is a SEPARATE PTB run before the flush (the
// keeper fetches each expiry's EXACT spot from the Pyth Lazer history endpoint), so a BS
// live-pricing outage defers only the flush, never settlement. Each tick step is isolated so
// one transient sub-step abort can't skip the rest of the tick.
import { readFileSync } from "node:fs";

import { CADENCES } from "./predictConfig.js";
import { nextDeployableExpiry } from "./cadenceSchedule.js";
import { atomicWriteFile } from "./io.js";
import { fetchExactSpot1e9 } from "./marketSource.js";
import { type Feeds, bootstrapPool, createMarket, ensureMarketQueue, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import { type KeeperChain, type SettleResult, settleAndFlush, settleFailed } from "./keeperLanes.js";
import { definedEnv, requiredEnv, requiredNonnegativeInt } from "./runnerConfig.js";
import { aggregateNetGasOf, appendTrace, errorTag, legComputationsOf, maxComputationOf } from "./trace.js";
import {
  CLEANUP_BATCH,
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  cleanupQueueTx,
  clockTimestampMs,
  execute,
  executeAndWait,
  fundAddressUsdcTx,
  keeperFlushTxs,
  keeperTrySettleTx,
  objectExists,
  readActiveMarketIds,
  readCreatedMarkets,
  readOpenRecordIds,
  payOpenTx,
  readMarketExpiry,
  readSettlementProgress,
  readValuationInProgress,
  deriveMarketQueueId,
  rebalanceExpiryCashTx,
  settleStepTx,
} from "../../devtools/ts/runtime.js";

// Prod testnet cadence set: 1m / 5m / 1h (deployment.testnet.json @ predict-testnet-6-24). The
// keeper enables and rolls all three; each windowSize is a count of periods in
// the future deployment horizon, not a target number of live markets.
const CADENCE_IDS = Object.keys(CADENCES)
  .map(Number)
  .sort((a, b) => a - b);
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = requiredNonnegativeInt("DURATION_MS"); // 0 = until killed
const MARKETS_PATH = `${requiredEnv("INSTANCE_DIR")}/markets.json`;
const WORKLIST_PATH = `${requiredEnv("INSTANCE_DIR")}/keeper-worklist.json`;
const TRADER_ADDRESSES = definedEnv("TRADER_ADDRESSES").split(",").filter(Boolean);
const TRADER_USDC = BigInt(requiredEnv("TRADER_USDC"));

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
// Markets whose queue is known to exist. A market picked up from chain after a restart is
// checked, and its queue created, before it is funded and advertised.
const queued = new Set<string>();
// The durable settlement work list: every market with a queue whose settlement (payout walk,
// cleanup, and sweep) has not finished, kept on disk and rebuilt from events at start. The active
// set alone is not enough, because anyone can sweep a settled market out of it first.
const worklist = new Map<string, number>();

function persistWorklist(): void {
  atomicWriteFile(WORKLIST_PATH, JSON.stringify([...worklist].map(([id, expiryMs]) => ({ id, expiryMs }))));
}

function listMarket(id: string, expiryMs: number): void {
  if (worklist.get(id) === expiryMs) return;
  worklist.set(id, expiryMs);
  persistWorklist();
}

// Restore the list after a restart: the file, then every created market whose queue exists and
// whose payout walk has not completed, which covers a market swept while the keeper was down.
async function rebuildWorklist(): Promise<void> {
  try {
    for (const m of JSON.parse(readFileSync(WORKLIST_PATH, "utf8")) as Mkt[]) worklist.set(m.id, m.expiryMs);
  } catch {
    // First start, or a torn file: the events below rebuild it.
  }
  for (const m of await readCreatedMarkets()) {
    if (worklist.has(m.id) || !(await objectExists(deriveMarketQueueId(m.id)))) continue;
    if (!(await readSettlementProgress(m.id)).payoutsCompleted) worklist.set(m.id, Number(m.expiryMs));
  }
  persistWorklist();
}

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

// The chain the settlement and flush lanes run against (keeperLanes.ts owns their ordering).
// Settlement needs only the exact Pyth spot, NOT live BS pricing, so a BS outage that defers the
// flush can never back settlement up (no beyond-retention brick). Each expiry's spot is fetched
// once from the Pyth history endpoint and reused across that market's phases.
function keeperChain(feeds: Feeds, poolValuationCapId: string): KeeperChain {
  const prices = new Map<string, bigint>();
  return {
    clockMs: async () => Number(await clockTimestampMs()),
    activeMarkets: async () => {
      const markets: Mkt[] = [];
      for (const id of await readActiveMarketIds()) markets.push({ id, expiryMs: await expiryOf(id) });
      return markets;
    },
    pendingMarkets: async () => [...worklist].map(([id, expiryMs]) => ({ id, expiryMs })),
    retire: async (marketId) => {
      if (worklist.delete(marketId)) persistWorklist();
    },
    settlementProgress: readSettlementProgress,
    trySettle: async (m) => {
      let price = prices.get(m.id);
      if (price === undefined) {
        price = await fetchExactSpot1e9(m.expiryMs);
        prices.set(m.id, price);
      }
      const r = await executeAndWait(
        keeperTrySettleTx({
          pythFeedId: feeds.pythFeedId, bsValueStoreId: feeds.bsValueStoreId, expiryMs: BigInt(m.expiryMs), price,
          marketId: m.id, protocolConfigId: PROTOCOL_CONFIG_ID,
        }),
        "settle",
      );
      return r.events;
    },
    settleStep: (m) => executeAndWait(settleStepTx({ marketId: m.id, protocolConfigId: PROTOCOL_CONFIG_ID }), "settle-step"),
    openRecords: (m, nextId) => readOpenRecordIds(m.id, nextId),
    payOpen: (m, recordId) =>
      executeAndWait(payOpenTx({ marketId: m.id, protocolConfigId: PROTOCOL_CONFIG_ID, recordId }), "pay-open"),
    cleanup: async (m, nextId) => {
      for (let first = 0n; first < nextId; first += BigInt(CLEANUP_BATCH)) {
        const recordIds: bigint[] = [];
        for (let id = first; id < nextId && id < first + BigInt(CLEANUP_BATCH); id++) recordIds.push(id);
        await executeAndWait(cleanupQueueTx({ marketId: m.id, recordIds }), "queue-cleanup");
      }
    },
    sweep: (m) =>
      executeAndWait(
        rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: m.id }),
        "settle-sweep",
      ),
    flush: (marketIds) =>
      execute(
        keeperFlushTxs({ feeds, marketIds, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, poolValuationCapId }),
        "flush",
      ),
  };
}

// Trace each settlement result; a settled market is swept, so forget its cached state.
function traceSettlements(results: SettleResult[], straggler: boolean): string {
  let lastErr = "";
  for (const result of results) {
    const m = result.market;
    if (settleFailed(result)) {
      lastErr = errorTag(result.error);
      appendTrace("keeper", { type: "fail", lane: "settle", tag: lastErr });
      const message = result.error instanceof Error ? result.error.message.slice(0, 100) : result.error;
      console.warn(`[keeper] settle deferred ${m.id.slice(0, 10)}: ${message}`);
    } else {
      expiryCache.delete(m.id); funded.delete(m.id); queued.delete(m.id); // swept off-chain; forget
      appendTrace("keeper", {
        type: "settle", market: m.id, expiryMs: m.expiryMs, phases: result.phases,
        ...(straggler ? { straggler: true } : {}),
      });
    }
  }
  return lastErr;
}

async function tick(feeds: Feeds, lifecycleCapId: string, poolValuationCapId: string) {
  // 0. Surface a stranded valuation lock. A valuation that died after its snapshot
  //    sealed leaves the outer lock (`valuation_in_progress`) engaged, but that lock
  //    now only gates cancels and config setters — not settlement, trading, or the
  //    flush lane. There is no separate discard step: the next flush's
  //    `start_pool_valuation` discards the stranded valuation and starts fresh (stop is
  //    folded into start), and the snapshot PTB is atomic so a pre-seal failure reverts
  //    the lock cleanly. So there is nothing to recover here — trace it and let the
  //    flush lane below supersede it.
  if (await readValuationInProgress()) {
    console.warn("[keeper] valuation lock engaged at tick start — the next flush supersedes it");
    appendTrace("keeper", { type: "valuation-stranded", lane: "recovery" });
  }

  // Reconcile the active set from CHAIN — never an in-memory list. Used by settle / rebalance /
  // roll below; settlement (step 1) re-reads a fresh set of its own each pass.
  const active: Mkt[] = [];
  for (const id of await readActiveMarketIds()) active.push({ id, expiryMs: await expiryOf(id) });

  // 1. Settlement, then the pool flush (keeperLanes.settleAndFlush).
  //  a. Durable settlement lane (single pass): settle, pay, and only then sweep every market
  //     past-expiry now. Decoupled from the flush so a BS outage can never back it up (brick fix).
  //     One bad settle fails alone, and a market left unfinished stays active for the next pass.
  //  b. Pool flush, only when something settled and nothing failed: value every active market.
  //     The snapshot sweeps every settled market it snapshots, so it must never meet one whose
  //     payout walk is unfinished: the lane first settles and pays what expired since (a) (the
  //     boundary-race stragglers, traced as such) and flushes only if all of them finished; the
  //     snapshot itself settles nothing. A market that expires between that pass and the
  //     snapshot aborts the snapshot (expired, unsettled) and the flush defers to the next tick,
  //     where (a) settles it. A failure part-way through the staged flush leaves the valuation
  //     lock held until the next flush's `start_pool_valuation` discards it; nothing settled is
  //     lost, because every swept market finished its walk. A flush OOG here is a capacity
  //     BREAKPOINT (analyze.py excludes it), NOT a stall — logged as a plain flush fail.
  const chain = keeperChain(feeds, poolValuationCapId);
  const settlement = await settleAndFlush(chain);
  const s1 = {
    ok: !settlement.settled.some(settleFailed),
    lastErr: traceSettlements(settlement.settled, false),
  };
  const settledOk = s1.ok;
  if (settledOk) consecutiveSettleDefers = 0;
  else if (++consecutiveSettleDefers >= 8) {
    // A real settlement stall (NOT a flush OOG): expired markets are not settling. Report the ACTUAL
    // error tag — this is the brick signal the bug oracle exists to catch.
    appendTrace("keeper", { type: "keeper-stall", consecutiveDefers: consecutiveSettleDefers, lastError: s1.lastErr });
    console.error(`[keeper] *** settlement STALLED ${consecutiveSettleDefers} ticks (lastError=${s1.lastErr}) — expired markets not settling; roll paused ***`);
  }

  const lane = settlement.flush;
  if (lane) {
    traceSettlements(lane.preFlush, true);
    if (lane.skipped) {
      console.warn("[keeper] flush deferred: a market that expired since the settlement lane is unfinished");
    } else if (lane.error !== undefined) {
      appendTrace("keeper", { type: "fail", lane: "flush", tag: errorTag(lane.error) });
      const message = lane.error instanceof Error ? lane.error.message.slice(0, 100) : lane.error;
      console.warn(`[keeper] flush deferred: ${message}`);
    } else {
      const fr = lane.flushed as Awaited<ReturnType<typeof execute>>;
      const fe = fr.events?.find((e: any) => e.type?.includes("FlushExecuted"))?.parsedJson;
      appendTrace("keeper", {
        type: "flush", marketCount: fe ? Number(fe.market_count) : lane.marketIds.length, stragglers: lane.preFlush.length,
        poolValue: fe ? Number(fe.pool_value) / 1e6 : 0, totalSupply: fe ? Number(fe.total_supply) : 0,
        activeNav: fe ? Number(fe.active_market_nav) / 1e6 : 0,
        // compGas is the heaviest SINGLE transaction (the largest value_expiry leg) — the number the
        // per-tx computation cap applies to. compGasTotal is the aggregate across the staged flush's
        // legs, and legCompGas is each leg in order (snapshot, value_expiry per market, finish), so a
        // capacity run measures one transaction against the cap and can see which leg carries it.
        gas: aggregateNetGasOf(fr), compGas: maxComputationOf(fr),
        compGasTotal: Number(fr.gas?.computationCost ?? 0), legCompGas: legComputationsOf(fr),
      });
      console.log(`[keeper] flushed ${lane.marketIds.length} active market(s)`);
    }
  }

  // Re-filter against a FRESH clock so a market that expired during step 1 is not passed to
  // `load_live_pricer` (pricing:9) by the funding or roll lanes below.
  const liveClock = Number(await clockTimestampMs());
  const live = active.filter((m) => m.expiryMs > liveClock);

  // 2. Fund: rebalance every live market each tick. The live target covers the queued orders'
  //    cash need, so this is what funds their fills, and it also retries a roll whose rebalance
  //    failed or a market picked up from chain after a restart. A market is funded, and so
  //    advertised, only once its queue exists. Isolated per market.
  for (const m of live) {
    try {
      if (!queued.has(m.id)) {
        await ensureMarketQueue(m.id);
        queued.add(m.id);
        listMarket(m.id, m.expiryMs);
      }
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
        queued.add(marketId); // createMarket creates the queue with the market
        listMarket(marketId, Number(expiryMs));
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

  // Publish only the FUNDED live markets for the trade generator (never advertise unfunded).
  atomicWriteFile(MARKETS_PATH, JSON.stringify(live.filter((m) => funded.has(m.id)).map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

async function main() {
  console.log(`[keeper] cadences=${CADENCE_IDS.join(",")} windows=${CADENCE_IDS.map((c) => CADENCES[c].windowSize).join(",")} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
  // Traders run the cleanout strategy's permissionless settled redeems, which need the allowlist.
  const { feeds, lifecycleCapId, poolValuationCapId } = await setupFeedsAndConfig(CADENCE_IDS, TRADER_ADDRESSES);
  await bootstrapPool(poolValuationCapId);
  await rebuildWorklist();
  for (const addr of TRADER_ADDRESSES) {
    await executeAndWait(fundAddressUsdcTx(addr, TRADER_USDC), `fund-trader-${addr.slice(0, 8)}`);
  }
  console.log(`[keeper] bootstrapped (PLP minted, feeds.json published); funded ${TRADER_ADDRESSES.length} trader(s); rolling markets...`);

  const startedAt = Date.now();
  const deadline = DURATION_MS > 0 ? startedAt + DURATION_MS : 0;
  for (;;) {
    try {
      await tick(feeds, lifecycleCapId, poolValuationCapId);
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
