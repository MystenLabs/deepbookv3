// Version 6 signed oracle data from the updater's landed snapshot. Predict reads no Propbook
// object, so the keeper and the traders sign the Block Scholes values each call needs, from the
// latest snapshot the updater published after its refresh landed (snapshot.json).

import { readFileSync } from "node:fs";

import { type SignedOracle } from "../../devtools/ts/runtime.js";
import { type MarketSnapshot, landedSnapshotFrom } from "./marketSource.js";

// The latest landed snapshot for `expiries`, or null before the updater's first push.
export function readLandedSnapshot(instanceDir: string, expiries: number[]): MarketSnapshot | null {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(`${instanceDir}/snapshot.json`, "utf8"));
  } catch {
    return null;
  }
  return landedSnapshotFrom(raw, expiries);
}

// One expiry's Block Scholes values from a snapshot, or null when the snapshot has none for it. A
// landed snapshot carries zeros for a series nothing has landed for yet, which no call accepts.
export function signedOracleFor(snapshot: MarketSnapshot, expiryMs: number): SignedOracle | null {
  const entry = snapshot.expiries.get(expiryMs);
  if (!entry || snapshot.bsSpot1e9 === 0n || entry.forward1e9 === 0n) return null;
  return { bsSpot: snapshot.bsSpot1e9, forward: entry.forward1e9, svi: entry.svi1e9 };
}
