// Default strategy: the original fuzz trader (random feasible mints + full redeems + a
// fraction of adversarial probes). Preserves `up` / `up-many` behavior unchanged.
import { RESOLVER_MARKET } from "../predictConfig.js";
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const ADVERSARIAL_FRACTION = 0.2;

// A deliberately-rejectable mint to exercise the admission + slippage guards. A guard abort
// is the expected outcome; a wrongly-accepted probe is traced as a guard gap.
async function adversarialProbe(ctx: StrategyCtx, market: Mkt, direction: "UP" | "DN"): Promise<null> {
  const mode = ctx.pick(["over-cap-leverage", "tight-max-cost", "tight-max-probability"]);
  const p = ctx.rand(0.25, 0.7);
  const base: Instruction = { direction, leverage: ctx.rand(1, ctx.leverageCap(p)), targetProbability: p, spendUsd: ctx.rand(10, 200) };
  const r = ctx.resolve(base, market);
  if (!r) return null;
  let leverage = r.leverage1e9;
  let maxCost = r.maxCost;
  let maxProbability = r.maxProbability1e9;
  if (mode === "over-cap-leverage") leverage = BigInt(Math.round(RESOLVER_MARKET.maxAdmissionLeverage * ctx.rand(1.5, 3) * 1e9));
  else if (mode === "tight-max-cost") maxCost = r.maxCost / 3n;
  else maxProbability = r.maxProbability1e9 / 3n;
  try {
    await ctx.submitMint(market, { strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: direction === "UP", quantity: r.quantity, leverage1e9: leverage, maxCost, maxProbability });
    ctx.trace({ type: "adversarial-accepted", mode, market: market.id.slice(0, 10) });
  } catch (e) {
    ctx.trace({ type: "fail", adversarial: mode, tag: errorTag(e) });
  }
  return null;
}

const fuzz: Strategy = {
  name: "fuzz",
  tickMs: 4000,
  maxOps: 0, // duration-only (the up/up-many default)
  fund: 1_000_000_000_000n, // $1M
  async tick(ctx) {
    ctx.pruneSettled();
    if (!ctx.markets().length || !ctx.snapshot()) return null;

    // 30%: redeem a held order (full close).
    if (ctx.held.length && Math.random() < 0.3) {
      const h = ctx.pick(ctx.held);
      return ctx.redeem(h, h.quantity);
    }

    // else: mint a fuzzed position into a random expiry; a fraction probes the guards.
    const market = ctx.randomExpiry();
    if (!market) return null;
    const direction = ctx.pick(["UP", "DN"]) as "UP" | "DN";
    if (Math.random() < ADVERSARIAL_FRACTION) return adversarialProbe(ctx, market, direction);
    const targetProbability = ctx.rand(0.1, 0.9);
    const inst: Instruction = { direction, leverage: ctx.rand(1, ctx.leverageCap(targetProbability)), targetProbability, spendUsd: ctx.rand(10, 300) };
    return ctx.mint(market, inst);
  },
};
export default fuzz;
