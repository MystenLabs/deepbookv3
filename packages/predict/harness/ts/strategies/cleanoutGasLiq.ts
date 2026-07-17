// Strategy: cleanout-gas-liq — the LIQUIDATED-account variant of cleanout-gas (predeploy P-9 /
// RP-11 follow-up). E1 (cleanout-gas) measured the cleanout of SURVIVING positions; but the
// archetypal loser is LIQUIDATED, and that path differs: a liquidated order freed its
// strike_payout_tree storage at LIQUIDATION time (apply_liquidation removes the node, no
// tombstone is written), so its cleanout (redeem_settled_permissionless -> the derived
// Liquidated close arm) frees only the account Position entry, NOT the payout-tree node that
// dominated E1's ~3.29M MIST/position rebate. This
// strategy parks N high-leverage near-ATM positions (thin floor buffer) in ONE direction so the
// keeper's liquidation pass knocks the whole batch out on an adverse drift, waits for settlement,
// then runs the permissionless cleanout. The cleanout trace records nLiquidated / nSettled (from the
// redeem events), so the fit separates the per-LIQUIDATED-position gas from the per-survivor gas and
// answers: is the cleanout still self-incentivized (net < 0) for the accounts most owed rebates?
//
// Run: STRATEGY=cleanout-gas-liq python3 -m harness up --traders 1 --seconds 1000
import { type Instruction } from "../resolver.js";
import { type CleanoutPosition } from "../runtime.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const NS = [4, 10, 20]; // positions-per-account sweep (even -> clean UP/DOWN halves)
const MIN_RUNWAY_MS = 120_000; // prefer a market with drift time (a fresh ~5m) so the batch knocks out
const MAX_RUNWAY_MS = 340_000; // ...but not the 1h market (too long to settle)
const MAX_WAIT_TICKS = 120; // ~5m markets: allow a longer settle wait than cleanout-gas
const MAX_CLEANOUT_RETRIES = 8;

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

// A market with enough runway for an adverse drift to knock the batch out (a fresh ~5m), else the
// nearest with any usable runway. Single direction per N (alternating) so the batch shares one fate.
function pickMarket(ctx: StrategyCtx): Mkt | null {
  const now = Date.now();
  const usable = ctx.markets().filter((m) => m.expiryMs - now > 40_000);
  if (!usable.length) return null;
  const drifty = usable.filter((m) => m.expiryMs - now >= MIN_RUNWAY_MS && m.expiryMs - now <= MAX_RUNWAY_MS);
  const pool = drifty.length ? drifty : usable;
  return pool.reduce((a, b) => (b.expiryMs > a.expiryMs ? b : a)); // most runway in the chosen pool
}

function legFor(ctx: StrategyCtx, market: Mkt, up: boolean): MintLeg | null {
  // liq-churn recipe: near the money (high static floor) + just under the leverage cap -> a thin
  // floor buffer, so a small adverse drift drops live gross below the floor and the keeper liquidates.
  const p = ctx.rand(0.45, 0.55);
  const inst: Instruction = {
    direction: up ? "UP" : "DN",
    leverage: ctx.leverageCap(p) * ctx.rand(0.95, 0.99),
    targetProbability: p,
    spendUsd: ctx.rand(20, 100),
  };
  const r = ctx.resolve(inst, market);
  if (!r) return null;
  return {
    strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE,
    isUp: up,
    quantity: r.quantity,
    leverage1e9: r.leverage1e9,
    maxCost: r.maxCost,
    maxProbability: r.maxProbability1e9,
  };
}

const cleanoutGasLiq: Strategy = {
  name: "cleanout-gas-liq",
  tickMs: 4000,
  maxOps: 0,
  fund: 60_000_000_000_000n, // high-leverage batches cost more premium than cleanout-gas
  async tick(ctx) {
    if (phase === "done") return null;

    if (phase === "mint") {
      if (!ctx.snapshot()) return null;
      const m = pickMarket(ctx);
      if (!m) return null;
      const n = NS[nIdx];
      // Mixed direction (first half UP, rest DOWN): whichever way spot drifts, the adverse half
      // drops below its floor and the keeper liquidates it -> ~n/2 liquidated redeems GUARANTEED
      // every market, so every cleanout carries liquidation data (no reliance on drift direction).
      const legs: MintLeg[] = [];
      for (let i = 0; i < n; i++) {
        const l = legFor(ctx, m, i < Math.ceil(n / 2));
        if (l) legs.push(l);
      }
      if (legs.length < n) return null;
      let res: any;
      try {
        res = await ctx.submitMintBatch(m, legs, { phase: "cleanout-liq-mint", nTarget: n });
      } catch (e) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "cleanout-liq-mint", n });
        return null;
      }
      const minted = ((res.events ?? []) as any[]).filter((e) => e.type?.includes("OrderMinted"));
      const positions: CleanoutPosition[] = minted.map((ev, i) => ({
        orderId: String(ev.parsedJson.order_id),
        quantity: legs[i].quantity,
      }));
      if (positions.length !== n) {
        ctx.trace({ type: "fail", tag: `minted ${positions.length}/${n}`, where: "cleanout-liq-mint-events", n });
        return null;
      }
      target = { marketId: m.id, positions };
      waitTicks = 0;
      retries = 0;
      phase = "wait";
      return "mint";
    }

    // phase === "wait": let the keeper liquidate the adverse batch during the market's life, then settle.
    if (!target) {
      phase = "mint";
      return null;
    }
    let settled = false;
    try {
      settled = await ctx.isSettled(target.marketId);
    } catch {
      // read failed (e.g. compacted) — keep waiting, bounded by MAX_WAIT_TICKS.
    }
    if (!settled) {
      if (++waitTicks > MAX_WAIT_TICKS) {
        ctx.trace({ type: "fail", tag: "settle-timeout", n: NS[nIdx], market: target.marketId });
        advance();
      }
      return null;
    }
    try {
      // Traces {type:"cleanout", n, nLiquidated, nSettled, ...gas}: nLiquidated > 0 is the liq measurement.
      await ctx.cleanout(target.marketId, target.positions);
      advance();
    } catch (e) {
      if (++retries > MAX_CLEANOUT_RETRIES) {
        ctx.trace({ type: "fail", tag: errorTag(e), where: "cleanout-liq", n: NS[nIdx] });
        advance();
      } else {
        ctx.trace({ type: "cleanoutRetry", tag: errorTag(e), attempt: retries, n: NS[nIdx] });
      }
    }
    return null;
  },
};

export default cleanoutGasLiq;
