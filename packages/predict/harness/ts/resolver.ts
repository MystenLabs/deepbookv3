// Semantic mint resolver: turn "2x UP @ ~5c, spend $100" into concrete mint args.
//
// Off-chain, using the snapshot we will push (perfect knowledge of the pricing
// inputs). Ports the contract's admission curve + mint economics exactly (in float;
// small drift accepted). The contract derives net_premium/floor from (quantity,
// entry_probability), so we only pick the strike, check feasibility, and
// size quantity; max_cost/max_probability guard the actual on-chain price.

import { type Svi, directionProbability, forwardPrice } from "./pricer.js";

const SCALE = 1_000_000_000; // 1e9 fixed-point (float_scaling) — probability
const PROB_SLACK = 1.1; // max_probability = quoted p + 10% (per-contract slippage cap)
const COST_SLACK = 1.2; // max_cost = spend + 20% (covers net_premium + fees + slippage)
const USDC_DECIMALS = 1_000_000; // USDC raw — quantity/payout/cash are USDC-scaled, not 1e9
const POS_INF_TICK = 2 ** 30 - 1; // range_codec pos-inf sentinel

export interface MarketParams {
  tickSize: number; // USD per tick (raw_strike = tick * tick_size)
  admissionTickSize: number; // USD; order ticks must sit on this coarser grid
  minEntryProbability: number; // e.g. 0.01
  maxEntryProbability: number; // e.g. 0.99
  lotSize: number; // raw quantity lot (constants::position_lot_size = 10_000)
}

export interface Snapshot {
  pythSpot: number;
  bsSpot: number;
  bsForward: number;
  svi: Svi;
}

export interface Instruction {
  direction: "UP" | "DN";
  targetProbability: number; // e.g. 0.05 for "~5c"
  spendUsd: number; // net-premium budget that sizes the quantity
}

export interface Resolved {
  feasible: boolean;
  reason?: string;
  strikeUsd: number;
  predictedProbability: number;
  quantity: bigint; // USDC-scaled (1e6), lot-rounded
  maxProbability1e9: bigint; // per-contract probability cap (quoted p + slack), 1e9-scaled
  maxCost: bigint; // all-in USDC withdrawal cap (spend + headroom), 1e6-scaled
}


/** Find the strike (USD) whose directional probability ≈ target, snapped to the admission grid. */
function searchStrike(snap: Snapshot, forward: number, isUp: boolean, target: number, mkt: MarketParams): number {
  // Probability is monotonic in strike (UP decreasing, DN increasing); bisect in
  // log-space since strikes span orders of magnitude.
  let lo = forward * 1e-4;
  let hi = forward * 1e4;
  for (let i = 0; i < 100; i++) {
    const mid = Math.sqrt(lo * hi);
    const p = directionProbability(snap.svi, forward, mid, isUp);
    const needHigherStrike = isUp ? p > target : p < target;
    if (needHigherStrike) lo = mid;
    else hi = mid;
  }
  const raw = Math.sqrt(lo * hi);
  const mult = Math.max(1, Math.round(mkt.admissionTickSize / mkt.tickSize));
  let tick = Math.round(raw / mkt.tickSize / mult) * mult;
  tick = Math.min(Math.max(tick, mult), POS_INF_TICK - 1);
  return tick;
}

export function resolveMint(inst: Instruction, snap: Snapshot, mkt: MarketParams): Resolved {
  const lot = mkt.lotSize;
  const forward = forwardPrice(snap.pythSpot, snap.bsSpot, snap.bsForward);
  const isUp = inst.direction === "UP";

  const strikeTick = searchStrike(snap, forward, isUp, inst.targetProbability, mkt);
  const strikeUsd = strikeTick * mkt.tickSize;
  const p = directionProbability(snap.svi, forward, strikeUsd, isUp);

  const reasons: string[] = [];
  if (p < mkt.minEntryProbability || p > mkt.maxEntryProbability)
    reasons.push(`p=${p.toFixed(4)} outside [${mkt.minEntryProbability}, ${mkt.maxEntryProbability}]`);

  // quantity (USDC max-payout units) = spend / p; lot-round down so
  // net_premium <= spend. USDC-scaled (1e6), matching the on-chain payout/cash unit.
  const qtyRaw = Math.floor((inst.spendUsd / p) * USDC_DECIMALS / lot) * lot;
  if (qtyRaw < lot) reasons.push("sized quantity below one lot");

  return {
    feasible: reasons.length === 0,
    reason: reasons.join("; ") || undefined,
    strikeUsd,
    predictedProbability: p,
    quantity: BigInt(Math.max(qtyRaw, 0)),
    maxProbability1e9: BigInt(Math.min(SCALE, Math.round(p * PROB_SLACK * SCALE))),
    maxCost: BigInt(Math.round(inst.spendUsd * COST_SLACK * USDC_DECIMALS)),
  };
}
