// Strategy: nav-stress-atm — the WORST-CASE per-order-cost variant of nav-stress. nav-stress rode the
// cheap normal_cdf branch (~1,086 u/order); a safe per-market cap must instead assume the EXPENSIVE
// branch (|d2| in the SMALL..MEDIUM exp_series range, ~3,644 u/order -> OOG at ~1,372 per #cap-flush24).
// KEY: the expensive branch is at MODERATE moneyness, NOT at-the-money — at d2~0 normal_cdf takes the
// CHEAP <SMALL Horner branch (a smoke at prob~0.5 measured ~cheap-branch cost). So this pins strikes at
// moderate moneyness (prob ~0.65-0.85 -> moderate |d2|). `analyze` reads the same flush-computation-vs-
// book breakpoint (per-instance), which — if we're on the expensive branch — falls well below ~4,580.
// (Verify via the gas-by-moneyness buckets in a full run; nudge the band if the per-order cost isn't up.)
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

const navStressAtm: Strategy = {
  name: "nav-stress-atm",
  tickMs: 1000, // per-market EMaxActiveLeveragedOrders cap; the expensive-branch breakpoint is captured below it
  maxOps: 5000,
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    ctx.pruneSettled();
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: "UP",
      leverage: 1.1, // low -> far above floor -> never liquidated (book stays == held count)
      // MODERATE moneyness (prob ~0.65-0.85 -> |d2| in the SMALL..MEDIUM range) -> the EXPENSIVE
      // normal_cdf exp_series branch (~3,644 u/order, the worst-case per-order NAV cost, #cap-flush24).
      // NOT tight ATM: at d2~0 normal_cdf takes the CHEAP <SMALL Horner branch. spendUsd jitter keeps
      // quantities distinct.
      targetProbability: ctx.rand(0.65, 0.85),
      spendUsd: ctx.rand(5, 10),
    };
    const op = await ctx.mint(market, inst);
    if (op) ctx.trace({ type: "book", size: ctx.held.length, market: market.id });
    return op;
  },
};
export default navStressAtm;
