import { rollDownSvi } from "./pricer.js";
import { PRICING_DEFAULTS } from "./predictConfig.js";

export interface Snap {
  spot1e9: string;
  bsSpot1e9: string;
  pythSourceTimestampMs: string;
  bsSpotSourceTimestampMs: number;
  expiries: Record<string, {
    forward: number;
    forwardSourceTimestampMs: number;
    sviSourceTimestampMs: number;
    svi: { alpha: number; beta: number; rho: number; m: number; sigma: number };
  }>;
}

function sourceIsFresh(sourceTimestampMs: number, nowMs: number, freshnessMs: number): boolean {
  return Number.isFinite(sourceTimestampMs) &&
    sourceTimestampMs > 0 &&
    sourceTimestampMs <= nowMs &&
    nowMs - sourceTimestampMs <= freshnessMs;
}

export function pricingEnvFromSnapshot(
  snap: Snap,
  expiryMs: number,
  nowMs: number,
): { pythSpot: number; bsSpot: number; bsForward: number; svi: any } | null {
  const exp = snap.expiries?.[String(expiryMs)];
  const pythSourceTimestampMs = Number(snap.pythSourceTimestampMs);
  if (
    !exp ||
    !sourceIsFresh(
      snap.bsSpotSourceTimestampMs,
      nowMs,
      PRICING_DEFAULTS.blockScholesPriceFreshnessMs,
    ) ||
    !sourceIsFresh(
      exp.forwardSourceTimestampMs,
      nowMs,
      PRICING_DEFAULTS.blockScholesPriceFreshnessMs,
    ) ||
    !sourceIsFresh(
      exp.sviSourceTimestampMs,
      nowMs,
      PRICING_DEFAULTS.blockScholesSviFreshnessMs,
    )
  ) return null;
  const bsSpot = Number(snap.bsSpot1e9) / 1e9;
  const rawSvi = {
    a: exp.svi.alpha,
    b: exp.svi.beta,
    rho: exp.svi.rho,
    m: exp.svi.m,
    sigma: exp.svi.sigma,
  };
  const svi = rollDownSvi(rawSvi, exp.sviSourceTimestampMs, expiryMs, nowMs);
  if (!svi) return null;
  const usePythSpot = PRICING_DEFAULTS.usePythSpotForForward && sourceIsFresh(
    pythSourceTimestampMs,
    nowMs,
    PRICING_DEFAULTS.pythSpotFreshnessMs,
  );
  return {
    // forwardPrice(pythSpot, bsSpot, bsForward) returns the direct BS forward when these spots
    // are equal, matching the contract's stale-Pyth fallback.
    pythSpot: usePythSpot ? Number(snap.spot1e9) / 1e9 : bsSpot,
    bsSpot,
    bsForward: Number(exp.forward),
    svi,
  };
}
