// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { Config } from "./config";
import type { Logger } from "./logger";
import type { OracleId, PriceCache, SVICache } from "./types";

const WS_RECONNECT_LADDER_MS = [500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 60_000];

export type Subscriber = {
  start: () => void;
  stop: () => void;
  addOracle: (oracleId: OracleId, underlying: string, expiryMs: number) => void;
  removeOracle: (oracleId: OracleId) => void;
  isConnected: () => boolean;
  lastFrameReceivedMs: () => number;
};

type OracleSub = {
  underlying: string;
  expiryMs: number;
  fwdSid: string;
  sviSid: string;
};

export function makeSubscriber(
  config: Config,
  priceCache: PriceCache,
  sviCache: SVICache,
  log: Logger,
): Subscriber {
  let ws: WebSocket | null = null;
  let nextRpcId = 100;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectAttempt = 0;
  let stopped = false;
  let lastFrame = 0;
  const oracles = new Map<OracleId, OracleSub>();
  let authed = false;

  function backoffMs(): number {
    return WS_RECONNECT_LADDER_MS[Math.min(reconnectAttempt, WS_RECONNECT_LADDER_MS.length - 1)];
  }

  function send(payload: Record<string, unknown>): void {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify(payload));
  }

  function subscribeSpot(underlyings: Set<string>): void {
    for (const asset of underlyings) {
      send({
        jsonrpc: "2.0",
        id: nextRpcId++,
        method: "subscribe",
        params: [{
          frequency: "1000ms",
          client_id: `spot_${asset}`,
          batch: [{ sid: `spot_${asset}`, feed: "index.px", asset: "spot", base_asset: asset, quote_asset: "USD" }],
          options: { format: { timestamp: "ms", hexify: false, decimals: 5 } },
        }],
      });
    }
  }

  function subscribeForwards(): void {
    const items = [...oracles.entries()].map(([_oid, o]) => ({
      sid: o.fwdSid,
      feed: "mark.px",
      asset: "future",
      base_asset: o.underlying,
      expiry: isoSeconds(o.expiryMs),
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
          base_asset: entry.underlying,
          model: "SVI",
          expiry: isoSeconds(entry.expiryMs),
        }],
        options: { format: { timestamp: "ms", hexify: false, decimals: 5 } },
      }],
    });
  }

  function resubscribeAll(): void {
    const underlyings = new Set<string>();
    for (const o of oracles.values()) underlyings.add(o.underlying);
    subscribeSpot(underlyings);
    subscribeForwards();
    for (const oid of oracles.keys()) subscribeSvi(oid);
    log.info({ event: "ws_subscribed", underlyings: [...underlyings], oracleCount: oracles.size });
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

    ws.addEventListener("close", () => {
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
  }

  function applyFrame(v: any): void {
    const sid = v.sid as string;
    const now = Date.now();
    if (sid.startsWith("spot_") && typeof v.v === "number") {
      // Single-underlying setup: any spot frame is "the" spot. If multiple
      // underlyings are ever active simultaneously, priceCache.spot would
      // need to become a Map keyed by underlying.
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
      if (reconnectTimer) clearTimeout(reconnectTimer);
      ws?.close();
    },
    addOracle: (oracleId, underlying, expiryMs) => {
      oracles.set(oracleId, {
        underlying,
        expiryMs,
        fwdSid: `fwd_${oracleId}`,
        sviSid: `svi_${oracleId}`,
      });
      if (authed) {
        subscribeForwards();
        subscribeSvi(oracleId);
      }
    },
    removeOracle: (oracleId) => {
      oracles.delete(oracleId);
    },
    isConnected: () => ws?.readyState === WebSocket.OPEN,
    lastFrameReceivedMs: () => lastFrame,
  };
}

function isoSeconds(expiryMs: number): string {
  // BlockScholes wants "YYYY-MM-DDTHH:MM:SSZ" (no milliseconds).
  return new Date(expiryMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}
