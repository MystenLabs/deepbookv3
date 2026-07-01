// Strategy 2: mixed churn — leveraged mints, partial + full redeems, random expiries, plus
// LP supply/withdraw. Exercises the broad trade + LP surface. One op per tick (≥1s apart) so
// open+close never land in the same Clock ms.
import { type Instruction } from "../resolver.js";
import { type Strategy } from "../strategy.js";

const SUPPLY_CHUNK = 50_000_000_000n; // $50k per supply
const LOT = 10_000n;

const mixedChurn: Strategy = {
  name: "mixed-churn",
  tickMs: 2000,
  maxOps: 3000,
  fund: 10_000_000_000_000n, // $10M (churn + LP supply)
  async tick(ctx) {
    ctx.pruneSettled();
    if (!ctx.markets().length || !ctx.snapshot()) return null;
    const roll = Math.random();

    // 15% LP supply.
    if (roll < 0.15) return ctx.supply(SUPPLY_CHUNK);
    // 10% LP withdraw — only what we actually hold (read first so we never over-draw).
    if (roll < 0.25) {
      await ctx.refreshPlp();
      const w = ctx.plpShares / 4n;
      return w >= 1_000_000n ? ctx.withdraw(w) : null; // 1_000_000n = constants::min_withdraw_request (1e6)
    }
    // 35% redeem a held order — half partial (lot-aligned), half full.
    if (ctx.held.length && roll < 0.6) {
      const h = ctx.pick(ctx.held);
      let close = h.quantity;
      if (Math.random() < 0.5 && h.quantity > LOT * 2n) {
        const half = (h.quantity / 2n / LOT) * LOT;
        if (half >= LOT) close = half;
      }
      return ctx.redeem(h, close);
    }
    // else: a leveraged mint into a random expiry.
    const market = ctx.randomExpiry();
    if (!market) return null;
    const p = ctx.rand(0.1, 0.9);
    const inst: Instruction = {
      direction: ctx.pick(["UP", "DN"]) as "UP" | "DN",
      leverage: ctx.rand(1, ctx.leverageCap(p)),
      targetProbability: p,
      spendUsd: ctx.rand(20, 200),
    };
    return ctx.mint(market, inst);
  },
};
export default mixedChurn;
