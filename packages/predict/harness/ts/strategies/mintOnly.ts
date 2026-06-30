// Strategy 1: high-frequency mint-only — one unleveraged mint at a time, ~1/s, into the
// nearest live expiry, run-to-completion at 10000 mints. No redeems (positions accumulate).
import { type Instruction } from "../resolver.js";
import { type Strategy } from "../strategy.js";

const mintOnly: Strategy = {
  name: "mint-only",
  tickMs: 1000,
  maxOps: 10000,
  fund: 5_000_000_000_000n, // $5M (10k held mints worth of premium)
  cadence: 0,
  async tick(ctx) {
    const market = ctx.nearestExpiry();
    if (!market || !ctx.snapshot()) return null;
    const inst: Instruction = {
      direction: ctx.pick(["UP", "DN"]) as "UP" | "DN",
      leverage: 1,
      targetProbability: ctx.rand(0.2, 0.8),
      spendUsd: ctx.rand(10, 50),
    };
    return ctx.mint(market, inst);
  },
};
export default mintOnly;
