// Strategy: mint-batch — the #cap-mintbatch root-cause probe. A 100-mint PTB cost 3-5B computation in
// the 2026-06-28 stress while 100 standalone mints ~= 650M; the ~45x per-candidate liquidation-scan
// amplification is REAL but the MECHANISM is unproven (dirtied-dynamic-field metering vs a per-tx
// metering effect). Per-function gas attribution is NOT available on localnet, so this settles it by
// DIFFERENTIAL on real total computationCost via a fixed script of controlled batches (one PTB/tick):
//   - sweep N in {1,2,5,10,20,50,100} identical leveraged (2x) mints -> cost(N): linear vs super-linear.
//     N=1 IS the standalone lev2 baseline (a 1-command PTB == a standalone tx).
//   - discriminator at K=20: [K lev1] , [K lev1 + 1 lev2] , [K lev2]. lev1 (1x) mints do NOT write the
//     liq book (insert_order is a no-op for 1x), so the lev2 marginal in the lev1-prefix batch
//     (cost[K lev1 + lev2] - cost[K lev1]) vs a standalone lev2 separates "prior liq-book WRITES dirty
//     the pages" (dirtied-field) from "being command N in a multi-command PTB, period" (tx-metering).
// A large batch may OOG at the ~5e9 computation cap -> that IS the ~110-op atomic-batch ceiling (caught
// + traced as {oog:true}, not a crash). REQUIRES SIM_GAS_BUDGET=50000000000 so a batch can reach the
// cap; on the default 1e9 budget the larger batches OOG on the budget, not the computation wall.
import { type Instruction } from "../resolver.js";
import { type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;

type Leg = { strike1e9: bigint; isUp: boolean; quantity: bigint; leverage1e9: bigint; maxCost: bigint; maxProbability: bigint };
// One controlled batch per tick, cycled. `n` identical legs at `lev`x; `tailLev2` appends one 2x leg.
type Spec = { kind: string; n: number; lev: number; tailLev2?: boolean };
const SCRIPT: Spec[] = [
  { kind: "sweep", n: 1, lev: 2 }, { kind: "sweep", n: 2, lev: 2 }, { kind: "sweep", n: 5, lev: 2 },
  { kind: "sweep", n: 10, lev: 2 }, { kind: "sweep", n: 20, lev: 2 }, { kind: "sweep", n: 50, lev: 2 },
  { kind: "sweep", n: 100, lev: 2 },
  { kind: "lev1", n: 20, lev: 1 }, // K lev1: no liq-book writes (insert_order no-op for 1x)
  { kind: "lev1_plus_lev2", n: 20, lev: 1, tailLev2: true }, // lev2 marginal here = cost - cost(lev1)
  { kind: "lev2", n: 20, lev: 2 }, // K lev2: full liq-book writes
  { kind: "lev1_single", n: 1, lev: 1 }, // standalone lev1 baseline
];

let step = 0;
let leveragedBook = 0; // running count of leveraged (>1x) orders inserted into the liq book

// Lock onto ONE persisting far-out (1h, >2h away) market so the whole script runs against one book.
function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (ctx.held.length > 0) return ctx.markets().find((m) => m.id === ctx.held[0].marketId) ?? null;
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  return farthest.expiryMs > Date.now() + TWO_HOURS_MS ? farthest : null;
}

function legFrom(ctx: StrategyCtx, market: Mkt, leverage: number): Leg | null {
  const inst: Instruction = { direction: "UP", leverage, targetProbability: 0.5, spendUsd: ctx.rand(5, 10) };
  const r = ctx.resolve(inst, market);
  if (!r) return null;
  return {
    strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE,
    isUp: true,
    quantity: r.quantity,
    leverage1e9: r.leverage1e9,
    maxCost: r.maxCost,
    maxProbability: r.maxProbability1e9,
  };
}

const mintBatch: Strategy = {
  name: "mint-batch",
  tickMs: 1500, // one PTB/tick; batches can be large, give the node a moment
  maxOps: SCRIPT.length * 4, // ~4 cycles: enough (N,cost) points without nearing the 5000 leveraged cap
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const spec = SCRIPT[step % SCRIPT.length];
    step++;

    const base = legFrom(ctx, market, spec.lev);
    if (!base) return null;
    const legs: Leg[] = [];
    for (let i = 0; i < spec.n; i++) legs.push(base);
    if (spec.tailLev2) {
      const l2 = legFrom(ctx, market, 2);
      if (!l2) return null;
      legs.push(l2);
    }
    const leveragedLegs = legs.filter((l) => l.leverage1e9 > SCALE).length;
    try {
      await ctx.submitMintBatch(market, legs, { kind: spec.kind, lev: spec.lev, book: leveragedBook });
      leveragedBook += leveragedLegs;
      return "mint";
    } catch (e) {
      // A large batch OOGs at the ~5e9 computation cap -> the atomic-batch ceiling. Record, don't crash.
      ctx.trace({ type: "mintBatch", kind: spec.kind, n: legs.length, lev: spec.lev, book: leveragedBook, oog: true, err: String(e).slice(0, 80) });
      return null;
    }
  },
};
export default mintBatch;
