import { describe, it, expect } from "vitest";
import type { Lane, LaneState } from "../types";
import {
  newLaneState,
  nextAvailableLane,
  releaseLane,
  laneEligibleForCreate,
  laneEligibleAtAll,
  poolStats,
} from "../gas-pool";

const SUI = 1_000_000_000;

function makeLane(i: number, balanceSui: number, available = true): Lane {
  return {
    id: i,
    gasCoinId: `0xg${i}`,
    gasCoinVersion: "",
    gasCoinDigest: "",
    gasCoinBalanceApproxMist: balanceSui * SUI,
    capId: `0xc${i}`,
    available,
    lastTxDigest: null,
  };
}

function makeState(lanes: Lane[]): LaneState {
  return { lanes, nextHint: 0 };
}

describe("gas-pool", () => {
  it("nextAvailableLane returns the first available lane from hint", () => {
    const s = makeState([makeLane(0, 30, false), makeLane(1, 30), makeLane(2, 30)]);
    expect(nextAvailableLane(s, 1)?.id).toBe(1);
  });

  it("nextAvailableLane wraps around", () => {
    const s = makeState([makeLane(0, 30), makeLane(1, 30, false)]);
    s.nextHint = 1;
    expect(nextAvailableLane(s, 1)?.id).toBe(0);
  });

  it("nextAvailableLane returns undefined when all in flight", () => {
    const s = makeState([makeLane(0, 30, false), makeLane(1, 30, false)]);
    expect(nextAvailableLane(s, 1)).toBeUndefined();
  });

  it("nextAvailableLane skips lanes below min threshold entirely", () => {
    const s = makeState([makeLane(0, 0.5), makeLane(1, 30)]);
    expect(nextAvailableLane(s, 1)?.id).toBe(1);
  });

  it("releaseLane marks available and updates digest", () => {
    const lane = makeLane(0, 30);
    lane.available = false;
    releaseLane(lane, "digest1");
    expect(lane.available).toBe(true);
    expect(lane.lastTxDigest).toBe("digest1");
  });

  it("laneEligibleForCreate excludes lanes below 5 SUI", () => {
    expect(laneEligibleForCreate(makeLane(0, 4), 5)).toBe(false);
    expect(laneEligibleForCreate(makeLane(0, 5), 5)).toBe(true);
  });

  it("laneEligibleAtAll excludes lanes below 1 SUI", () => {
    expect(laneEligibleAtAll(makeLane(0, 0.5), 1)).toBe(false);
    expect(laneEligibleAtAll(makeLane(0, 1), 1)).toBe(true);
  });

  it("poolStats reports totals and low-lane counts", () => {
    const s = makeState([makeLane(0, 30), makeLane(1, 4), makeLane(2, 0.5)]);
    const st = poolStats(s, 5, 1);
    expect(st.totalSui).toBe(30 + 4 + 0.5);
    expect(st.belowCreateReserve).toBe(2);   // lanes 1 and 2
    expect(st.belowMin).toBe(1);              // lane 2
  });
});
