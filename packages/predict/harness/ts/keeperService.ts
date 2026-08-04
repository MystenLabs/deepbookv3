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
import { nextDeployableExpiry } from "./cadenceSchedule.js";
import { atomicWriteFile } from "./io.js";
import { fetchExactSpot1e9 } from "./marketSource.js";
import { type Feeds, bootstrapPool, createMarket, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import { bigintEnv, budgetLadder, definedEnv, requiredEnv, requiredNonnegativeInt } from "./runnerConfig.js";
import { appendTrace, computationOf, errorTag, gasOf } from "./trace.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clockTimestampMs,
  executeAndWait,
  fundAddressDusdcTx,
  keeperFlushTxs,
  execute,
  abortValuationTx,
  keeperLiquidateTx,
  keeperSettleTx,
  readActiveMarketIds,
  readValuationInProgress,
  readMarketExpiry,
  rebalanceExpiryCashTx,
  setTradeLiquidationBudgetTx,
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
const TRADER_ADDRESSES = definedEnv("TRADER_ADDRESSES").split(",").filter(Boolean);
const TRADER_DUSDC = BigInt(requiredEnv("TRADER_DUSDC"));
// Budget the KEEPER spends on its own permissionless `liquidate()` lane. Distinct from the on-chain
// `trade_liquidation_budget` the TRADE path spends, which the ladder below drives. Parsed through
// `bigintEnv` so a typo names the variable rather than throwing a bare SyntaxError at module load —
// which would kill the keeper before it wrote any trace, surfacing as `no-keeper-trace`. Set 0
// deliberately for the liq-budget adverse probe, which needs liquidatable orders to survive long
// enough for a mint's ambient pass to meet them.
const LIQ_BUDGET = bigintEnv("KEEPER_LIQ_BUDGET", 24n);
// Ladder for the on-chain ambient-pass budget, measured from keeper start. Unset (the default)
// never touches the config, so every existing run keeps the contract default.
const TRADE_LIQ_BUDGET_STAGES = budgetLadder(process.env.TRADE_LIQ_BUDGET_STAGES || "");
let nextBudgetStage = 0;
let budgetStageFailures = 0;
// A rung that cannot be applied is retried, but not forever: an out-of-range value aborts every
// tick, and `protocol_config` is a GUARD module, so the repeated failures classify as expected
// preconditions and the run would exit 0 having swept nothing. Give up after a few attempts rather
// than mirror the contract's bounds here (they are the contract's to own).
const MAX_BUDGET_STAGE_FAILURES = 3;

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
  // 0. Clear a stranded valuation lock BEFORE anything else. The lock outlives its
  //    transaction now, so a flush that died part-way blocks settlement, liquidation and
  //    every LP lane — including the flush lane's own recovery, which would otherwise
  //    never run again because it sits behind `settledOk`. Recovering here instead keeps
  //    the tick steps individually isolated, which is the harness invariant.
  try {
    if (await readValuationInProgress()) {
      console.warn("[keeper] valuation lock engaged at tick start — discarding the stranded flush");
      await executeAndWait(
        abortValuationTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "abort-stranded-valuation",
      );
      appendTrace("keeper", { type: "valuation-aborted", lane: "recovery" });
    }
  } catch (e) {
    // Leave it engaged and retry next tick rather than proceeding into lanes that will
    // all abort; surface the real tag so the bug oracle can see a repeating failure.
    appendTrace("keeper", { type: "fail", lane: "lock-recovery", tag: errorTag(e) });
    console.error(`[keeper] *** could not clear the valuation lock: ${errorTag(e)} — protocol stays frozen ***`);
    return;
  }

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
      // The flush is a sequence now: settle+snapshot (atomic), one value_expiry per
      // market, then finish. A failure part-way leaves the valuation lock held, so the
      // catch below discards it rather than letting the whole protocol sit frozen.
      const fr = await execute(
        keeperFlushTxs({ feeds, marketIds: flush.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
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
      // A flush that fails after the snapshot transaction committed leaves the valuation
      // lock engaged, which freezes mint, redeem, liquidation, settlement and every LP
      // request until it is discarded. The single-PTB flush could not reach that state.
      // Discard on the same lifecycle authority that started it rather than waiting out
      // `max_valuation_window_ms`; a failure here is logged and the next tick retries.
      try {
        await executeAndWait(
          abortValuationTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
          "abort-valuation",
        );
        appendTrace("keeper", { type: "valuation-aborted" });
        console.warn("[keeper] discarded the in-flight valuation, lock released");
      } catch (abortErr) {
        // `EValuationNotInProgress` is the benign case: the flush failed before
        // `start_pool_valuation` committed, so there is nothing to discard. Anything else
        // left the lock engaged — step 0 of the next tick retries it, so this is logged
        // rather than swallowed.
        const tag = errorTag(abortErr);
        appendTrace("keeper", { type: "abort-noop", tag });
        if (!tag.includes("EValuationNotInProgress")) {
          console.warn(`[keeper] abort after failed flush did not land (${tag}); next tick retries`);
        }
      }
    }
  }

  // 2. Liquidate LIVE markets, re-filtered against a FRESH clock so a market that expired
  //    during step 1 isn't passed to load_live_pricer (pricing:9). Isolated.
  const liveClock = Number(await clockTimestampMs());
  const live = active.filter((m) => m.expiryMs > liveClock);
  if (live.length && LIQ_BUDGET > 0n) {
    try {
      const lr = await executeAndWait(
        keeperLiquidateTx({ feeds, markets: live.map((m) => m.id), protocolConfigId: PROTOCOL_CONFIG_ID, budget: LIQ_BUDGET }),
        "liquidate",
      );
      // `budget` is traced so the analysis can tell whether this lane was competing with a
      // liq-budget probe: the probe nets only its OWN transactions' knockouts, so a keeper sweeping
      // alongside it leaves the probe's book over-counted — and that overstates the ceiling.
      appendTrace("keeper", { type: "liquidate", markets: live.length, gas: gasOf(lr), budget: Number(LIQ_BUDGET) });
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
        rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: m.id }),
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

  // Publish only the FUNDED live markets for the trade generator (never advertise unfunded).
  atomicWriteFile(MARKETS_PATH, JSON.stringify(live.filter((m) => funded.has(m.id)).map((m) => ({ id: m.id, expiryMs: m.expiryMs }))));
}

// Apply every due rung of the trade-liquidation-budget ladder. Isolated like the other lanes: a
// failed set defers to the next tick, and the stage is consumed only on success so the sweep cannot
// skip a rung it never applied.
//
// This runs BEFORE tick() inside the same try, so it must never throw: doing so would skip
// settlement, flush, rebalance and roll on every subsequent iteration — one bad rung bricking every
// other keeper lane, against the per-step isolation invariant. On give-up it abandons the ladder
// and marks the trace fatal, which fails the run in `analyze` while leaving the other lanes alone.
//
// The ladder is in-memory, so a keeper restart replays it from the first rung and walks the budget
// back DOWN before climbing again. That costs run time, not correctness: every rung is traced, and
// the analysis joins each probe to the rung in force at its own timestamp.
async function applyBudgetStages(startedAt: number) {
  const elapsed = Date.now() - startedAt;
  while (nextBudgetStage < TRADE_LIQ_BUDGET_STAGES.length && TRADE_LIQ_BUDGET_STAGES[nextBudgetStage].atMs <= elapsed) {
    const { budget } = TRADE_LIQ_BUDGET_STAGES[nextBudgetStage];
    // Stamped BEFORE the tx. A probe between the request and the trace record ran under an unknown
    // budget — the set may already have landed — so the analysis discards that window rather than
    // attribute it to either rung; crediting it to the older, lower rung understates the slope and
    // overstates the ceiling, which is the unsafe direction.
    const requestedAtMs = Date.now();
    try {
      await executeAndWait(setTradeLiquidationBudgetTx(PROTOCOL_CONFIG_ID, budget), "trade-liq-budget");
      appendTrace("keeper", { type: "liqBudget", budget: Number(budget), elapsedMs: elapsed, requestedAtMs });
      console.log(`[keeper] trade_liquidation_budget -> ${budget} (t+${Math.round(elapsed / 1000)}s)`);
      nextBudgetStage++;
      budgetStageFailures = 0;
    } catch (e) {
      appendTrace("keeper", { type: "fail", lane: "liqBudget", tag: errorTag(e) });
      budgetStageFailures++;
      if (budgetStageFailures >= MAX_BUDGET_STAGE_FAILURES) {
        nextBudgetStage = TRADE_LIQ_BUDGET_STAGES.length;
        appendTrace("keeper", {
          type: "fail", lane: "liqBudget", fatal: true,
          tag: `budget-ladder-abandoned:rung=${budget}:${errorTag(e)}`,
        });
        console.error(
          `[keeper] TRADE_LIQ_BUDGET_STAGES: rung ${budget} failed ${budgetStageFailures}x — abandoning the ladder; ` +
            `the sweep will collect nothing further (last: ${e instanceof Error ? e.message.slice(0, 160) : e})`,
        );
        return;
      }
      console.warn(`[keeper] trade_liquidation_budget deferred: ${e instanceof Error ? e.message.slice(0, 100) : e}`);
      return; // retry this rung next tick; do not run ahead to a later one
    }
  }
}

async function main() {
  console.log(`[keeper] cadences=${CADENCE_IDS.join(",")} windows=${CADENCE_IDS.map((c) => CADENCES[c].windowSize).join(",")} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
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
      await applyBudgetStages(startedAt);
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
