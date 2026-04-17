import { describe, expect, it } from "vitest";
import { extractWsValues, isWsSubscriptionAck, makeSubscriber } from "../subscriber";
import type { PriceCache, SVICache } from "../types";

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

describe("makeSubscriber", () => {
  it("does not resubscribe when syncOracles receives an unchanged target set", async () => {
    class FakeWebSocket {
      static instances: FakeWebSocket[] = [];
      static OPEN = 1;
      static CLOSED = 3;
      readyState = FakeWebSocket.OPEN;
      sent: string[] = [];
      private listeners = new Map<string, Array<(event: any) => void>>();

      constructor(_url: string) {
        FakeWebSocket.instances.push(this);
      }

      addEventListener(type: string, listener: (event: any) => void): void {
        const existing = this.listeners.get(type) ?? [];
        existing.push(listener);
        this.listeners.set(type, existing);
      }

      send(payload: string): void {
        this.sent.push(payload);
      }

      close(): void {
        this.readyState = FakeWebSocket.CLOSED;
      }

      emit(type: string, event: any): void {
        for (const listener of this.listeners.get(type) ?? []) {
          listener(event);
        }
      }
    }

    const originalWebSocket = (globalThis as any).WebSocket;
    (globalThis as any).WebSocket = FakeWebSocket as any;
    try {
      const expiryMs = Date.now() + 60_000;
      const priceCache: PriceCache = { spot: null, forwards: new Map() };
      const sviCache: SVICache = new Map();
      const subscriber = makeSubscriber(
        {
          blockscholesWsUrl: "wss://example.test",
          blockscholesApiKey: "key",
        } as any,
        priceCache,
        sviCache,
        {
          info() {},
          warn() {},
          error() {},
          fatal() {},
        } as any,
      );

      subscriber.syncOracles([
        {
          id: "0xoracle",
          underlying: "BTC",
          expiryMs,
        },
      ]);
      subscriber.start();

      const ws = FakeWebSocket.instances[0];
      ws.emit("open", {});
      ws.emit("message", { data: JSON.stringify({ id: 1, result: "ok" }) });

      const subscribeCountAfterAuth = ws.sent
        .map((raw) => JSON.parse(raw))
        .filter((payload) => payload.method === "subscribe").length;

      subscriber.syncOracles([
        {
          id: "0xoracle",
          underlying: "BTC",
          expiryMs,
        },
      ]);
      await Promise.resolve();

      const subscribeCountAfterNoopSync = ws.sent
        .map((raw) => JSON.parse(raw))
        .filter((payload) => payload.method === "subscribe").length;

      expect(subscribeCountAfterAuth).toBe(3);
      expect(subscribeCountAfterNoopSync).toBe(subscribeCountAfterAuth);
    } finally {
      (globalThis as any).WebSocket = originalWebSocket;
    }
  });
});
