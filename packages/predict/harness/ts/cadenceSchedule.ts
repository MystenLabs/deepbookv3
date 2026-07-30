import { CADENCES, CADENCE_PERIOD_MS } from "./predictConfig.js";

export interface ScheduledMarket {
  expiryMs: number;
}

// Recover the owning cadence from an expiry for the enabled production set.
// Higher-rank cadences own overlapping boundaries.
export function cadenceOf(expiryMs: number): number {
  if (expiryMs % CADENCE_PERIOD_MS[2] === 0) return 2;
  if (expiryMs % CADENCE_PERIOD_MS[1] === 0) return 1;
  return 0;
}

// Mirror market_manager::next_deployable_market closely enough to avoid
// submitting a guaranteed ECadenceWindowExceeded transaction.
export function nextDeployableExpiry(
  live: ScheduledMarket[],
  cadenceId: number,
  nowMs: number,
  enabledCadenceIds: number[],
): number | null {
  const periodMs = CADENCE_PERIOD_MS[cadenceId];
  const windowSize = Number(CADENCES[cadenceId].windowSize);
  const lastActive = live
    .filter((market) => cadenceOf(market.expiryMs) === cadenceId)
    .reduce((max, market) => Math.max(max, market.expiryMs), 0);
  const nextFuture = (Math.floor(nowMs / periodMs) + 1) * periodMs;
  let candidate = Math.max(lastActive + periodMs, nextFuture);
  const windowEnd = nowMs + windowSize * periodMs;
  const existing = new Set(live.map((market) => market.expiryMs));

  while (candidate <= windowEnd) {
    const reservedByHigherCadence = enabledCadenceIds.some(
      (higherId) =>
        higherId > cadenceId &&
        Number(CADENCES[higherId].windowSize) > 0 &&
        candidate % CADENCE_PERIOD_MS[higherId] === 0,
    );
    if (!reservedByHigherCadence && !existing.has(candidate)) return candidate;
    candidate += periodMs;
  }
  return null;
}
