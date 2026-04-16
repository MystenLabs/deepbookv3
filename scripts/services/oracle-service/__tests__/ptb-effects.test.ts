import { describe, it, expect } from "vitest";
import { parseOracleEvents, gasNetFromEffects } from "../ptb-effects";

const PKG = "0xabc";

describe("parseOracleEvents", () => {
  it("extracts OracleCreated events", () => {
    const events = [
      {
        type: `${PKG}::registry::OracleCreated`,
        parsedJson: {
          oracle_id: "0xoracle1",
          underlying_asset: "BTC",
          expiry: "1776357000000",
          min_strike: "50000",
          tick_size: "1",
        },
      },
    ];
    const result = parseOracleEvents(events as any, PKG);
    expect(result.created).toEqual([
      { oracleId: "0xoracle1", underlyingAsset: "BTC", expiryMs: 1776357000000 },
    ]);
  });

  it("extracts OracleSettled events", () => {
    const events = [
      {
        type: `${PKG}::oracle::OracleSettled`,
        parsedJson: {
          oracle_id: "0xoracle1",
          settlement_price: "74500000000000",
          timestamp: "1776358000000",
          expiry: "1776357000000",
        },
      },
    ];
    const r = parseOracleEvents(events as any, PKG);
    expect(r.settled).toEqual([
      { oracleId: "0xoracle1", settlementPrice: 74500000000000, timestampMs: 1776358000000 },
    ]);
  });

  it("ignores unknown event types", () => {
    const events = [{ type: `${PKG}::other::NotRelevant`, parsedJson: {} }];
    const r = parseOracleEvents(events as any, PKG);
    expect(r.created).toEqual([]);
    expect(r.settled).toEqual([]);
  });
});

describe("gasNetFromEffects", () => {
  it("returns storage rebate minus gas used", () => {
    const effects = {
      gasUsed: {
        computationCost: "1000",
        storageCost: "2000",
        storageRebate: "10000",
        nonRefundableStorageFee: "100",
      },
    };
    const net = gasNetFromEffects(effects as any);
    expect(net).toBe(10000 - 1000 - 2000 - 100);
  });
});
