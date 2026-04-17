import { describe, expect, it } from "vitest";
import { hasFreshPriceSample, shouldRunManagerWindowNow, waitForAllLanesIdle } from "../executor";
import type { Lane, OracleState, PriceSample, ServiceState } from "../types";

function lane(available: boolean): Lane {
  return {
    id: 0,
    gasCoinId: "0xgas",
    gasCoinVersion: "1",
    gasCoinDigest: "digest",
    capId: "0xcap",
    available,
  };
}

function oracle(overrides: Partial<OracleState> = {}): OracleState {
  return {
    id: "0xoracle",
    underlying: "BTC",
    expiryMs: 10_000,
    tier: "15m",
    status: "active",
    registeredCapIds: new Set(),
    ...overrides,
  };
}

function state(oracles: OracleState[]): ServiceState {
  return {
    oracles: new Map(oracles.map((item) => [item.id, item])),
    lanes: [lane(true)],
    capIds: ["0xcap"],
    priceCache: { spot: null, forwards: new Map() },
    sviCache: new Map(),
    managerInFlight: false,
    laneHint: 0,
    lastPushMs: 0,
  };
}

describe("hasFreshPriceSample", () => {
  it("returns false for stale spot data", () => {
    const spot: PriceSample = { value: 1, receivedAtMs: 1_000 };
    expect(hasFreshPriceSample(spot, 5_500, 3_000)).toBe(false);
  });

  it("returns true for fresh spot data", () => {
    const spot: PriceSample = { value: 1, receivedAtMs: 3_000 };
    expect(hasFreshPriceSample(spot, 5_500, 3_000)).toBe(true);
  });
});

describe("waitForAllLanesIdle", () => {
  it("rejects when a lane never drains", async () => {
    await expect(waitForAllLanesIdle([lane(false)], 20, 1)).rejects.toThrow(
      "manager window timed out waiting for lanes to drain",
    );
  });

  it("resolves once every lane is available", async () => {
    await expect(waitForAllLanesIdle([lane(true)], 20, 1)).resolves.toBeUndefined();
  });
});

describe("shouldRunManagerWindowNow", () => {
  it("returns true when an inactive oracle already has svi cached", () => {
    const service = state([oracle({ status: "inactive" })]);
    service.sviCache.set("0xoracle", {
      params: { a: 1, b: 2, rho: 3, m: 4, sigma: 5 },
      receivedAtMs: 9_000,
      lastPushedAtMs: null,
    });

    expect(shouldRunManagerWindowNow(service, 9_500, 3_000)).toBe(true);
  });

  it("returns true when an active oracle reaches expiry", () => {
    const service = state([oracle({ status: "active", expiryMs: 9_000 })]);

    expect(shouldRunManagerWindowNow(service, 9_001, 3_000)).toBe(true);
  });

  it("returns false when no lifecycle step is ready", () => {
    const service = state([oracle({ status: "active", expiryMs: 10_000 })]);

    expect(shouldRunManagerWindowNow(service, 9_000, 3_000)).toBe(false);
  });
});
