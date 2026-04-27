import { describe, expect, it, vi } from "vitest";
import { assertSignerOwnsAdminCap, ensureCapsAndCoins, refreshGasLanesIfNeeded } from "../bootstrap";
import type { Lane } from "../types";

const SUI_TO_MIST = 1_000_000_000n;

function objectId(suffix: string): string {
  return `0x${suffix.padStart(64, "0")}`;
}

function coin(suffix: string, balanceSui: number, version = "1") {
  return {
    coinObjectId: objectId(suffix),
    balance: (BigInt(balanceSui) * SUI_TO_MIST).toString(),
    version,
    digest: `${suffix.padStart(32, "1")}`,
  };
}

function config(overrides: Record<string, unknown> = {}) {
  return {
    adminCapId: objectId("ad"),
    predictPackageId: objectId("e1"),
    laneCount: 2,
    gasPoolFloorSui: 20,
    gasLaneMinSui: 100,
    ...overrides,
  } as any;
}

function log() {
  return {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    fatal: vi.fn(),
  } as any;
}

describe("assertSignerOwnsAdminCap", () => {
  it("throws a clear error when the signer does not own the admin cap", async () => {
    const client = {
      getObject: async () => ({
        data: {
          owner: {
            AddressOwner: "0xadmin",
          },
        },
      }),
    } as any;

    await expect(
      assertSignerOwnsAdminCap(client, "0xsigner", "0xcap"),
    ).rejects.toThrow(
      "oracle-feed signer 0xsigner must own AdminCap 0xcap, but current owner is 0xadmin",
    );
  });
});

describe("ensureCapsAndCoins", () => {
  it("refreshes lanes when coin count equals lane count but a selected coin is below threshold", async () => {
    const signerAddress = objectId("d1");
    const caps = [objectId("c1"), objectId("c2")];
    const initialCoins = [coin("a1", 180), coin("a2", 1)];
    const refreshedCoins = [coin("b1", 90, "2"), coin("b2", 90, "2")];
    let refreshed = false;

    const client = {
      getObject: vi.fn(async () => ({
        data: { owner: { AddressOwner: signerAddress } },
      })),
      getOwnedObjects: vi.fn(async () => ({
        data: caps.map((capId) => ({ data: { objectId: capId } })),
        hasNextPage: false,
      })),
      getCoins: vi.fn(async () => ({
        data: refreshed ? refreshedCoins : initialCoins,
        hasNextPage: false,
      })),
      signAndExecuteTransaction: vi.fn(async () => {
        refreshed = true;
        return { digest: "0xdigest", effects: { status: { status: "success" } } };
      }),
      waitForTransaction: vi.fn(async () => undefined),
    } as any;

    const result = await ensureCapsAndCoins(
      client,
      { toSuiAddress: () => signerAddress } as any,
      config(),
      log(),
    );

    expect(client.signAndExecuteTransaction).toHaveBeenCalledTimes(1);
    expect(result.lanes.map((lane) => lane.capId)).toEqual(caps);
    expect(result.lanes.map((lane) => lane.gasCoinId)).toEqual([
      objectId("b1"),
      objectId("b2"),
    ]);
    expect(result.lanes.map((lane) => lane.gasCoinVersion)).toEqual(["2", "2"]);
  });
});

describe("refreshGasLanesIfNeeded", () => {
  it("preserves lane cap IDs while replacing refreshed gas coin refs", async () => {
    const signerAddress = objectId("d1");
    const lanes: Lane[] = [
      {
        id: 0,
        gasCoinId: objectId("a1"),
        gasCoinVersion: "1",
        gasCoinDigest: "11111111111111111111111111111111",
        capId: objectId("c1"),
        available: true,
      },
      {
        id: 1,
        gasCoinId: objectId("a2"),
        gasCoinVersion: "1",
        gasCoinDigest: "22222222222222222222222222222222",
        capId: objectId("c2"),
        available: true,
      },
    ];
    const initialCoins = [coin("a1", 1), coin("a2", 220)];
    const refreshedCoins = [coin("b1", 110, "2"), coin("b2", 109, "2")];
    let refreshed = false;

    const client = {
      getCoins: vi.fn(async () => ({
        data: refreshed ? refreshedCoins : initialCoins,
        hasNextPage: false,
      })),
      signAndExecuteTransaction: vi.fn(async () => {
        refreshed = true;
        return { digest: "0xdigest", effects: { status: { status: "success" } } };
      }),
      waitForTransaction: vi.fn(async () => undefined),
    } as any;

    await expect(
      refreshGasLanesIfNeeded(
        client,
        { toSuiAddress: () => signerAddress } as any,
        config(),
        lanes,
        log(),
      ),
    ).resolves.toBe(true);

    expect(lanes.map((lane) => lane.capId)).toEqual([objectId("c1"), objectId("c2")]);
    expect(lanes.map((lane) => lane.gasCoinId)).toEqual([objectId("b1"), objectId("b2")]);
    expect(lanes.map((lane) => lane.gasCoinVersion)).toEqual(["2", "2"]);
  });

  it("does not refresh when all lane coins are above threshold", async () => {
    const signerAddress = objectId("d1");
    const lanes: Lane[] = [
      {
        id: 0,
        gasCoinId: objectId("a1"),
        gasCoinVersion: "1",
        gasCoinDigest: "11111111111111111111111111111111",
        capId: objectId("c1"),
        available: true,
      },
      {
        id: 1,
        gasCoinId: objectId("a2"),
        gasCoinVersion: "1",
        gasCoinDigest: "22222222222222222222222222222222",
        capId: objectId("c2"),
        available: true,
      },
    ];
    const client = {
      getCoins: vi.fn(async () => ({
        data: [coin("a1", 150), coin("a2", 120)],
        hasNextPage: false,
      })),
      signAndExecuteTransaction: vi.fn(),
      waitForTransaction: vi.fn(),
    } as any;

    await expect(
      refreshGasLanesIfNeeded(
        client,
        { toSuiAddress: () => signerAddress } as any,
        config(),
        lanes,
        log(),
      ),
    ).resolves.toBe(false);

    expect(client.signAndExecuteTransaction).not.toHaveBeenCalled();
    expect(lanes.map((lane) => lane.gasCoinId)).toEqual([objectId("a1"), objectId("a2")]);
  });
});
