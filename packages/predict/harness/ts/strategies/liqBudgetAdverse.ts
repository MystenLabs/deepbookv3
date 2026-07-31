// Strategy: liq-budget-adverse — the ADVERSE arm of the trade-path liquidation-budget ceiling
// (DBU-695, Three Sigma #48). Same probe as liq-budget-sweep, but mints high-leverage near-ATM
// orders (just under the admission cap, p~0.5 -> thin floor buffer, same profile as liq-churn),
// so real BTC drift pushes them under their knock-out threshold and a mint's ambient pass MEETS
// liquidatable candidates instead of only healthy ones.
//
// This is the branch the filed issue is actually about: a liquidatable candidate does not just
// get priced, it gets removed from the paged liquidation index AND has its boundaries removed
// from the payout treap. Whether the per-tx wall is the computation cap or the object-runtime
// cached-objects limit (1,000 dynamic-field children) is the open question — see the header of
// liqBudgetProbe.ts for why neither is pre-declared as expected.
//
// Pair with KEEPER_LIQ_BUDGET=0: the keeper's own permissionless liquidate() lane would
// otherwise sweep these orders before a mint's ambient pass could reach them, hiding the branch.
//
// Run: KEEPER_LIQ_BUDGET=0 TRADE_LIQ_BUDGET_STAGES=0:24,900:512,1800:1500,2700:3000 \
//      SIM_GAS_BUDGET=50000000000 python3 -m harness campaign liq-budget-adverse --timeout 3600
import { type Instruction } from "../resolver.js";
import { makeLiqBudgetStrategy } from "./liqBudgetProbe.js";

export default makeLiqBudgetStrategy({
  name: "liq-budget-adverse",
  fund: 20_000_000_000_000n,
  instruction: (ctx): Instruction => {
    const p = ctx.rand(0.45, 0.55); // near the money -> high static floor -> tight knock-out level
    return {
      direction: ctx.pick(["UP", "DN"]) as "UP" | "DN",
      leverage: ctx.leverageCap(p) * ctx.rand(0.9, 0.99), // just under the admission cap
      targetProbability: p,
      spendUsd: ctx.rand(5, 10),
    };
  },
});
