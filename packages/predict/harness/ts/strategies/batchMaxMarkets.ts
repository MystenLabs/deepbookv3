// Strategy: batch-max-markets — pool-total flush stress across the FULL live market set via batched mints.
// Round-robins over every live market, filling each with one PTB per turn (~BATCH varied-leg mints), so the
// keeper's ONE hot-potato flush PTB (a value_expiry command per active market + finish_flush) is measured
// against growing market-count AND total leveraged orders — capturing the per-command PTB-accumulation tax
// (a later value_expiry command costs more than an earlier one, #cap-mintbatch), which makes the pool-total
// flush exceed the sum of standalone per-market costs and shifts the joint-budget cap boundaries (24/1000/5000).
// The NAV memo bounds EACH market's linear walk at the 1000-node cap, so the pool total (~9 live markets ×
// up-to-1000 ticks each) is where the flush can still climb toward the 5e9 cap — the number the cap needs.
// 1m/5m markets settle before accumulating much (best-effort; ctx.resolve pre-skips too-near markets); the
// persisting 5m/1h markets carry the book. Each leg is independently resolved (varied). Market count tops out
// at the enabled cadence grid (~9), not the contract's 24 — the full-24 boundary needs a wider grid (harness
// change). REQUIRES SIM_GAS_BUDGET=50000000000. Run duration-only: campaign … --timeout N.
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const MAX_BOOK = 5000; // per-market EMaxActiveLeveragedOrders
const BATCH = 40; // mints per PTB — safely under the ~110-mint atomic-batch OOG ceiling
const LVG = 1.1; // low -> far above floor -> never liquidated -> per-market book == cumulative mints

type Leg = { strike1e9: bigint; isUp: boolean; quantity: bigint; leverage1e9: bigint; maxCost: bigint; maxProbability: bigint };

// Batch mints never enter ctx.held, so track per-market book ourselves; a round-robin cursor spreads the fill.
const perMarket = new Map<string, number>();
let rr = 0;

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

const batchMaxMarkets: Strategy = {
  name: "batch-max-markets",
  tickMs: 1500,
  maxOps: 0, // duration-only: keep filling live markets for the whole run
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    const live = ctx.markets();
    if (!live.length || !ctx.snapshot()) return null;
    // Reconcile the counter against the live set: a settled market's orders leave the flush, so drop it
    // from the pool total (mirrors pruneSettled for batch-minted orders that never entered ctx.held).
    const liveIds = new Set(live.map((m) => m.id));
    for (const id of [...perMarket.keys()]) if (!liveIds.has(id)) perMarket.delete(id);

    // Round-robin over live markets so all fill in parallel (best-effort; near markets churn out).
    const market = live[rr % live.length];
    rr++;
    const have = perMarket.get(market.id) ?? 0;
    const room = MAX_BOOK - have;
    if (room <= 0) return null;
    const want = Math.min(BATCH, room);
    const legs: Leg[] = [];
    for (let i = 0; i < want; i++) {
      const l = legFrom(ctx, market);
      if (l) legs.push(l);
    }
    if (legs.length === 0) return null;
    try {
      await ctx.submitMintBatch(market, legs, { market: market.id });
      perMarket.set(market.id, have + legs.length);
      const total = [...perMarket.values()].reduce((a, b) => a + b, 0);
      ctx.trace({ type: "book", size: total, markets: live.length, market: market.id, perMarket: have + legs.length });
      return "mint";
    } catch (e) {
      const oog = /InsufficientGas|OUT_OF_GAS|computation/i.test(String(e));
      if (oog) ctx.trace({ type: "mintBatch", n: legs.length, market: market.id, oog: true, err: errorTag(e) });
      else ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, market: market.id });
      return null;
    }
  },
};
export default batchMaxMarkets;
