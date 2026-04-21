import { afterEach, describe, expect, it, vi } from "vitest";
import { discoverOracles } from "../registry";
import {
  hasFreshPriceSample,
  pushTick,
  runManagerWindow,
  shouldRunManagerWindowNow,
  waitForAllLanesIdle,
} from "../executor";
import type { Lane, OracleState, PriceSample, ServiceState } from "../types";

vi.mock("../registry", () => ({
  discoverOracles: vi.fn(),
}));

function lane(available: boolean): Lane {
  return {
    id: 0,
    gasCoinId: "0x00000000000000000000000000000000000000000000000000000000000000a1",
    gasCoinVersion: "1",
    gasCoinDigest: "11111111111111111111111111111111",
    capId: "0x00000000000000000000000000000000000000000000000000000000000000c1",
    available,
  };
}

function oracle(overrides: Partial<OracleState> = {}): OracleState {
  return {
    id: "0x00000000000000000000000000000000000000000000000000000000000000b1",
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
    capIds: ["0x00000000000000000000000000000000000000000000000000000000000000c1"],
    priceCache: { spot: null, forwards: new Map() },
    sviCache: new Map(),
    managerInFlight: false,
    laneHint: 0,
    lastPushMs: 0,
  };
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.mocked(discoverOracles).mockReset();
});

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
    service.sviCache.set("0x00000000000000000000000000000000000000000000000000000000000000b1", {
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

  it("returns true when an oracle is settled but not yet compacted", () => {
    const service = state([oracle({ status: "settled" })]);

    expect(shouldRunManagerWindowNow(service, 9_000, 3_000)).toBe(true);
  });

  it("returns false for an already-compacted oracle (no further manager work)", () => {
    const service = state([oracle({ status: "compacted" })]);

    expect(shouldRunManagerWindowNow(service, 9_000, 3_000)).toBe(false);
  });
});

describe("runManagerWindow", () => {
  it("does not create a duplicate oracle when another tier already owns the same expiry", async () => {
    const sharedExpiryMs = Date.parse("2026-04-17T16:00:00.000Z");
    vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-04-17T14:21:00.000Z"));
    vi.mocked(discoverOracles).mockResolvedValue(
      new Map([
        [
          "0xexisting",
          oracle({
            id: "0xexisting",
            expiryMs: sharedExpiryMs,
            tier: "1h",
            status: "active",
          }),
        ],
      ]),
    );

    const service = state([]);
    const client = {
      signAndExecuteTransaction: vi.fn(async () => ({
        digest: "0xdigest",
        effects: {
          status: { status: "success" },
          mutated: [{
            reference: {
              objectId: service.lanes[0]!.gasCoinId,
              version: "2",
              digest: "11111111111111111111111111111111",
            },
          }],
        },
        events: [],
      })),
      waitForTransaction: vi.fn(async () => undefined),
    } as any;
    const subscriber = {
      syncOracles: vi.fn(),
    } as any;

    await runManagerWindow(
      service,
      client,
      {
        toSuiAddress: () =>
          "0x00000000000000000000000000000000000000000000000000000000000000d1",
      } as any,
      {
        predictPackageId:
          "0x00000000000000000000000000000000000000000000000000000000000000e1",
        registryId:
          "0x00000000000000000000000000000000000000000000000000000000000000f1",
        predictId:
          "0x00000000000000000000000000000000000000000000000000000000000000f2",
        adminCapId:
          "0x00000000000000000000000000000000000000000000000000000000000000f3",
        tiersEnabled: ["15m", "1h"],
        expiriesPerTier: 1,
        minLookaheadMs: 90 * 60_000,
        underlying: "BTC",
        strikeMin: 50_000_000_000_000,
        tickSize: 1_000_000_000,
      } as any,
      subscriber,
      {
        info() {},
        warn() {},
        error() {},
        fatal() {},
      } as any,
    );

    expect(client.signAndExecuteTransaction).not.toHaveBeenCalled();
    expect(subscriber.syncOracles).toHaveBeenCalledTimes(1);
  });
});

describe("pushTick", () => {
  it("refreshes a stale lane gas coin ref after a preflight version error", async () => {
    const service = state([oracle({ expiryMs: Date.now() + 60_000 })]);
    service.priceCache.spot = { value: 100_000, receivedAtMs: Date.now() };
    service.priceCache.forwards.set(
      "0x00000000000000000000000000000000000000000000000000000000000000b1",
      { value: 100_100, receivedAtMs: Date.now() },
    );

    const staleError =
      "Error: Error checking transaction input objects: Transaction needs to be rebuilt " +
      "because object 0x00000000000000000000000000000000000000000000000000000000000000a1 " +
      "version 1 is unavailable for consumption, current version: 2";

    const client = {
      signAndExecuteTransaction: vi
        .fn()
        .mockRejectedValueOnce(new Error(staleError))
        .mockResolvedValueOnce({
          digest: "0xdigest",
          effects: {
            status: { status: "success" },
            mutated: [{
              reference: {
                objectId: "0x00000000000000000000000000000000000000000000000000000000000000a1",
                version: "3",
                digest: "33333333333333333333333333333333",
              },
            }],
          },
        }),
      getObject: vi.fn(async () => ({
        data: {
          objectId: "0x00000000000000000000000000000000000000000000000000000000000000a1",
          version: "2",
          digest: "22222222222222222222222222222222",
        },
      })),
      waitForTransaction: vi.fn(async () => undefined),
    } as any;

    await pushTick(
      service,
      client,
      { toSuiAddress: () => "0x00000000000000000000000000000000000000000000000000000000000000d1" } as any,
      {
        predictPackageId: "0x00000000000000000000000000000000000000000000000000000000000000e1",
        priceCacheStaleMs: 3_000,
        safetyWindowMs: 5_000,
      } as any,
      {
        info() {},
        warn() {},
        error() {},
        fatal() {},
      } as any,
    );

    expect(client.getObject).toHaveBeenCalledTimes(1);
    expect(service.lanes[0].gasCoinVersion).toBe("2");
    expect(service.lanes[0].gasCoinDigest).toBe("22222222222222222222222222222222");
    expect(service.lanes[0].available).toBe(true);

    await pushTick(
      service,
      client,
      { toSuiAddress: () => "0x00000000000000000000000000000000000000000000000000000000000000d1" } as any,
      {
        predictPackageId: "0x00000000000000000000000000000000000000000000000000000000000000e1",
        priceCacheStaleMs: 3_000,
        safetyWindowMs: 5_000,
      } as any,
      {
        info() {},
        warn() {},
        error() {},
        fatal() {},
      } as any,
    );

    expect(client.signAndExecuteTransaction).toHaveBeenCalledTimes(2);
    expect(service.lanes[0].gasCoinVersion).toBe("3");
  });

  it("keeps the lane busy until waitForTransaction resolves", async () => {
    const service = state([oracle({ expiryMs: Date.now() + 60_000 })]);
    service.priceCache.spot = { value: 100_000, receivedAtMs: Date.now() };
    service.priceCache.forwards.set(
      "0x00000000000000000000000000000000000000000000000000000000000000b1",
      { value: 100_100, receivedAtMs: Date.now() },
    );

    let releaseWait: (() => void) | null = null;
    const client = {
      signAndExecuteTransaction: async () => ({
        digest: "0xdigest",
        effects: {
          status: { status: "success" },
          mutated: [{
            reference: {
              objectId: "0x00000000000000000000000000000000000000000000000000000000000000a1",
              version: "2",
              digest: "11111111111111111111111111111111",
            },
          }],
        },
      }),
      waitForTransaction: async () => {
        await new Promise<void>((resolve) => {
          releaseWait = resolve;
        });
      },
    } as any;

    const pending = pushTick(
      service,
      client,
      { toSuiAddress: () => "0x00000000000000000000000000000000000000000000000000000000000000d1" } as any,
      {
        predictPackageId: "0x00000000000000000000000000000000000000000000000000000000000000e1",
        priceCacheStaleMs: 3_000,
        safetyWindowMs: 5_000,
      } as any,
      {
        info() {},
        warn() {},
        error() {},
        fatal() {},
      } as any,
    );

    await Promise.resolve();

    expect(service.lanes[0].available).toBe(false);

    releaseWait?.();
    await pending;

    expect(service.lanes[0].available).toBe(true);
    expect(service.lanes[0].gasCoinVersion).toBe("2");
  });
});
