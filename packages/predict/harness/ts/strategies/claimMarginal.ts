// Strategy: claim-marginal — isolates the rebate CLAIM's own gas economics (P-9 / RP-11 follow-up).
// A gas-maximizing searcher already redeeming an account's settled positions will only ALSO run the
// rebate claim if the claim's MARGINAL net gas is <= 0; otherwise it skips the claim, and non-owed
// accounts' (winners') reserve basis never resolves back to the pool. E1 proved the BUNDLE is
// net-negative, but the claim's own contribution was buried in the intercept. This measures it
// directly: per settled account, run the N redeems WITHOUT the claim (redeemAll), then the claim
// ALONE (claimRebate). standalone-claim net = the claimRebate trace; in-bundle marginal ≈
// standalone minus one base-tx (the bundle shares the base tx + settle with the redeems).
//
// Run: STRATEGY=claim-marginal python3 -m harness up --traders 1 --seconds 600
import { type Instruction } from "../resolver.js";
import { type CleanoutPosition } from "../runtime.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const NS = [3, 10]; // claim-only is ~N-independent; a couple of N confirms it + gives a redeemAll baseline
const LVG = 1.1; // low leverage: survive to a settled redeem (clean redeemAll baseline)
const MINT_RUNWAY_MS = 25_000;
const MAX_WAIT_TICKS = 60;
const MAX_RETRIES = 8;

type Phase = "mint" | "wait" | "done";
let phase: Phase = "mint";
let nIdx = 0;
let target: { marketId: string; positions: CleanoutPosition[] } | null = null;
let waitTicks = 0;
let retries = 0;

function advance() {
  nIdx++;
  target = null;
  waitTicks = 0;
  retries = 0;
  phase = nIdx >= NS.length ? "done" : "mint";
}

function legFor(ctx: StrategyCtx, market: Mkt): MintLeg | null {
  const inst: Instruction = { direction: "UP", leverage: LVG, targetProbability: ctx.rand(0.45, 0.6), spendUsd: ctx.rand(5, 10) };
  const r = ctx.resolve(inst, market);
  if (!r) return null;
  return { strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: true, quantity: r.quantity, leverage1e9: r.leverage1e9, maxCost: r.maxCost, maxProbability: r.maxProbability1e9 };
}

const claimMarginal: Strategy = {
  name: "claim-marginal",
  tickMs: 4000,
  maxOps: 0,
  fund: 40_000_000_000_000n,
  async tick(ctx) {
    if (phase === "done") return null;

    if (phase === "mint") {
      if (!ctx.snapshot()) return null;
      const m = ctx.nearestExpiry();
      if (!m || m.expiryMs - Date.now() < MINT_RUNWAY_MS) return null;
      const n = NS[nIdx];
      const legs: MintLeg[] = [];
      for (let i = 0; i < n; i++) {
        const l = legFor(ctx, m);
        if (l) legs.push(l);
      }
      if (legs.length < n) return null;
      let res: any;
      try {
        res = await ctx.submitMintBatch(m, legs, { phase: "claim-marginal-mint", nTarget: n });
      } catch (e) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "claim-marginal-mint", n });
        return null;
      }
      const minted = ((res.events ?? []) as any[]).filter((e) => e.type?.includes("OrderMinted"));
      const positions: CleanoutPosition[] = minted.map((ev, i) => ({ orderId: String(ev.parsedJson.order_id), quantity: legs[i].quantity }));
      if (positions.length !== n) {
        ctx.trace({ type: "fail", tag: `minted ${positions.length}/${n}`, where: "claim-marginal-events", n });
        return null;
      }
      target = { marketId: m.id, positions };
      waitTicks = 0;
      retries = 0;
      phase = "wait";
      return "mint";
    }

    // phase === "wait": once settled, redeem-all (no claim) THEN claim-alone, tracing each.
    if (!target) {
      phase = "mint";
      return null;
    }
    let settled = false;
    try {
      settled = await ctx.isSettled(target.marketId);
    } catch {
      // keep waiting
    }
    if (!settled) {
      if (++waitTicks > MAX_WAIT_TICKS) {
        ctx.trace({ type: "fail", tag: "settle-timeout", n: NS[nIdx], market: target.marketId });
        advance();
      }
      return null;
    }
    try {
      await ctx.redeemAll(target.marketId, target.positions); // traces {type:"redeemAll", n, ...gas}
      await ctx.claimRebate(target.marketId); // traces {type:"claimRebate", ...gas}  <- the number under test
      advance();
    } catch (e) {
      if (++retries > MAX_RETRIES) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "claim-marginal", n: NS[nIdx] });
        advance();
      } else {
        ctx.trace({ type: "claimMarginalRetry", tag: errorTag(e), attempt: retries, n: NS[nIdx] });
      }
    }
    return null;
  },
};

export default claimMarginal;
