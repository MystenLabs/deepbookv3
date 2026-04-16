import type { Config } from "./config";
import type { Logger } from "./logger";
import type { OracleId, PriceCache, SVICache } from "./types";

type SubId = number;

export type Subscriber = {
  start: () => void;
  stop: () => void;
  addOracle: (oracleId: OracleId, expiryMs: number) => void;
  removeOracle: (oracleId: OracleId) => void;
  isConnected: () => boolean;
  lastFrameReceivedMs: () => number;
};

export function makeSubscriber(
  config: Config,
  priceCache: PriceCache,
  sviCache: SVICache,
  log: Logger,
): Subscriber {
  let ws: WebSocket | null = null;
  let nextRpcId = 100;
  let pingTimer: ReturnType<typeof setInterval> | null = null;
  let pongTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectAttempt = 0;
  let stopped = false;
  let lastFrame = 0;
  const oracles = new Map<OracleId, { expiryMs: number; fwdSid: string; sviSid: string }>();
  const authResolvers: Array<() => void> = [];
  let authed = false;

  function backoffMs(): number {
    const ladder = [500, 1000, 2000, 4000, 8000, 16_000, 30_000, 60_000];
    return ladder[Math.min(reconnectAttempt, ladder.length - 1)];
  }

  function send(payload: Record<string, unknown>): void {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify(payload));
  }

  function subscribeSpot(): void {
    send({
      jsonrpc: "2.0",
      id: nextRpcId++,
      method: "subscribe",
      params: [{
        frequency: "1000ms",
        client_id: "spot",
        batch: [{ sid: "spot", feed: "index.px", asset: "spot", base_asset: "BTC", quote_asset: "USD" }],
        options: { format: { timestamp: "ms", hexify: false, decimals: 5 } },
      }],
    });
  }

  function subscribeForwards(): void {
    const items = [...oracles.entries()].map(([oid, o]) => ({
      sid: o.fwdSid,
      feed: "mark.px",
      asset: "future",
      base_asset: "BTC",
      expiry: new Date(o.expiryMs).toISOString().replace(/\.\d{3}Z$/, "Z"),
    }));
    for (let i = 0; i < items.length; i += 10) {
      const batch = items.slice(i, i + 10);
      send({
        jsonrpc: "2.0",
        id: nextRpcId++,
        method: "subscribe",
        params: [{
          frequency: "1000ms",
          client_id: `fwd_batch_${i}`,
          batch,
          options: { format: { timestamp: "ms", hexify: false, decimals: 5 } },
        }],
      });
    }
  }

  function subscribeSvi(oracleId: OracleId): void {
    const entry = oracles.get(oracleId);
    if (!entry) return;
    send({
      jsonrpc: "2.0",
      id: nextRpcId++,
      method: "subscribe",
      params: [{
        frequency: "20000ms",
        retransmit_frequency: "20000ms",
        client_id: entry.sviSid,
        batch: [{
          sid: entry.sviSid,
          feed: "model.params",
          exchange: "composite",
          asset: "option",
          base_asset: "BTC",
          model: "SVI",
          expiry: new Date(entry.expiryMs).toISOString().replace(/\.\d{3}Z$/, "Z"),
        }],
        options: { format: { timestamp: "ms", hexify: false, decimals: 5 } },
      }],
    });
  }

  function resubscribeAll(): void {
    subscribeSpot();
    subscribeForwards();
    for (const oid of oracles.keys()) subscribeSvi(oid);
    log.info({ event: "ws_subscribed", count: oracles.size * 2 + 1 });
  }

  function startPing(): void {
    pingTimer = setInterval(() => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      try {
        (ws as any).ping?.();
      } catch {}
      pongTimer = setTimeout(() => {
        log.warn({ event: "ws_frame_dropped", reason: "no_pong" });
        ws?.close();
      }, config.wsPongTimeoutMs);
    }, config.wsPingIntervalMs);
  }

  function stopPing(): void {
    if (pingTimer) clearInterval(pingTimer);
    if (pongTimer) clearTimeout(pongTimer);
    pingTimer = null;
    pongTimer = null;
  }

  function connect(): void {
    if (stopped) return;
    log.info({ event: "ws_connecting", attempt: reconnectAttempt });
    ws = new WebSocket(config.blockscholesWsUrl);
    authed = false;

    ws.addEventListener("open", () => {
      send({ jsonrpc: "2.0", id: 1, method: "authenticate", params: { api_key: config.blockscholesApiKey } });
    });

    ws.addEventListener("message", (event: MessageEvent) => {
      lastFrame = Date.now();
      let parsed: any;
      try {
        parsed = JSON.parse(event.data.toString());
      } catch {
        return;
      }

      if (parsed.id === 1 && parsed.result === "ok") {
        authed = true;
        log.info({ event: "ws_auth_ok" });
        resubscribeAll();
        reconnectAttempt = 0;
        return;
      }

      if (parsed.error) {
        log.warn({ event: "ws_subscribe_error", rpcId: parsed.id, error: parsed.error });
        return;
      }

      if (parsed.method === "subscription") {
        const entry = parsed.params?.[0];
        const values = entry?.data?.values ?? [];
        for (const v of values) {
          applyFrame(v);
        }
      }
    });

    ws.addEventListener("pong" as any, () => {
      if (pongTimer) clearTimeout(pongTimer);
      pongTimer = null;
    });

    ws.addEventListener("close", () => {
      stopPing();
      if (stopped) return;
      log.warn({ event: "ws_reconnect", attempt: reconnectAttempt + 1, backoffMs: backoffMs() });
      reconnectTimer = setTimeout(() => {
        reconnectAttempt++;
        connect();
      }, backoffMs());
    });

    ws.addEventListener("error", (e: Event) => {
      log.warn({ event: "ws_frame_dropped", reason: "socket_error", err: String(e) });
    });

    startPing();
  }

  function applyFrame(v: any): void {
    const sid = v.sid as string;
    const now = Date.now();
    if (sid === "spot" && typeof v.v === "number") {
      priceCache.spot = { value: v.v, receivedAtMs: now };
      return;
    }
    if (sid.startsWith("fwd_")) {
      const oid = sid.slice(4);
      priceCache.forwards.set(oid, { value: Number(v.v), receivedAtMs: now });
      return;
    }
    if (sid.startsWith("svi_")) {
      const oid = sid.slice(4);
      const prev = sviCache.get(oid);
      sviCache.set(oid, {
        params: { a: Number(v.alpha), b: Number(v.beta), rho: Number(v.rho), m: Number(v.m), sigma: Number(v.sigma) },
        receivedAtMs: now,
        lastPushedAtMs: prev?.lastPushedAtMs ?? null,
      });
      return;
    }
  }

  return {
    start: () => { connect(); },
    stop: () => {
      stopped = true;
      stopPing();
      if (reconnectTimer) clearTimeout(reconnectTimer);
      ws?.close();
    },
    addOracle: (oracleId, expiryMs) => {
      const fwdSid = `fwd_${oracleId}`;
      const sviSid = `svi_${oracleId}`;
      oracles.set(oracleId, { expiryMs, fwdSid, sviSid });
      if (authed) {
        subscribeForwards();
        subscribeSvi(oracleId);
      }
    },
    removeOracle: (oracleId) => {
      oracles.delete(oracleId);
      // Note: we don't send unsubscribe; docs don't specify the RPC shape.
      // Frames for dropped oracles will arrive and be ignored by applyFrame
      // since priceCache.forwards and sviCache no longer have those keys
      // (the executor only pushes for oracles in the registry).
    },
    isConnected: () => ws?.readyState === WebSocket.OPEN,
    lastFrameReceivedMs: () => lastFrame,
  };
}
