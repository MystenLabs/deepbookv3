import { describe, expect, it, vi } from "vitest";

import {
  formatQuoteBalance,
  readManagerQuoteBalance,
  readQuoteAssetMetadata,
  readWalletQuoteBalance,
} from "@/lib/sui/predict-balances";

describe("predict-balances", () => {
  it("reads wallet quote balance from client.getBalance()", async () => {
    const client = {
      getBalance: vi.fn().mockResolvedValue({
        balance: {
          balance: "125000000",
          coinBalance: "125000000",
          addressBalance: "125000000",
          coinType: "0x2::usd::USD",
        },
      }),
    };

    await expect(
      readWalletQuoteBalance(client as never, {
        owner: "0xowner",
        coinType: "0x2::usd::USD",
      }),
    ).resolves.toBe(125000000n);
  });

  it("reads a manager quote balance from the BalanceManager bag dynamic field", async () => {
    const client = {
      getObject: vi.fn().mockResolvedValue({
        object: {
          json: {
            balance_manager: {
              balances: {
                id: {
                  id: "0xbag",
                },
              },
            },
          },
        },
      }),
      listDynamicFields: vi.fn().mockResolvedValue({
        dynamicFields: [
          {
            valueType: "0x2::balance::Balance<0x2::usd::USD>",
            value: {
              type: "0x2::balance::Balance<0x2::usd::USD>",
              bcs: new Uint8Array([64, 66, 15, 0, 0, 0, 0, 0]),
            },
          },
        ],
      }),
    };

    await expect(
      readManagerQuoteBalance(client as never, {
        managerId: "0xmanager",
        coinType: "0x2::usd::USD",
      }),
    ).resolves.toBe(1000000n);
  });

  it("returns zero when the manager bag has no matching quote balance", async () => {
    const client = {
      getObject: vi.fn().mockResolvedValue({
        object: {
          json: {
            balance_manager: {
              balances: {
                id: {
                  id: "0xbag",
                },
              },
            },
          },
        },
      }),
      listDynamicFields: vi.fn().mockResolvedValue({
        dynamicFields: [],
      }),
    };

    await expect(
      readManagerQuoteBalance(client as never, {
        managerId: "0xmanager",
        coinType: "0x2::usd::USD",
      }),
    ).resolves.toBe(0n);
  });

  it("formats quote balances with metadata and falls back to the type symbol", async () => {
    const client = {
      getCoinMetadata: vi.fn().mockResolvedValue({
        coinMetadata: {
          id: "0xmeta",
          decimals: 6,
          name: "Dollar",
          symbol: "USDs",
          description: "",
          iconUrl: null,
        },
      }),
    };

    await expect(
      readQuoteAssetMetadata(client as never, "0x2::usd::USD"),
    ).resolves.toEqual({
      decimals: 6,
      symbol: "USDs",
    });

    expect(formatQuoteBalance(123450000n, { decimals: 6, symbol: "USDs" })).toBe("$123.45");
    expect(formatQuoteBalance(null, { decimals: 6, symbol: "USDs" })).toBe("—");
  });
});
