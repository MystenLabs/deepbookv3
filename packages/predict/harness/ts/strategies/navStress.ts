// Strategy: NAV-stress — find the maximum leverage-book size the on-chain NAV calc can tolerate.
// The NAV calc runs in the keeper FLUSH, which values every active market in ONE PTB; per market it
// walks the leverage structure, so flush gas grows with the leveraged-order count. This strategy
// concentrates a growing book of leveraged orders in ONE persisting market so that market's
// per-expiry NAV walk dominates the flush gas, isolating book-size as the only variable:
//   - low leverage (1.1x) -> each order sits far above its floor -> the keeper never liquidates it;
//   - the farthest-out (1h) expiry, >2h away -> it never settles during the pile;
//   - hold everything (never redeem).
// Nothing leaves the book, so ctx.held.length == the market's leveraged-order count; we trace it
// each tick. `analyze` joins these book sizes with the keeper's flush gas to find the breakpoint —
// the book size at which flush gas hits the tx gas cap and the flush can no longer be valued. Runs
// to the per-market 5000 cap (EMaxActiveLeveragedOrders); the breakpoint is captured wherever it
// falls below that (or, if the flush stays under the cap at 5000, the order cap is the binding limit).
//
// The keeper flush is bumped to the Sui max tx gas budget (keeperService) so the breakpoint reflects
// the PROTOCOL limit, not the 1e9 harness default.
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";

const TWO_HOURS_MS = 2 * 3_600_000;

// Lock the pile onto ONE market that outlasts the whole run: the farthest-out expiry (a 1h boundary
// >2h away). Reuse it via the held orders; before the first mint, wait until such a market exists
// (the keeper needs a few ticks to roll the far 1h markets up).
function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (ctx.held.length > 0) return ctx.markets().find((m) => m.id === ctx.held[0].marketId) ?? null;
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  return farthest.expiryMs > Date.now() + TWO_HOURS_MS ? farthest : null;
}

const navStress: Strategy = {
  name: "nav-stress",
  tickMs: 1000, // one leveraged mint/sec; mint-only (no same-ms redeem) and strikes vary so ids differ
  maxOps: 5000, // the per-market EMaxActiveLeveragedOrders cap; the NAV breakpoint is captured below it
  fund: 20_000_000_000_000n, // $20M — headroom for ~5000 small leveraged mints
  async tick(ctx) {
    // A slow pile (heavy localnet load) can outlast the locked 1h market; prune settled orders so a
    // settled lock re-locks onto a fresh far market instead of stalling — the gas-vs-size curve just
    // accumulates across lock cycles (no-op while the lock is still live).
    ctx.pruneSettled();
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: "UP",
      leverage: 1.1, // low -> far above floor -> never liquidated (book stays == held count)
      targetProbability: ctx.rand(0.45, 0.6), // near-money, varied -> distinct strikes (no same-ms id clash)
      spendUsd: ctx.rand(5, 10), // small -> many orders per fund
    };
    const op = await ctx.mint(market, inst);
    if (op) ctx.trace({ type: "book", size: ctx.held.length, market: market.id });
    return op;
  },
};
export default navStress;
