// Strategy: cleanout-gas — the E1 measurement for predeploy P-9 (rebate self-incentive). For each
// N in a sweep, park N low-leverage positions on THIS account in a fresh near-expiry market, wait for
// the keeper to settle it, then submit ONE permissionless cleanout PTB (redeem all N settled positions
// + claim the trading-loss rebate) and record its FULL gas breakdown. The net gas
// (computation + storage − rebate) as a function of N answers the open question: is the permissionless
// cleanout self-incentivized — i.e. net < 0, the cleaner PAID by the storage rebate from deleting the
// N position dynamic-fields + the ExpiryTradingSummary entry? The linear fit net(N) = a + b·N gives the
// per-position marginal (b) and the fixed claim term (a), hence the break-even N* and, if net stays
// positive, the minimum up-front storage that would have to be built in to make it incentivized.
//
// Run: STRATEGY=cleanout-gas python3 -m harness up --traders 1 --seconds 700
//   (or `python3 -m harness campaign cleanout-gas --timeout 700`). Analyze from the trace's
//   {type:"cleanout", n, computationCost, storageCost, storageRebate, nonRefundableStorageFee, net} rows.
import { type Instruction } from "../resolver.js";
import { type CleanoutPosition } from "../runtime.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const NS = [1, 3, 5, 10, 20]; // positions-per-account sweep -> the net(N) linear fit
const LVG = 1.1; // low leverage: far above the floor -> never liquidated -> survives to a settled redeem
const MINT_RUNWAY_MS = 25_000; // need this much time-to-expiry to mint and still let the market settle
const MAX_WAIT_TICKS = 60; // give up waiting for settlement after this many ticks (not expected for a 1m market)
const MAX_CLEANOUT_RETRIES = 8; // retry past transient valuation-lock / RPC races before abandoning an N

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
  // ATM-ish, low leverage, small spend; varied probability so the legs are distinct payout-tree nodes.
  const inst: Instruction = { direction: "UP", leverage: LVG, targetProbability: ctx.rand(0.45, 0.6), spendUsd: ctx.rand(5, 10) };
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

const cleanoutGas: Strategy = {
  name: "cleanout-gas",
  tickMs: 4000, // poll pace for settlement + cleanout retries
  maxOps: 0, // duration-only: the sweep self-terminates (phase "done") when every N is measured
  fund: 40_000_000_000_000n, // generous: the NS-sum of positions across several markets
  async tick(ctx) {
    if (phase === "done") return null;

    if (phase === "mint") {
      if (!ctx.snapshot()) return null;
      const m = ctx.nearestExpiry();
      // A fresh market with enough runway to mint AND still settle within the run.
      if (!m || m.expiryMs - Date.now() < MINT_RUNWAY_MS) return null;
      const n = NS[nIdx];
      const legs: MintLeg[] = [];
      for (let i = 0; i < n; i++) {
        const l = legFor(ctx, m);
        if (l) legs.push(l);
      }
      if (legs.length < n) return null; // couldn't price all legs this tick — retry next tick
      let res: any;
      try {
        res = await ctx.submitMintBatch(m, legs, { phase: "cleanout-mint", nTarget: n });
      } catch (e) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "cleanout-mint", n });
        return null;
      }
      // Pair each OrderMinted event (emitted in PTB/leg order) with its leg quantity for the full close.
      const minted = ((res.events ?? []) as any[]).filter((e) => e.type?.includes("OrderMinted"));
      const positions: CleanoutPosition[] = minted.map((ev, i) => ({
        orderId: String(ev.parsedJson.order_id),
        quantity: legs[i].quantity,
      }));
      if (positions.length !== n) {
        ctx.trace({ type: "fail", tag: `minted ${positions.length}/${n}`, where: "cleanout-mint-events", n });
        return null;
      }
      target = { marketId: m.id, positions };
      waitTicks = 0;
      retries = 0;
      phase = "wait";
      return "mint";
    }

    // phase === "wait": poll settlement, then clean out.
    if (!target) {
      phase = "mint";
      return null;
    }
    let settled = false;
    try {
      settled = await ctx.isSettled(target.marketId);
    } catch {
      // market read failed (e.g. compacted) — treat as still-waiting, bounded by MAX_WAIT_TICKS.
    }
    if (!settled) {
      if (++waitTicks > MAX_WAIT_TICKS) {
        ctx.trace({ type: "fail", tag: "settle-timeout", n: NS[nIdx], market: target.marketId });
        advance();
      }
      return null;
    }
    try {
      await ctx.cleanout(target.marketId, target.positions); // traces {type:"cleanout", n, ...gas}
      advance();
    } catch (e) {
      if (++retries > MAX_CLEANOUT_RETRIES) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "cleanout", n: NS[nIdx] });
        advance();
      } else {
        // Most likely the keeper's valuation lock (claim asserts !valuation_in_progress) — retry.
        ctx.trace({ type: "cleanoutRetry", tag: errorTag(e), attempt: retries, n: NS[nIdx] });
      }
    }
    return null;
  },
};

export default cleanoutGas;
