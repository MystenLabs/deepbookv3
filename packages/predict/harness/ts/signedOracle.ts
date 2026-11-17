// Version 6 signed oracle data from the updater's landed snapshot. Predict reads no Propbook
// object, so the keeper and the traders sign the Block Scholes values each call needs, from the
// latest snapshot the updater published after its refresh landed (snapshot.json). The local
// signer stamps them at the instant the call names, so this module keeps the provider's own
// timing: the spot is the one observed with the forward, an observation too old for the instant
// is refused, and the SVI is rolled from its source time to the instant it is stamped at.

import { readFileSync } from "node:fs";

import { type SignedOracle } from "../../devtools/ts/runtime.js";
import { type LandedMarketSnapshot, landedSnapshotFrom } from "./marketSource.js";
import { PRICING_DEFAULTS } from "./predictConfig.js";

// The latest landed snapshot for `expiries`, or null before the updater's first push.
export function readLandedSnapshot(instanceDir: string, expiries: number[]): LandedMarketSnapshot | null {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(`${instanceDir}/snapshot.json`, "utf8"));
  } catch {
    return null;
  }
  return landedSnapshotFrom(raw, expiries);
}

// An observation is too old once it is more than `maxAgeMs` before the instant it is stamped at.
// A newer one (the snapshot moved on after a τ) is accepted.
function recentEnough(sourceMs: number, atMs: number, maxAgeMs: number): boolean {
  return sourceMs > 0 && atMs - sourceMs <= maxAgeMs;
}

// The SVI time scaling Predict applies on chain (`a` and `b` by the ratio of the remaining times
// to expiry), from the provider's source time to the instant the tuple is stamped at. Null at or
// past expiry. The result is floored at the localnet binding's 9 decimals, the precision a
// provider signing a fresh tuple at that instant would publish, so it can sit one unit below the
// chain's own 18-decimal roll of the older tuple.
export function rollSvi1e9(
  svi: SignedOracle["svi"],
  sourceMs: number,
  expiryMs: number,
  atMs: number,
): SignedOracle["svi"] | null {
  const anchor = BigInt(expiryMs - sourceMs);
  const remaining = BigInt(expiryMs - atMs);
  if (anchor <= 0n || remaining <= 0n) return null;
  return { ...svi, a: (svi.a * remaining) / anchor, b: (svi.b * remaining) / anchor };
}

// One expiry's Block Scholes values to sign with the spot and forward stamped at `valueAtMs` and
// the SVI at `sviAtMs`. Null when the snapshot has no row for the expiry, nothing has landed for a
// series yet (a landed snapshot carries zeros), no retained spot shares the forward's source time,
// or an observation is older than the pricing freshness windows allow.
export function signedOracleFor(
  snapshot: LandedMarketSnapshot,
  expiryMs: number,
  valueAtMs: number,
  sviAtMs: number,
): SignedOracle | null {
  const entry = snapshot.expiries.get(expiryMs);
  if (!entry || entry.forward1e9 === 0n) return null;
  const spot = snapshot.bsSpotHistory.find(
    (read) => read.sourceTimestampMs === entry.forwardSourceTimestampMs,
  );
  if (!spot || spot.value1e9 === 0n) return null;
  if (
    !recentEnough(entry.forwardSourceTimestampMs, valueAtMs, PRICING_DEFAULTS.blockScholesPriceFreshnessMs) ||
    !recentEnough(entry.sviSourceTimestampMs, sviAtMs, PRICING_DEFAULTS.blockScholesSviFreshnessMs)
  ) {
    return null;
  }
  const svi = rollSvi1e9(entry.svi1e9, entry.sviSourceTimestampMs, expiryMs, sviAtMs);
  if (!svi) return null;
  return { bsSpot: spot.value1e9, forward: entry.forward1e9, svi };
}
