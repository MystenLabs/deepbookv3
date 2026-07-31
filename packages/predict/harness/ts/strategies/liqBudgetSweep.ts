// Strategy: liq-budget-sweep — the HEALTHY arm of the trade-path liquidation-budget ceiling
// (DBU-695, Three Sigma #48). Fills one far-1h market with LOW-leverage orders (1.1x, far above
// their floor, so nothing is ever knocked out) and measures per-mint computation as the keeper's
// budget ladder steps up. Every candidate the ambient pass selects is priced and found healthy,
// so this isolates the scan+price cost — the floor under any budget setting, paid on every mint
// and live redeem whether or not anything is liquidatable.
//
// Because nothing liquidates, `minted` here IS the active leveraged book, which makes this the
// arm that yields the clean cost(budget, book) surface. The adverse branch is liq-budget-adverse.
//
// Run: TRADE_LIQ_BUDGET_STAGES=0:24,900:512,1800:1500,2700:3000 SIM_GAS_BUDGET=50000000000
//      python3 -m harness campaign liq-budget-sweep --timeout 3600
import { type Instruction } from "../resolver.js";
import { makeLiqBudgetStrategy } from "./liqBudgetProbe.js";

export default makeLiqBudgetStrategy({
  name: "liq-budget-sweep",
  fund: 20_000_000_000_000n,
  instruction: (ctx): Instruction => ({
    direction: "UP",
    leverage: 1.1, // low -> far above floor -> never liquidated -> minted == active book
    targetProbability: ctx.rand(0.45, 0.6),
    spendUsd: ctx.rand(5, 10),
  }),
});
