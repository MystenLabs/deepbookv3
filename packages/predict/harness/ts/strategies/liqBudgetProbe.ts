// Shared core for the two trade-path liquidation-budget probes (DBU-695, Three Sigma #48).
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
// {type:"liqBudget", budget, elapsedMs}; analysis joins probes to rungs on time. Run with e.g.
//   TRADE_LIQ_BUDGET_STAGES=0:24,900:512,1800:1500,2700:3000 SIM_GAS_BUDGET=50000000000
//
// BATCHING IS ADAPTIVE, AND THAT IS THE POINT. Every `mint_exact_quantity` in a PTB runs its own
// ambient pass, so an N-mint batch pays N sweeps: at budget 3,000 even a 2-mint batch is over the
// cap. The batch therefore starts at 40 (fast fill while the budget is low) and halves on each
// OOG until it reaches 1. A 1-leg batch is byte-identical to an ordinary mint, so every
// submission at batch==1 IS the measurement — no separate probe path to keep honest.
//
// READING THE RESULT. The declared wall is the per-tx computation cap (`InsufficientGas`).
// `analyze` fails a run VACUOUS when a declared wall is never reached — here that is a real
// result, not a harness failure: it means the ladder's top rung was affordable at the book the
// run built. If the object-runtime cached-objects limit (1,000 children/tx) binds first on the
// adverse arm instead, it surfaces as an UNdeclared VM error and gets flagged; that is
// deliberate — which wall binds is the open question, so neither is pre-declared as expected.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
const MAX_BOOK = 5000; // EMaxActiveLeveragedOrders — the per-market index cap
const START_BATCH = 40; // safely under the ~110-mint atomic-batch OOG ceiling at budget 24

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
  // Batch mints never enter ctx.held, so lock the market and count our own mints. `minted` is
  // mints ISSUED, which equals the active book only on the healthy arm (leverage low enough that
  // nothing is ever knocked out). On the adverse arm liquidations leave the index, so
  // minted >= book and the active count must come from the liquidation events, not from here.
  let lockedId: string | null = null;
  let minted = 0;
  let batch = START_BATCH;
  let wallHits = 0; // consecutive single-mint OOGs; reset by any success

  function targetMarket(ctx: StrategyCtx): Mkt | null {
    if (lockedId) {
      const m = ctx.markets().find((mk) => mk.id === lockedId);
      if (m) return m;
      lockedId = null; // locked market settled (shouldn't happen for a >2h market) — re-lock
      minted = 0;
    }
    const live = ctx.markets();
    if (!live.length) return null;
    const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
    if (farthest.expiryMs <= Date.now() + TWO_HOURS_MS) return null;
    lockedId = farthest.id;
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
    maxOps: 0, // duration-only: fill, then hold and keep probing as the budget ladder steps up
    fund: arm.fund,
    ...(arm.expect ? { expect: arm.expect } : {}),
    async tick(ctx) {
      const market = targetMarket(ctx);
      if (!market || !ctx.snapshot()) return null;
      if (batch === 1 && wallHits >= WALL_CONFIRMATIONS) return null; // wall measured — hold
      const want = Math.min(batch, MAX_BOOK - minted);
      if (want <= 0) return null; // at the index cap — hold; the ladder keeps re-probing
      const legs: MintLeg[] = [];
      for (let i = 0; i < want; i++) {
        const l = legFrom(ctx, market);
        if (l) legs.push(l);
      }
      if (legs.length === 0) return null;
      try {
        // submitMintBatch traces {type:"mintBatch", n, gas, compGas, …meta}; at n==1 that IS an
        // ordinary mint's cost, which is the number the ceiling is set from.
        await ctx.submitMintBatch(market, legs, { minted, batch });
        minted += legs.length;
        wallHits = 0;
        ctx.trace({ type: "book", size: minted, market: market.id });
        return "mint";
      } catch (e) {
        if (isOog(e)) {
          // The cap: halve and retry smaller. At batch==1 there is nothing left to halve — that
          // IS the wall, so confirm it a few times and then hold.
          ctx.trace({ type: "mintBatch", n: legs.length, minted, batch, oog: true, err: errorTag(e) });
          if (batch === 1) wallHits += 1;
          batch = Math.max(1, Math.floor(batch / 2));
        } else {
          ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, minted, batch });
        }
        return null;
      }
    },
  };
}
