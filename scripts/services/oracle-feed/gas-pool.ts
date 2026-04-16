// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { Lane, LaneState } from "./types";

const SUI_TO_MIST = 1_000_000_000;

export function newLaneState(lanes: Lane[]): LaneState {
  return { lanes, nextHint: 0 };
}

function laneHasMinBalance(lane: Lane, minSui: number): boolean {
  return lane.gasCoinBalanceApproxMist >= minSui * SUI_TO_MIST;
}

export function nextAvailableLane(state: LaneState, minSui: number): Lane | undefined {
  const n = state.lanes.length;
  for (let i = 0; i < n; i++) {
    const idx = (state.nextHint + i) % n;
    const lane = state.lanes[idx];
    if (lane.available && laneHasMinBalance(lane, minSui)) {
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

export function totalPoolSui(state: LaneState): number {
  let totalMist = 0;
  for (const lane of state.lanes) totalMist += lane.gasCoinBalanceApproxMist;
  return totalMist / SUI_TO_MIST;
}
