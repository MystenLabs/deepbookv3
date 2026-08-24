// Off-chain replica of the on-chain 1% invert.
//
// The first charged mint inverts the live surface on-chain and stores the 99
// interior `strike / forward` ratios, 1e9-scaled. Later quotes rematerialize
// those ratios against the live forward. This module is the float twin of that
// invert, used by simulations and analysis rather than submitted to the chain.
//
// Submitting ratios rather than absolute prices is what makes the cut operable at
// all. Pricing reads a strike only as `ln(strike) - ln(forward)`, so a bucket's mass
// is a function of these ratios alone and is unchanged by anything spot does between
// this generator pricing the surface and the transaction executing. An absolute
// ladder has no such property: an equal-mass bucket is roughly two basis points of
// the forward wide, so a quarter of a basis point of drift already pushes a bucket
// out of tolerance, and spot covers that in well under a second.
//
// The remaining error is float-vs-fixed-point disagreement plus the SVI roll-down
// over the submission delay. Scoring float-derived ratios with the contract-faithful
// fixed-point mirror in `simulations/python_replay.py` puts the worst bucket-mass
// error at a couple of hundred raw at zero delay and around 3.3e3 per second of
// delay thereafter, so a cut has tens of seconds of budget against the 1e5
// tolerance. That is why this reuses the float `pricer.ts` port instead of carrying
// a second fixed-point implementation.
import { type Svi, upPrice } from "./pricer.js";

// Bucket count mirroring `inventory_grid`. The contract owns the open-end sentinels
// and requires exactly `bucket_count - 1` interior ratios.
export const GRID_BUCKETS = 100;
const RATIO_SCALE = 1_000_000_000;

// Log-space bisection halves the bracket each pass, so 80 passes over a 1e-4..1e4
// multiple of the forward drive the interval below double precision. The whole
// ladder is ~8k float evaluations, which is free next to the RPC round trip.
const BISECTION_PASSES = 80;
const BRACKET_MULTIPLE = 1e4;

// Strike whose UP price is `target`. `upPrice` is monotonically decreasing in
// strike, so a midpoint priced above the target means the strike is still too
// low. Bisection is geometric because the surface is parameterized in
// log-moneyness.
function strikeAtUpPrice(svi: Svi, forward: number, target: number): number {
  let low = forward / BRACKET_MULTIPLE;
  let high = forward * BRACKET_MULTIPLE;
  for (let pass = 0; pass < BISECTION_PASSES; pass += 1) {
    const mid = Math.sqrt(low * high);
    if (upPrice(svi, forward, mid) > target) low = mid;
    else high = mid;
  }
  return Math.sqrt(low * high);
}

/**
 * The 99 interior boundaries cutting `svi`/`forward` into 100 equal-mass buckets,
 * as 1e9-scaled multiples of the forward, or null if the surface is degenerate.
 *
 * Returns null rather than throwing so a caller can skip a degenerate surface:
 * as remaining time goes to zero the distribution collapses onto the forward
 * and adjacent quantiles round to the same ratio, which the contract rejects
 * as a non-increasing boundary.
 */
export function gridBoundaries(svi: Svi, forward: number): bigint[] | null {
  if (!Number.isFinite(forward) || forward <= 0) return null;
  const ratios: bigint[] = [];
  for (let index = 1; index < GRID_BUCKETS; index += 1) {
    // Bucket i is `(boundaries[i], boundaries[i + 1]]` and UP price is a
    // survival function, so the boundary closing the i-th percentile from below
    // is the strike with `1 - i/100` of the mass above it.
    const strike = strikeAtUpPrice(svi, forward, 1 - index / GRID_BUCKETS);
    if (!Number.isFinite(strike) || strike <= 0) return null;
    const ratio = BigInt(Math.round((strike / forward) * RATIO_SCALE));
    if (ratio <= 0n) return null;
    if (ratios.length > 0 && ratio <= ratios[ratios.length - 1]) return null;
    ratios.push(ratio);
  }
  return ratios;
}
