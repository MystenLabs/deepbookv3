import { describe, expect, it } from "vitest";
import { parseOracleObject } from "../registry";

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
