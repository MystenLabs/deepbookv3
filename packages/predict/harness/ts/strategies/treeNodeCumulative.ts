// Strategy: tree-node-cumulative — settle whether Sui's object-runtime cache is PER-COMMAND or
// CUMULATIVE across the flush PTB. Fills the TWO farthest markets to PER_MARKET_TARGET tree nodes
// EACH with 1x orders (zero leverage-book pages); neither market alone reaches the 1000 cache/mint
// cap. Then holds so the keeper flush (value_expiry A + value_expiry B + finish) runs with both.
//   - flush ABORTS with `cached objects limit (1000 entries)`  => CUMULATIVE across commands
//     (600+600 > 1000) => C-1's flush wall is the SUM of nodes across all live markets.
//   - flush SUCCEEDS                                            => PER-COMMAND (cache resets each
//     value_expiry) => the wall is max single-market nodes.
// REQUIRES SIM_GAS_BUDGET=50000000000. Run duration-only: campaign … --timeout N.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const MIN_LIFE_MS = 20 * 60_000; // lock markets that comfortably outlive the run
const LVG = 1.0; // 1x -> is_leveraged() == false -> NO liquidation-book pages. Tree nodes only.
const BATCH = 12;
const PER_MARKET_TARGET = 600; // each < 1000 (no single-market trigger); sum 1200 > 1000 (cumulative trigger)
const SPEND = 7;
const P_HI = 0.98;
const P_LO = 0.02;
const P_STEP = 0.00045;

interface MState {
  used: Set<number>;
  pcUp: number;
  pcDn: number;
  dnPhase: boolean;
}
const state = new Map<string, MState>();
let locked: string[] = [];
let rr = 0;
let heldTraced = false;

function ensureLocked(ctx: StrategyCtx): string[] {
  if (locked.length >= 2) return locked;
  const live = ctx.markets().filter((m) => m.expiryMs > Date.now() + MIN_LIFE_MS);
  live.sort((a, b) => b.expiryMs - a.expiryMs); // farthest first
  locked = live.slice(0, 2).map((m) => m.id);
  for (const id of locked) if (!state.has(id)) state.set(id, { used: new Set(), pcUp: P_HI, pcDn: P_LO, dnPhase: false });
  return locked;
}

function nextLeg(ctx: StrategyCtx, market: Mkt, s: MState): MintLeg | null {
  const tryAt = (p: number, isUp: boolean): MintLeg | null => {
    const inst: Instruction = { direction: isUp ? "UP" : "DN", leverage: LVG, targetProbability: p, spendUsd: SPEND };
    const r = ctx.resolve(inst, market);
    if (!r) return null;
    const usd = Math.round(r.strikeUsd);
    if (s.used.has(usd)) return null;
    s.used.add(usd);
    return { strike1e9: BigInt(usd) * SCALE, isUp, quantity: r.quantity, leverage1e9: r.leverage1e9, maxCost: r.maxCost, maxProbability: r.maxProbability1e9 };
  };
  if (!s.dnPhase) {
    while (s.pcUp > P_LO) {
      const p = s.pcUp;
      s.pcUp -= P_STEP;
      const l = tryAt(p, true);
      if (l) return l;
    }
    s.dnPhase = true;
  }
  while (s.pcDn < P_HI) {
    const p = s.pcDn;
    s.pcDn += P_STEP;
    const l = tryAt(p, false);
    if (l) return l;
  }
  return null;
}

const treeNodeCumulative: Strategy = {
  name: "tree-node-cumulative",
  tickMs: 1000,
  maxOps: 0,
  fund: 30_000_000_000_000n,
  // Probes the object-cache ceiling cumulatively: the flush is EXPECTED to abort once the two markets'
  // combined node count crosses ~1000. Whitelisted for THIS run only (a normal flush hitting it is C-1).
  expect: { terminal: ["cached objects limit"], note: "cumulative two-market node ceiling (C-1)" },
  async tick(ctx) {
    const ids = ensureLocked(ctx);
    if (ids.length < 2 || !ctx.snapshot()) return null;
    // Round-robin to the next locked market still under target.
    let market: Mkt | null = null;
    let s: MState | null = null;
    for (let k = 0; k < ids.length; k++) {
      const id = ids[(rr + k) % ids.length];
      const st = state.get(id)!;
      if (st.used.size < PER_MARKET_TARGET) {
        const m = ctx.markets().find((mk) => mk.id === id);
        if (m) {
          market = m;
          s = st;
          rr = (rr + k + 1) % ids.length;
          break;
        }
      }
    }
    if (!market || !s) {
      // Both at target: HOLD so the keeper flushes both. One held trace marks the state for the analyzer.
      if (!heldTraced) {
        heldTraced = true;
        ctx.trace({ type: "held", totals: ids.map((id) => state.get(id)!.used.size) });
      }
      return null;
    }
    const room = PER_MARKET_TARGET - s.used.size;
    const want = Math.min(room > 60 ? BATCH : 2, room);
    const legs: MintLeg[] = [];
    for (let i = 0; i < want; i++) {
      const l = nextLeg(ctx, market, s);
      if (l) legs.push(l);
    }
    if (!legs.length) return null;
    try {
      await ctx.submitMintBatch(market, legs, { market: market.id, nodes: s.used.size });
      ctx.trace({ type: "nodes", market: market.id, nodeCount: s.used.size, totals: ids.map((id) => state.get(id)!.used.size) });
      return "mint";
    } catch (e) {
      for (const l of legs) s.used.delete(Number(l.strike1e9 / SCALE));
      if (isOog(e)) ctx.trace({ type: "mintBatch", n: legs.length, oog: true, err: errorTag(e) });
      else ctx.trace({ type: "fail", tag: errorTag(e), n: legs.length, market: market.id });
      return null;
    }
  },
};
export default treeNodeCumulative;
