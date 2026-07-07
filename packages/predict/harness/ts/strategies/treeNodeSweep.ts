// Strategy: tree-node-sweep — isolate PAYOUT-TREE NODE COUNT as the driver of the pool-flush
// object-runtime cached-objects abort (`MEMORY_LIMIT_EXCEEDED: Object runtime cached objects limit
// (1000 entries) reached` in dynamic_field::borrow_child_object). Locks ONE persisting far market and
// fills its payout tree with 1x (UNLEVERAGED) orders at DISTINCT strikes:
//   - 1x => order::is_leveraged() == false => insert_order is a no-op => ZERO liquidation-book pages.
//   - each distinct $1 strike => one new PayoutNode (a Table<tick,PayoutNode> child); pos-inf isn't stored.
//   - value_expiry -> current_nav -> walk_linear loads EVERY node, so tree nodes are the only
//     dynamic-field child that grows.
// Prediction: the keeper flush aborts with the identical 1000-entry error once nodeCount (+ a small
// fixed overhead from the near-empty cadence markets) crosses 1000 — with NO pages present, assigning
// the abort to tree-node count alone. The tree's own EMaxPayoutTreeNodes cap (strike_payout_tree:1) is a
// DIFFERENT error on the MINT tx, so the flush cache-limit abort is distinguishable from the mint cap.
// REQUIRES SIM_GAS_BUDGET=50000000000. Run duration-only: campaign … --timeout N.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
const LVG = 1.0; // 1x -> is_leveraged() == false -> NO liquidation-book pages. Tree nodes are the only variable.
const BATCH = 12; // mints/PTB; adaptive shrink near the cap keeps node-count resolution fine at the crossover.
const NEAR_CAP = 940; // below the ~1000 crossover, step finely so a flush lands in the failure window.
const SPEND = 7; // net-premium budget per leg (USD)
const P_HI = 0.98;
const P_LO = 0.02; // 1x is feasible across the full [0.01,0.99] entry-prob band -> a wide distinct-strike sweep.
const P_STEP = 0.00045; // ~2100 UP samples across the band -> up to ~2100 distinct $1 strikes (>> the 1000 cap).

let lockedId: string | null = null;
const usedStrikes = new Set<number>(); // distinct integer-USD strikes minted on the locked market == on-chain node count
let pcUp = P_HI; // UP probability cursor (walks DOWN -> strike UP)
let pcDn = P_LO; // DN fallback cursor (walks UP -> strike UP) once the UP band saturates
let dnPhase = false;

function targetMarket(ctx: StrategyCtx): Mkt | null {
  if (lockedId) return ctx.markets().find((mk) => mk.id === lockedId) ?? null;
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a));
  if (farthest.expiryMs <= Date.now() + TWO_HOURS_MS) return null; // wait for a >2h market to persist the whole run
  lockedId = farthest.id;
  return farthest;
}

function legAt(ctx: StrategyCtx, market: Mkt, p: number, isUp: boolean): MintLeg | null {
  const inst: Instruction = { direction: isUp ? "UP" : "DN", leverage: LVG, targetProbability: p, spendUsd: SPEND };
  const r = ctx.resolve(inst, market);
  if (!r) return null;
  const usd = Math.round(r.strikeUsd);
  if (usedStrikes.has(usd)) return null; // collision -> caller advances the cursor and retries
  usedStrikes.add(usd);
  return { strike1e9: BigInt(usd) * SCALE, isUp, quantity: r.quantity, leverage1e9: r.leverage1e9, maxCost: r.maxCost, maxProbability: r.maxProbability1e9 };
}

// Walk the probability cursor to the next distinct strike (UP band first, DN band as fallback).
function nextLeg(ctx: StrategyCtx, market: Mkt): MintLeg | null {
  if (!dnPhase) {
    while (pcUp > P_LO) {
      const p = pcUp;
      pcUp -= P_STEP;
      const leg = legAt(ctx, market, p, true);
      if (leg) return leg;
    }
    dnPhase = true; // UP band exhausted -> DN strikes for more distinct nodes
  }
  while (pcDn < P_HI) {
    const p = pcDn;
    pcDn += P_STEP;
    const leg = legAt(ctx, market, p, false);
    if (leg) return leg;
  }
  return null; // both bands saturated
}

const treeNodeSweep: Strategy = {
  name: "tree-node-sweep",
  tickMs: 1200,
  maxOps: 0, // duration-only: fill toward the node cap, then hold so the keeper flush is measured at high node count
  fund: 20_000_000_000_000n,
  async tick(ctx) {
    const market = targetMarket(ctx);
    if (!market || !ctx.snapshot()) return null;
    const want = usedStrikes.size > NEAR_CAP ? 2 : BATCH;
    const legs: MintLeg[] = [];
    for (let i = 0; i < want; i++) {
      const l = nextLeg(ctx, market);
      if (l) legs.push(l);
    }
    if (legs.length === 0) return null; // bands saturated: hold; the keeper keeps flushing at this node count
    try {
      await ctx.submitMintBatch(market, legs, { nodes: usedStrikes.size, market: market.id });
      ctx.trace({ type: "nodes", nodeCount: usedStrikes.size, market: market.id });
      return "mint";
    } catch (e) {
      // Atomic batch: on abort NONE of the legs committed, so back out the strikes we optimistically
      // counted. EMaxPayoutTreeNodes (strike_payout_tree:1) at ~1000 is the expected hard stop -> HOLD.
      for (const l of legs) usedStrikes.delete(Number(l.strike1e9 / SCALE));
      if (isOog(e)) ctx.trace({ type: "mintBatch", n: legs.length, nodes: usedStrikes.size, oog: true, err: errorTag(e) });
      else ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, nodes: usedStrikes.size });
      return null;
    }
  },
};
export default treeNodeSweep;
