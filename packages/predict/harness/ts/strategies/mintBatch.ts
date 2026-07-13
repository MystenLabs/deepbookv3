// Strategy: mint-batch — the #cap-mintbatch root-cause probe. A 100-mint PTB cost 3-5B computation in
// the 2026-06-28 stress while 100 standalone mints ~= 650M; the batch amplification of the per-op
// liquidation scan is REAL but the MECHANISM is unproven (dirtied-dynamic-field metering vs a per-tx
// metering effect). Per-function gas attribution is NOT available on localnet, so this settles it by
// DIFFERENTIAL on real total computationCost via a fixed script of controlled batches (one PTB/tick):
//   - sweep N in {1,2,5,10,20,50,100} identical leveraged mints -> builds the book PAST the 24-candidate
//     scan budget (so the discriminator runs saturated) and shows cost(N). NOTE cost(N) is confounded
//     (the book grows across the sweep); the discriminator is the clean test.
//   - discriminator at a SATURATED book (scan pinned at 24, so +-1 book is noise), back-to-back:
//       S  = standalone leveraged mint
//       A  = [K lev1]                (1x mints do NOT write the liq book -- insert_order is a no-op)
//       AB = [K lev1 + 1 leveraged]  -> leveraged marginal = AB - A (NO prior liq-book writes)
//       BB = [K leveraged]           (full prior liq-book writes)
//     (AB-A) vs S isolates "do prior NON-liq-book commands amplify?"; (BB/K) vs S isolates "do prior
//     LIQ-BOOK writes amplify?". If (AB-A)~S but (BB/K)>>S -> amplification needs same-PTB liq-book
//     writes (dirtied-field). If (AB-A)>>S -> a multi-command PTB alone amplifies (tx-metering).
// A large batch may OOG at the ~5e9 computation cap -> the ~110-op atomic-batch ceiling (caught + traced
// as {oog:true}, not a crash). REQUIRES SIM_GAS_BUDGET=50000000000 so a batch can reach the cap.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
// Leveraged but far above floor: it inserts into the liq book (is_leveraged) yet is never liquidated, so
// the scan cost is isolated with no book churn (matches nav-stress's 1.1x).
const LVG = 1.1;

// One controlled batch per tick, cycled. `n` identical legs at `lev`x; `tailLeveraged` appends one LVG leg.
type Spec = { kind: string; n: number; lev: number; tailLeveraged?: boolean };
const SCRIPT: Spec[] = [
  { kind: "sweep", n: 1, lev: LVG }, { kind: "sweep", n: 2, lev: LVG }, { kind: "sweep", n: 5, lev: LVG },
  { kind: "sweep", n: 10, lev: LVG }, { kind: "sweep", n: 20, lev: LVG }, { kind: "sweep", n: 50, lev: LVG },
  { kind: "sweep", n: 100, lev: LVG },
  { kind: "disc_std", n: 1, lev: LVG }, // S: standalone leveraged
  { kind: "disc_lev1", n: 20, lev: 1 }, // A: K lev1 (1x -> no liq-book writes)
  { kind: "disc_prefix", n: 20, lev: 1, tailLeveraged: true }, // AB: K lev1 + 1 leveraged
  { kind: "disc_lvg", n: 20, lev: LVG }, // BB: K leveraged (full liq-book writes)
];

let step = 0;
let leveragedBook = 0; // running count of leveraged (>1x) orders in the liq book
let lockedId: string | null = null;

// Lock onto ONE persisting far-out (1h, >2h away) market so the whole script runs against one book.
function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (lockedId) {
    const locked = ctx.markets().find((m) => m.id === lockedId);
    if (locked) return locked;
    lockedId = null;
    leveragedBook = 0;
    step = 0;
  }
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  if (farthest.expiryMs <= Date.now() + TWO_HOURS_MS) return null;
  lockedId = farthest.id;
  return farthest;
}

function legFrom(ctx: StrategyCtx, market: Mkt, leverage: number): MintLeg | null {
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
  maxOps: SCRIPT.length * 4, // ~4 cycles: 4 discriminator samples at growing (saturated) books
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const spec = SCRIPT[step % SCRIPT.length];
    step++;

    const base = legFrom(ctx, market, spec.lev);
    if (!base) return null;
    const legs: MintLeg[] = [];
    for (let i = 0; i < spec.n; i++) legs.push(base);
    if (spec.tailLeveraged) {
      const l = legFrom(ctx, market, LVG);
      if (!l) return null;
      legs.push(l);
    }
    const leveragedLegs = legs.filter((l) => l.leverage1e9 > SCALE).length;
    try {
      await ctx.submitMintBatch(market, legs, { kind: spec.kind, lev: spec.lev, book: leveragedBook });
      leveragedBook += leveragedLegs;
      return "mint";
    } catch (e) {
      if (isOog(e)) {
        // OOG at the tx gas budget / 5e9 computation cap -> the atomic-batch ceiling. NOT a bug.
        ctx.trace({ type: "mintBatch", kind: spec.kind, n: legs.length, lev: spec.lev, book: leveragedBook, oog: true, err: errorTag(e) });
      } else {
        // A real (module:code) abort inside a batched PTB is a BUG the oracle MUST see — do not mask it as
        // OOG. Emit a fail record so analyze.py's bug oracle classifies it.
        ctx.trace({ type: "fail", tag: errorTag(e), batch: spec.kind, n: legs.length });
      }
      return null;
    }
  },
};
export default mintBatch;
