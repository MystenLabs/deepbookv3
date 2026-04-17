import { describe, expect, it } from "vitest";
import { extractWsValues, isWsSubscriptionAck } from "../subscriber";

describe("extractWsValues", () => {
  it("keeps all subscription entries when a frame contains multiple params", () => {
    const payload = {
      jsonrpc: "2.0",
      method: "subscription",
      params: [
        {
          client_id: "pricing",
          data: {
            timestamp: 1776382722000,
            values: [{ sid: "fwd_0xabc", v: 74998.83913 }],
          },
        },
        {
          client_id: "svi",
          data: {
            timestamp: 1776382720000,
            values: [
              {
                sid: "svi_0xabc",
                alpha: 0.00001,
                beta: 0.00013,
                rho: 0.22782,
                m: 0.00111,
                sigma: 0.00126,
              },
            ],
          },
        },
      ],
    };

    expect(extractWsValues(payload)).toEqual([
      {
        kind: "forward",
        oracleId: "0xabc",
        value: 74998.83913,
        timestampMs: 1776382722000,
      },
      {
        kind: "svi",
        oracleId: "0xabc",
        params: {
          a: 0.00001,
          b: 0.00013,
          rho: 0.22782,
          m: 0.00111,
          sigma: 0.00126,
        },
        timestampMs: 1776382720000,
      },
    ]);
  });

  it("ignores non-subscription payloads", () => {
    expect(extractWsValues({ jsonrpc: "2.0", id: 1, result: "ok" })).toEqual([]);
  });

  it("recognizes subscribe ack payloads", () => {
    expect(isWsSubscriptionAck({
      jsonrpc: "2.0",
      id: 101,
      result: [{ batch: { client_id: "forwards" } }],
    })).toBe(true);
  });
});
