// Strategy: nav-stress-multi — the POOL-TOTAL variant of nav-stress. nav-stress piles into ONE market;
// this spreads the leverage book across EVERY live market so the keeper flush (which values ALL active
// markets in one PTB) is measured against the TOTAL leveraged-order count, not a single market's. It
// confirms the pool-total capacity and that the per-market base is stable x K (#cap-flush24). Same
// low-leverage held pile, but each tick targets a RANDOM live market. `analyze` reuses the nav-stress
// flush-computation-vs-book section per-instance (here `size` is the total live held count).
import { type Instruction } from "../resolver.js";
import { type Strategy } from "../strategy.js";

const navStressMulti: Strategy = {
  name: "nav-stress-multi",
  tickMs: 1000,
  maxOps: 5000,
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    // Prune settled: near-expiry (1m/5m) markets settle mid-run and their held orders drop, so the book
    // accumulates in the persisting (5m/1h) markets — the flush values whatever is live at flush time.
    ctx.pruneSettled();
    const market = ctx.randomExpiry();
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: "UP",
      leverage: 1.1, // low -> never liquidated (book stays == held count)
      targetProbability: ctx.rand(0.45, 0.6),
      spendUsd: ctx.rand(5, 10),
    };
    const op = await ctx.mint(market, inst);
    // Spread the leverage book across every live market -> the flush values ALL of them in one PTB ->
    // measures the POOL-TOTAL capacity, not a single market (#cap-flush24).
    if (op) ctx.trace({ type: "book", size: ctx.held.length, markets: ctx.markets().length, market: market.id });
    return op;
  },
};
export default navStressMulti;
