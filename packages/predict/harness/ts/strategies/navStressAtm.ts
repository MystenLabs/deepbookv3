// Strategy: nav-stress-atm — the WORST-CASE moneyness variant of nav-stress. nav-stress rode the cheap
// normal_cdf branch (~1,086 u/order, prob 0.45-0.6); a safe per-market cap must instead assume the
// EXPENSIVE branch (near-ATM, |d2| in the SMALL..MEDIUM exp_series range, ~3,644 u/order -> OOG at
// ~1,372 per #cap-flush24). Identical pile to nav-stress but strikes pinned tight around at-the-money so
// the flush's correction_value -> range_price -> normal_cdf takes the expensive path. `analyze` reads
// the same flush-computation-vs-book breakpoint (per-instance), which should fall well below ~4,580.
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
  tickMs: 1000,
  maxOps: 5000, // per-market EMaxActiveLeveragedOrders cap; the expensive-branch breakpoint is captured below it
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    ctx.pruneSettled();
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: "UP",
      leverage: 1.1, // low -> far above floor -> never liquidated (book stays == held count)
      // near-ATM (prob ~0.5) -> the expensive normal_cdf/exp_series d2 branch -> worst-case per-order NAV
      // cost (#cap-flush24). spendUsd jitter keeps quantities distinct.
      targetProbability: ctx.rand(0.48, 0.52),
      spendUsd: ctx.rand(5, 10),
    };
    const op = await ctx.mint(market, inst);
    if (op) ctx.trace({ type: "book", size: ctx.held.length, market: market.id });
    return op;
  },
};
export default navStressAtm;
