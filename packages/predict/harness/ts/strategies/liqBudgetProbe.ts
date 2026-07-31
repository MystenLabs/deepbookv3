// Shared core for the two trade-path liquidation-budget probes (DBU-695).
//
// WHAT IS BEING MEASURED. `trade_liquidation_budget` bounds the ambient liquidation pass that
// runs before every mint and every live redeem. It ships at 24 and is admin-raisable to a
// compile-time max of 3,000 that no measurement stands behind. The pass costs
// min(budget, active_leveraged_orders) candidates, each priced with an un-memoized
// `range_price`, so the deliverable is per-mint `compGas` as a joint function of the configured
// budget and the book — and the budget at which an ordinary mint stops fitting in one tx.
//
// HOW ONE RUN SWEEPS IT. The cost is min(budget, book), so a book built cheaply at budget 24 can
// be re-probed at every higher rung without rebuilding it. The keeper walks
// TRADE_LIQ_BUDGET_STAGES ("<elapsedSeconds>:<budget>,…") and traces each rung as
// {type:"liqBudget", budget, requestedAtMs, elapsedMs}; analysis joins probes to rungs on time and
// discards the request-to-landed window, where the in-force budget is indeterminate. Run e.g.
//   TRADE_LIQ_BUDGET_STAGES=0:24,900:512,1800:1500,2700:3000 SIM_GAS_BUDGET=50000000000
//
// FILL, THEN PROBE ONE AT A TIME. Every `mint_exact_quantity` in a PTB runs its own ambient pass,
// so an N-mint batch pays N sweeps and only n==1 transactions measure the trade path. Batching
// exists solely to reach a deep book fast: up to FILL_TARGET the probe batches (halving on any
// OOG), and past it every mint goes out alone for the rest of the run. A 1-leg batch is
// byte-identical to an ordinary mint, so each of those submissions IS the measurement — there is
// no separate probe path that could drift from what a real trader pays.
//
// READING THE RESULT. Only the adverse arm declares the per-tx computation cap
// (`InsufficientGas`) as its terminal wall, because only it is expected to reach one; `analyze`
// fails a run VACUOUS when a DECLARED wall goes unreached, so declaring it on the healthy arm
// would turn every clean run red. An undeclared arm that OOGs a single mint raises
// `liq-budget-wall-undeclared` instead — that is a finding, not the measurement. If the
// object-runtime cached-objects limit (1,000 children/tx) binds before the computation cap on the
// adverse arm, it surfaces as an UNdeclared VM error and gets flagged; which wall binds first is
// the open question, so neither is pre-declared as the expected one.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
const MAX_BOOK = 5000; // EMaxActiveLeveragedOrders — the per-market index cap
const START_BATCH = 40; // safely under the ~110-mint atomic-batch OOG ceiling at budget 24
// Book size at which the fill stops batching and every mint becomes a single-mint probe. Batching
// exists only to reach a deep book quickly; past this the run's job is to emit n==1 samples, and it
// must keep emitting them for the WHOLE ladder. MAX_BOOK - FILL_TARGET = 3,000 single mints, ~75
// minutes at tickMs 1500, which outlasts the documented ladder — so every rung gets probed.
//
// Getting this wrong is silent: batching to the index cap saturates the book in ~3 minutes, long
// before the first rung steps, after which there is nothing left to mint and the run collects
// nothing while still reporting a clean verdict.
const FILL_TARGET = 2000;

// After this many consecutive single-mint OOGs the wall is measured and the strategy holds. Without
// it the probe submits a failing ~cap-sized tx every tick forever: the trader's gas coin drains (an
// OOG still executes and charges), and the trace fills with duplicate wall records. Higher rungs
// only cost more, so there is nothing left to learn once a 1-leg mint cannot fit.
const WALL_CONFIRMATIONS = 3;

export interface LiqBudgetArm {
  name: string;
  fund: bigint;
  // The arm's leverage profile — the ONLY difference between the healthy and adverse probes.
  instruction(ctx: StrategyCtx): Instruction;
  // Declared terminal wall, when reaching it is this arm's PURPOSE. Omit when it is not: `analyze`
  // fails a run VACUOUS if a declared wall goes unreached, and whitelists it when it is hit — so
  // declaring a wall an arm is not expected to reach turns every clean run red AND suppresses the
  // surprise if it ever does happen.
  expect?: { terminal: string[]; note?: string };
}

export function makeLiqBudgetStrategy(arm: LiqBudgetArm): Strategy {
  // Batch mints never enter ctx.held, so lock the market and track the index ourselves. The book is
  // mints issued MINUS orders the ambient pass knocked out, counted from each tx's OrderLiquidated
  // events — on the adverse arm those removals are continuous, so issued-mints alone overstates the
  // index, and overstating it understates the per-candidate slope and overstates the ceiling the
  // whole run exists to set. On the healthy arm nothing knocks out and `liquidated` stays 0.
  let lockedId: string | null = null;
  let minted = 0;
  let liquidated = 0;
  let batch = START_BATCH;
  let wallHits = 0; // consecutive single-mint OOGs; reset by any success

  const book = () => minted - liquidated;

  function targetMarket(ctx: StrategyCtx): Mkt | null {
    const live = ctx.markets();
    if (lockedId) {
      const m = live.find((mk) => mk.id === lockedId);
      if (m) return m;
      // The locked market is missing from this tick's view. That is NOT proof it settled:
      // `markets()` reads markets.json, which comes back empty on a torn read and drops markets
      // whose keeper-side `funded` set was cleared by a restart. Resetting the book counter on that
      // alone would leave `book` under-reporting the real index for the rest of the run — silently,
      // and in the direction that corrupts the measurement. So hold state and wait; only a genuine
      // re-lock onto a DIFFERENT market resets, below.
      if (!live.length) return null;
    }
    if (!live.length) return null;
    const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
    if (farthest.expiryMs <= Date.now() + TWO_HOURS_MS) return null;
    if (farthest.id !== lockedId) {
      // A different market: the old book is gone with it, so every piece of book-derived state
      // resets together. Carrying `batch`/`wallHits` over would strand the strategy — a run that
      // reached the wall holds at batch==1 with wallHits past its limit and never mints again.
      lockedId = farthest.id;
      minted = 0;
      liquidated = 0;
      batch = START_BATCH;
      wallHits = 0;
    }
    return farthest;
  }

  function legFrom(ctx: StrategyCtx, market: Mkt): MintLeg | null {
    const inst = arm.instruction(ctx);
    const r = ctx.resolve(inst, market); // null when infeasible (e.g. too near expiry) — skip the leg
    if (!r) return null;
    return {
      strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE,
      isUp: inst.direction === "UP",
      quantity: r.quantity,
      leverage1e9: r.leverage1e9,
      maxCost: r.maxCost,
      maxProbability: r.maxProbability1e9,
    };
  }

  return {
    name: arm.name,
    tickMs: 1500,
    maxOps: 0, // duration-only: fill to FILL_TARGET, then probe one mint at a time for the rest
    fund: arm.fund,
    ...(arm.expect ? { expect: arm.expect } : {}),
    async tick(ctx) {
      const market = targetMarket(ctx);
      if (!market || !ctx.snapshot()) return null;
      if (batch === 1 && wallHits >= WALL_CONFIRMATIONS) return null; // wall measured — hold
      // Past FILL_TARGET every mint goes out alone, whether or not anything has OOG'd. Halving on
      // OOG alone is not enough: batching only shrinks when it stops fitting, so a run would sit at
      // n=5 or n=2 for most of the ladder and emit n==1 samples — the only ones the fit uses — at
      // the very top rung, if ever.
      if (book() >= FILL_TARGET) batch = 1;
      const want = Math.min(batch, MAX_BOOK - book());
      if (want <= 0) return null; // index cap with nothing knocked out — no room left to probe
      const legs: MintLeg[] = [];
      for (let i = 0; i < want; i++) {
        const l = legFrom(ctx, market);
        if (l) legs.push(l);
      }
      if (legs.length === 0) return null;
      try {
        // submitMintBatch traces {type:"mintBatch", n, gas, compGas, …meta}; at n==1 that IS an
        // ordinary mint's cost, which is the number the ceiling is set from. `book` is the index
        // size the ambient pass saw — BEFORE this tx's own mints and knockouts.
        const res = await ctx.submitMintBatch(market, legs, { book: book(), minted, batch });
        // The ambient pass in this very tx may have knocked orders out of the index. `knocked` also
        // goes onto the record (via the follow-up trace) because a liquidating candidate costs more
        // than a scanned one — index removal plus payout-tree boundary removal — so without it the
        // fitted comp/candidate is a blend of the two whose mix is invisible after the fact.
        const knocked = ((res?.events ?? []) as any[]).filter((e) => e.type?.includes("OrderLiquidated")).length;
        minted += legs.length;
        liquidated += knocked;
        wallHits = 0;
        ctx.trace({ type: "book", size: book(), minted, liquidated, knocked, n: legs.length, market: market.id });
        return "mint";
      } catch (e) {
        if (isOog(e)) {
          // The cap: halve and retry smaller. At batch==1 there is nothing left to halve — that
          // IS the wall, so confirm it a few times and then hold.
          ctx.trace({ type: "mintBatch", n: legs.length, book: book(), minted, batch, oog: true, err: errorTag(e) });
          if (batch === 1) wallHits += 1;
          batch = Math.max(1, Math.floor(batch / 2));
        } else {
          ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, book: book(), minted, batch });
        }
        return null;
      }
    },
  };
}
