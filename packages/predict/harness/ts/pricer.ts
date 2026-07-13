// Off-chain port of deepbook_predict::pricing (compute_nd2 / range_price).
//
// Float, not fixed-point: a small drift from the contract's normal_cdf/exp is
// accepted by design (the semantic instruction targets an approximate price, and
// the predicted-vs-actual gap is itself a useful slippage signal). We mirror the
// on-chain SVI total-variance Black-Scholes tail exactly in form, so the strike we
// pick yields ~the target probability and the mint's max_probability guard passes.
//
//   k    = ln(strike / forward)
//   w(k) = a + b·(rho·(k-m) + sqrt((k-m)^2 + sigma^2))   // SVI total variance
//   d2   = -((k + w/2) / sqrt(w))
//   up_price(strike) = Phi(d2)                            // P(settle > strike)

export interface Svi {
  a: number; // SVI alpha
  b: number; // SVI beta
  rho: number; // signed
  m: number; // signed
  sigma: number;
}

// Standard normal CDF via erf (Abramowitz-Stegun 7.1.26, |err| < 1.5e-7).
export function normalCdf(x: number): number {
  return 0.5 * (1 + erf(x / Math.SQRT2));
}

function erf(x: number): number {
  const sign = x >= 0 ? 1 : -1;
  const ax = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * ax);
  const y =
    1 -
    ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
      t *
      Math.exp(-ax * ax);
  return sign * y;
}

/** Forward the contract prices against: pyth spot re-anchored by the BS basis. */
export function forwardPrice(pythSpot: number, bsSpot: number, bsForward: number): number {
  if (pythSpot > 0 && bsSpot > 0) return pythSpot * (bsForward / bsSpot);
  return bsForward;
}

/** P(settle > strike) — the UP tail. forward and strike in the same units (USD). */
export function upPrice(svi: Svi, forward: number, strike: number): number {
  if (strike <= 0) return 1; // neg-inf limit
  const k = Math.log(strike / forward);
  const km = k - svi.m;
  const w = svi.a + svi.b * (svi.rho * km + Math.sqrt(km * km + svi.sigma * svi.sigma));
  if (w <= 0) return k < 0 ? 1 : 0; // degenerate variance → tail limit
  const d2 = -((k + w / 2) / Math.sqrt(w));
  return normalCdf(d2);
}

/** Probability of a binary order in a direction at `strike`: UP = P(>strike), DOWN = P(<strike). */
export function directionProbability(svi: Svi, forward: number, strike: number, isUp: boolean): number {
  const up = upPrice(svi, forward, strike);
  return isUp ? up : 1 - up;
}
