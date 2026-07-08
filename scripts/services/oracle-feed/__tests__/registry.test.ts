import { describe, expect, it, vi } from "vitest";
import { bcs } from "@mysten/sui/bcs";
import {
  classifyStatus,
  fetchCompactedOracleIds,
  parseOracleObject,
} from "../registry";

function objectId(suffix: string): string {
  return `0x${suffix.padStart(64, "0")}`;
}

const silentLog = {
  info() {},
  warn() {},
  error() {},
  fatal() {},
} as any;

describe("parseOracleObject", () => {
  it("reads settlement_price when showContent returns it as a flat string", () => {
    const parsed = parseOracleObject({
      data: {
        objectId: "0xoracle",
        content: {
          dataType: "moveObject",
          fields: {
            underlying_asset: "BTC",
            expiry: "1776384000000",
            active: false,
            settlement_price: "75092327660000",
            authorized_caps: {
              fields: {
                contents: ["0xcap"],
              },
            },
          },
        },
      },
    });

    expect(parsed).toMatchObject({
      oracleId: "0xoracle",
      underlying: "BTC",
      expiryMs: 1776384000000,
      active: false,
      settlementPriceOpt: 75092327660000,
      authorizedCaps: ["0xcap"],
    });
  });
});

describe("classifyStatus", () => {
  it("returns 'compacted' when isCompacted is true, overriding settlement_price", () => {
    // settlement_price is set AND already compacted — compacted wins.
    expect(classifyStatus(false, 1_000, 75_092_327_660_000, true, 5_000)).toBe(
      "compacted",
    );
  });

  it("returns 'settled' when settlement_price is set and not yet compacted", () => {
    expect(classifyStatus(false, 1_000, 75_092_327_660_000, false, 5_000)).toBe(
      "settled",
    );
  });

  it("returns 'pending_settlement' when past expiry without settlement_price", () => {
    expect(classifyStatus(true, 4_000, null, false, 5_000)).toBe(
      "pending_settlement",
    );
  });

  it("returns 'inactive' when not active, pre-expiry, no settlement", () => {
    expect(classifyStatus(false, 10_000, null, false, 5_000)).toBe("inactive");
  });

  it("returns 'active' on the happy path", () => {
    expect(classifyStatus(true, 10_000, null, false, 5_000)).toBe("active");
  });
});

describe("fetchCompactedOracleIds", () => {
  it("returns all settled_oracle ids across a paginated table", async () => {
    const client = {
      getObject: vi.fn(async () => ({
        json: {
          vault: {
            settled_oracles: {
              id: objectId("51"),
            },
          },
        },
      })),
      listDynamicFields: vi.fn(async ({ cursor }: { cursor: string | null }) => {
        if (cursor === null) {
          return {
            dynamicFields: [
              { name: { bcs: bcs.Address.serialize(objectId("1")).toBytes() } },
              { name: { bcs: bcs.Address.serialize(objectId("2")).toBytes() } },
            ],
            hasNextPage: true,
            cursor: "page2",
          };
        }
        return {
          dynamicFields: [{ name: { bcs: bcs.Address.serialize(objectId("3")).toBytes() } }],
          hasNextPage: false,
          cursor: null,
        };
      }),
    } as any;

    const ids = await fetchCompactedOracleIds(client, "0xpredict", silentLog);

    expect(ids).toEqual(new Set([objectId("1"), objectId("2"), objectId("3")]));
    expect(client.getObject).toHaveBeenCalledTimes(1);
    expect(client.listDynamicFields).toHaveBeenCalledTimes(2);
  });

  it("returns an empty set when the Predict object has no moveObject content", async () => {
    const client = {
      getObject: vi.fn(async () => ({ json: null })),
      listDynamicFields: vi.fn(),
    } as any;

    const ids = await fetchCompactedOracleIds(client, "0xpredict", silentLog);

    expect(ids.size).toBe(0);
    expect(client.listDynamicFields).not.toHaveBeenCalled();
  });

  it("returns an empty set when getObject rejects, does not throw", async () => {
    const client = {
      getObject: vi.fn(async () => {
        throw new Error("rpc down");
      }),
      listDynamicFields: vi.fn(),
    } as any;

    const ids = await fetchCompactedOracleIds(client, "0xpredict", silentLog);

    expect(ids.size).toBe(0);
    expect(client.listDynamicFields).not.toHaveBeenCalled();
  });

  it("returns an empty set when the settled_oracles table id is missing", async () => {
    const client = {
      getObject: vi.fn(async () => ({
        json: { vault: {} },
      })),
      listDynamicFields: vi.fn(),
    } as any;

    const ids = await fetchCompactedOracleIds(client, "0xpredict", silentLog);

    expect(ids.size).toBe(0);
    expect(client.listDynamicFields).not.toHaveBeenCalled();
  });
});
