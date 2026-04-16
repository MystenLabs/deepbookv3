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
  // UTC 08:00 boundary. Always returns next calendar day at 08:00 UTC.
  const d = new Date(now);
  const midnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  const tomorrowAt8 = midnight + MS_DAY + 8 * MS_HOUR;
  return tomorrowAt8;
}

function next1w(now: number): number {
  // Friday = 5 (Sun=0). Target = next Friday 08:00 UTC strictly after `now`,
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

export function expectedExpiriesForTier(tier: Tier, now: number): number[] {
  const first = nextOf(tier, now);
  const dt = step(tier);
  return [first, first + dt, first + 2 * dt, first + 3 * dt];
}

export function expectedExpirySet(tiers: Tier[], now: number): Map<Tier, number[]> {
  const out = new Map<Tier, number[]>();
  for (const t of tiers) out.set(t, expectedExpiriesForTier(t, now));
  return out;
}
