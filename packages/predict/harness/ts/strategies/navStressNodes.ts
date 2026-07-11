// Strategy: nav-stress-nodes — the PAYOUT-TREE variant of nav-stress (the C-1 node-count term).
// nav-stress and nav-stress-atm concentrate strikes in a narrow band (few distinct boundaries — prior
// runs reached only ~83), so the 1,000-node payout-tree cap has never been benchmarked. This piles the
// same never-liquidated 1.1x book into ONE persisting market but sweeps targetProbability across nearly
// the full admissible range (0.05–0.95), spreading strikes across the $1 admission grid so the tree's
// distinct-boundary count grows toward the node cap ALONGSIDE the leveraged-order count — the joint
// worst case per market (max nodes x max leveraged orders). `analyze` reads the same flush-computation-
// vs-book breakpoint; the traced `strikes` (distinct strike count ~= boundary count) lets the findings
// separate the node-count gas term from the per-order term.
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";

const TWO_HOURS_MS = 2 * 3_600_000;

// Lock the pile onto ONE market that outlasts the run: the farthest-out 1h boundary (>2h away).
function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (ctx.held.length > 0) return ctx.markets().find((m) => m.id === ctx.held[0].marketId) ?? null;
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  return farthest.expiryMs > Date.now() + TWO_HOURS_MS ? farthest : null;
}

// Distinct admission-grid strikes minted so far (~= payout-tree boundary count for an all-UP book).
const strikes = new Set<number>();

const navStressNodes: Strategy = {
  name: "nav-stress-nodes",
  tickMs: 1000, // one leveraged mint/sec; mint-only, strikes vary
  maxOps: 5000, // per-market EMaxActiveLeveragedOrders cap; node/gas breakpoints are captured below it
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    ctx.pruneSettled();
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: "UP",
      leverage: 1.1, // low -> far above floor -> never liquidated (book stays == held count)
      // Near-full admissible band -> strikes spread across the $1 admission grid -> maximal distinct
      // payout-tree boundaries (vs nav-stress's narrow 0.45-0.6 band that reused ~83 strikes).
      targetProbability: ctx.rand(0.05, 0.95),
      spendUsd: ctx.rand(5, 10),
    };
    const r = ctx.resolve(inst, market); // resolve first to record the strike the mint will use
    if (!r) return null;
    const op = await ctx.mint(market, inst);
    if (op) {
      strikes.add(Math.round(r.strikeUsd));
      ctx.trace({ type: "book", size: ctx.held.length, strikes: strikes.size, market: market.id });
    }
    return op;
  },
};
export default navStressNodes;
