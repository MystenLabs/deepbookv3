// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { Tier } from "./types";

const MS_MIN = 60_000;
const MS_HOUR = 60 * MS_MIN;
const MS_DAY = 24 * MS_HOUR;

function next15m(now: number): number {
  const quarter = 15 * MS_MIN;
  return Math.floor(now / quarter) * quarter + quarter;
}

function next1h(now: number): number {
  return Math.floor(now / MS_HOUR) * MS_HOUR + MS_HOUR;
}

function next1d(now: number): number {
  // UTC 08:00 boundary. Returns today-or-tomorrow at 08:00 UTC strictly after now.
  const d = new Date(now);
  const midnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  const todayAt8 = midnight + 8 * MS_HOUR;
  if (todayAt8 > now) return todayAt8;
  return midnight + MS_DAY + 8 * MS_HOUR;
}

function next1w(now: number): number {
  // Friday = 5 (Sun=0). Target = next Friday 08:00 UTC strictly after now,
  // except when today is Friday and now is before 08:00 UTC.
  const d = new Date(now);
  const dow = d.getUTCDay();
  const midnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  const todayAt8 = midnight + 8 * MS_HOUR;
  if (dow === 5 && todayAt8 > now) return todayAt8;
  const daysUntilFriday = (5 - dow + 7) % 7 || 7;
  return midnight + daysUntilFriday * MS_DAY + 8 * MS_HOUR;
}

function nextOf(tier: Tier, t: number): number {
  switch (tier) {
    case "15m": return next15m(t);
    case "1h":  return next1h(t);
    case "1d":  return next1d(t);
    case "1w":  return next1w(t);
  }
}

function step(tier: Tier): number {
  switch (tier) {
    case "15m": return 15 * MS_MIN;
    case "1h":  return MS_HOUR;
    case "1d":  return MS_DAY;
    case "1w":  return 7 * MS_DAY;
  }
}

/// Return the next `count` expiries for a tier, strictly in the future from
/// `now + minLookaheadMs`. The lookahead floor exists so the first-rotated
/// expiry is far enough out that BlockScholes's mark.px feed accepts the
/// subscription (their server rejects near-term expiries).
export function expectedExpiriesForTier(
  tier: Tier,
  now: number,
  count: number,
  minLookaheadMs: number,
): number[] {
  const first = nextOf(tier, now + minLookaheadMs);
  const dt = step(tier);
  const out: number[] = [];
  for (let i = 0; i < count; i++) out.push(first + i * dt);
  return out;
}

export function expectedExpirySet(
  tiers: Tier[],
  count: number,
  minLookaheadMs: number,
  now: number,
): Map<Tier, number[]> {
  const out = new Map<Tier, number[]>();
  for (const t of tiers) out.set(t, expectedExpiriesForTier(t, now, count, minLookaheadMs));
  return out;
}

/// Best-effort tier classification for an already-existing oracle. Used to
/// slot discovered on-chain oracles into the rotation registry on startup.
/// Returns undefined if the expiry doesn't land on any tier's schedule —
/// such oracles won't be tracked for rotation, and will naturally fall off
/// as they settle.
export function inferTier(expiryMs: number, enabledTiers: Tier[]): Tier | undefined {
  const d = new Date(expiryMs);
  const dow = d.getUTCDay();
  const sec = d.getUTCSeconds();
  const ms = d.getUTCMilliseconds();
  if (sec !== 0 || ms !== 0) return undefined;

  if (enabledTiers.includes("1w") && dow === 5 && d.getUTCHours() === 8 && d.getUTCMinutes() === 0) {
    return "1w";
  }
  if (enabledTiers.includes("1d") && d.getUTCHours() === 8 && d.getUTCMinutes() === 0) {
    return "1d";
  }
  if (enabledTiers.includes("1h") && d.getUTCMinutes() === 0) {
    return "1h";
  }
  if (enabledTiers.includes("15m") && d.getUTCMinutes() % 15 === 0) {
    return "15m";
  }
  return undefined;
}
