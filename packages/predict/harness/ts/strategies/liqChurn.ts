// Strategy 3: leverage -> liquidation churn. Mint HIGH-leverage near-the-money orders (just
// under the admission cap, p≈0.5 -> high static floor, tight knock-out level) and hold them,
// so as the real BTC spot drifts some fall under their floor and the keeper's liquidation
// pass + the NAV-under-liquidation accounting are exercised — the least-tested leverage path.
import { type Instruction } from "../resolver.js";
import { type Strategy } from "../strategy.js";

const liqChurn: Strategy = {
  name: "liq-churn",
  tickMs: 1500,
  maxOps: 2000,
  fund: 10_000_000_000_000n,
  async tick(ctx) {
    ctx.pruneSettled();
    const market = ctx.randomExpiry();
    if (!market || !ctx.snapshot()) return null;
    const p = ctx.rand(0.45, 0.55); // near the money
    const inst: Instruction = {
      direction: ctx.pick(["UP", "DN"]) as "UP" | "DN",
      leverage: ctx.leverageCap(p) * ctx.rand(0.9, 0.99), // just under the cap: feasible, high floor
      targetProbability: p,
      spendUsd: ctx.rand(20, 100),
    };
    return ctx.mint(market, inst);
  },
};
export default liqChurn;
