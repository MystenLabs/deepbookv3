// The updater-maintained oracle snapshot and its mapping onto the pricing inputs
// the contract will use.
//
// Owned here rather than in the trader so strategy resolution prices against
// the same surface the chain does; a second copy of this derivation would drift.
import { readFileSync } from "node:fs";

import { forwardPrice, rollDownSvi } from "./pricer.js";
import { type Snapshot } from "./resolver.js";

/** `snapshot.json` as the updater writes it. */
export interface Snap {
  spot1e9: string;
  bsSpot1e9: string;
  publishedAtMs: string;
  expiries: Record<string, {
    forward: number;
    sviTsMs: number;
    svi: { alpha: number; beta: number; rho: number; m: number; sigma: number };
  }>;
}

export function readSnapshot(instanceDir: string): Snap | null {
  try {
    return JSON.parse(readFileSync(`${instanceDir}/snapshot.json`, "utf8"));
  } catch {
    return null;
  }
}

/**
 * The pricing inputs for one expiry, or null if the snapshot has no usable entry.
 *
 * Match load_live_pricer: use Block Scholes' own signed spot for the basis
 * re-anchor, then roll a/b from the ON-CHAIN batch envelope to this quote's
 * wall-clock time. The updater re-signs every push under its own clamped
 * envelope and writes it back as the snapshot's `publishedAtMs`, so that — not
 * the upstream provider's batch timestamp, which never reaches the chain — is
 * the anchor the contract will use. Using Pyth as both spots and leaving SVI at
 * its anchor made near-expiry max-probability guards reject otherwise valid
 * strategy quotes.
 */
export function pricerEnvFor(
  snap: Snap | null,
  expiryMs: number,
  pricingTimestampMs: number,
): Snapshot | null {
  const expiry = snap?.expiries?.[String(expiryMs)];
  if (!snap || !expiry) return null;
  const svi = rollDownSvi(
    {
      a: expiry.svi.alpha,
      b: expiry.svi.beta,
      rho: expiry.svi.rho,
      m: expiry.svi.m,
      sigma: expiry.svi.sigma,
    },
    Number(snap.publishedAtMs),
    expiryMs,
    pricingTimestampMs,
  );
  if (!svi) return null;
  return {
    pythSpot: Number(snap.spot1e9) / 1e9,
    bsSpot: Number(snap.bsSpot1e9) / 1e9,
    bsForward: Number(expiry.forward),
    svi,
  };
}

/** The forward the contract prices this expiry against. */
export function forwardFor(env: Snapshot): number {
  return forwardPrice(env.pythSpot, env.bsSpot, env.bsForward);
}
