import type { Lane, LaneState } from "./types";

const SUI_TO_MIST = 1_000_000_000;

export function newLaneState(lanes: Lane[]): LaneState {
  return { lanes, nextHint: 0 };
}

export function laneEligibleAtAll(lane: Lane, minSui: number): boolean {
  return lane.gasCoinBalanceApproxMist >= minSui * SUI_TO_MIST;
}

export function laneEligibleForCreate(lane: Lane, reserveSui: number): boolean {
  return lane.gasCoinBalanceApproxMist >= reserveSui * SUI_TO_MIST;
}

export function nextAvailableLane(state: LaneState, minSui: number): Lane | undefined {
  const n = state.lanes.length;
  for (let i = 0; i < n; i++) {
    const idx = (state.nextHint + i) % n;
    const lane = state.lanes[idx];
    if (lane.available && laneEligibleAtAll(lane, minSui)) {
      state.nextHint = (idx + 1) % n;
      return lane;
    }
  }
  return undefined;
}

export function releaseLane(lane: Lane, txDigest: string): void {
  lane.available = true;
  lane.lastTxDigest = txDigest;
}

export type PoolStats = {
  totalSui: number;
  belowCreateReserve: number;
  belowMin: number;
};

export function poolStats(state: LaneState, reserveSui: number, minSui: number): PoolStats {
  let totalMist = 0;
  let belowCreateReserve = 0;
  let belowMin = 0;
  for (const lane of state.lanes) {
    totalMist += lane.gasCoinBalanceApproxMist;
    if (!laneEligibleForCreate(lane, reserveSui)) belowCreateReserve++;
    if (!laneEligibleAtAll(lane, minSui)) belowMin++;
  }
  return {
    totalSui: totalMist / SUI_TO_MIST,
    belowCreateReserve,
    belowMin,
  };
}
