// Strategy: batch-max-book — the raw single-market ceiling, reached FAST via batched mints. Locks onto
// ONE persisting far-1h market and fills it toward the 5000 EMaxActiveLeveragedOrders cap with one PTB
// per tick (~BATCH varied-leg mints each), then HOLDS at the cap so the keeper flush is measured
// repeatedly at book 5000. With the NAV price-memo the single-market flush should no longer OOG before
// the cap, so the deliverable is the flush computation AT the 5000 ceiling — what fraction of the 5e9
// per-tx cap one full market costs. Each leg is independently resolved (varied strike/quantity), so the
// payout tree fills toward its ~1000-node cap — the near-worst-case linear-walk cost, not one strike
// repeated. REQUIRES SIM_GAS_BUDGET=50000000000 so a batch tx isn't trader-budget-capped (BATCH=40 keeps
// each PTB well under the ~110-mint atomic-batch OOG ceiling). Run duration-only: campaign … --timeout N.
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
const MAX_BOOK = 5000; // EMaxActiveLeveragedOrders (per-market cap)
const BATCH = 40; // mints per PTB — safely under the ~110-mint atomic-batch OOG ceiling
const LVG = 1.1; // low -> far above floor -> never liquidated -> book == cumulative mints

type Leg = { strike1e9: bigint; isUp: boolean; quantity: bigint; leverage1e9: bigint; maxCost: bigint; maxProbability: bigint };

// Batch mints never enter ctx.held, so lock the market and track the book ourselves.
let lockedId: string | null = null;
let book = 0;

function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (lockedId) {
    const m = ctx.markets().find((mk) => mk.id === lockedId);
    if (m) return m;
    lockedId = null; // locked market settled (shouldn't happen for a >2h market) — re-lock, restart the pile
    book = 0;
  }
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  if (farthest.expiryMs <= Date.now() + TWO_HOURS_MS) return null;
  lockedId = farthest.id;
  return farthest;
}

function legFrom(ctx: StrategyCtx, market: Mkt): Leg | null {
  const inst: Instruction = { direction: "UP", leverage: LVG, targetProbability: ctx.rand(0.45, 0.6), spendUsd: ctx.rand(5, 10) };
  const r = ctx.resolve(inst, market); // null when infeasible (e.g. too near expiry) — skip that leg
  if (!r) return null;
  return {
    strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE,
    isUp: true,
    quantity: r.quantity,
    leverage1e9: r.leverage1e9,
    maxCost: r.maxCost,
    maxProbability: r.maxProbability1e9,
  };
}

const batchMaxBook: Strategy = {
  name: "batch-max-book",
  tickMs: 1500, // one PTB/tick; batches are large, give the node a moment
  maxOps: 0, // duration-only: fill fast, then hold at the cap so the flush is measured at book 5000
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const room = MAX_BOOK - book;
    if (room <= 0) return null; // at the ceiling — hold; the keeper keeps flushing at book 5000
    const want = Math.min(BATCH, room);
    const legs: Leg[] = [];
    for (let i = 0; i < want; i++) {
      const l = legFrom(ctx, market);
      if (l) legs.push(l);
    }
    if (legs.length === 0) return null;
    try {
      await ctx.submitMintBatch(market, legs, { book });
      book += legs.length;
      ctx.trace({ type: "book", size: book, market: market.id });
      return "mint";
    } catch (e) {
      // OOG at the computation cap is the atomic-batch ceiling, not a bug. Real aborts (incl. the
      // whitelisted caps EMaxActiveLeveragedOrders / EMaxPayoutTreeNodes) are tagged for the oracle.
      const oog = /InsufficientGas|OUT_OF_GAS|computation/i.test(String(e));
      if (oog) ctx.trace({ type: "mintBatch", n: legs.length, book, oog: true, err: errorTag(e) });
      else ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, book });
      return null;
    }
  },
};
export default batchMaxBook;
