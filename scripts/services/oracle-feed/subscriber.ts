// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { Config } from "./config";
import type { Logger } from "./logger";
import type {
  OracleId,
  OracleState,
  PriceCache,
  SVICache,
  SVIParams,
} from "./types";

const WS_RECONNECT_LADDER_MS = [
  500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 60_000,
];
const WS_SUBSCRIPTION_DECIMALS = 9;

// BlockScholes per-batch sub limit. Each batch uses one stable client_id; sids
// within a batch must be unique. Resending the same client_id with a new batch
// replaces the server-side sub list — not additive — so we always send the
// full current set under each stable id.
const MAX_SUBS_PER_BATCH = 20;

export type Subscriber = {
  start: () => void;
  stop: () => void;
  syncOracles: (
    oracles: Iterable<Pick<OracleState, "id" | "underlying" | "expiryMs">>,
  ) => void;
  isConnected: () => boolean;
  lastFrameReceivedMs: () => number;
};

type OracleSub = {
  underlying: string;
  expiryMs: number;
  fwdSid: string;
  sviSid: string;
};

function toOracleSub(
  oracle: Pick<OracleState, "id" | "underlying" | "expiryMs">,
): OracleSub {
  return {
    underlying: oracle.underlying,
    expiryMs: oracle.expiryMs,
    fwdSid: `fwd_${oracle.id}`,
    sviSid: `svi_${oracle.id}`,
  };
}

function oracleTargetsEqual(
  current: Map<OracleId, OracleSub>,
  next: Map<OracleId, OracleSub>,
): boolean {
  if (current.size !== next.size) return false;
  for (const [oracleId, currentSub] of current) {
    const nextSub = next.get(oracleId);
    if (!nextSub) return false;
    if (
      currentSub.underlying !== nextSub.underlying ||
      currentSub.expiryMs !== nextSub.expiryMs
    ) {
      return false;
    }
  }
  return true;
}

export type ExtractedWsValue =
  | { kind: "spot"; sid: string; value: number; timestampMs: number }
  | { kind: "forward"; oracleId: OracleId; value: number; timestampMs: number }
  | { kind: "svi"; oracleId: OracleId; params: SVIParams; timestampMs: number };

export function extractWsValues(payload: any): ExtractedWsValue[] {
  if (payload?.method !== "subscription" || !Array.isArray(payload.params)) {
    return [];
  }

  const out: ExtractedWsValue[] = [];
  for (const entry of payload.params) {
    const timestampMs = Number(entry?.data?.timestamp);
    const values = Array.isArray(entry?.data?.values) ? entry.data.values : [];
    for (const value of values) {
      const sid = String(value?.sid ?? "");
      if (sid.startsWith("spot_") && typeof value.v === "number") {
        out.push({ kind: "spot", sid, value: value.v, timestampMs });
        continue;
      }
      if (sid.startsWith("fwd_") && typeof value.v === "number") {
        out.push({
          kind: "forward",
          oracleId: sid.slice(4),
          value: Number(value.v),
          timestampMs,
        });
        continue;
      }
      if (sid.startsWith("svi_")) {
        out.push({
          kind: "svi",
          oracleId: sid.slice(4),
          params: {
            a: Number(value.alpha),
            b: Number(value.beta),
            rho: Number(value.rho),
            m: Number(value.m),
            sigma: Number(value.sigma),
          },
          timestampMs,
        });
      }
    }
  }
  return out;
}

export function isWsSubscriptionAck(payload: any): boolean {
  return (
    payload?.jsonrpc === "2.0" &&
    typeof payload?.id === "number" &&
    Array.isArray(payload?.result)
  );
}

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
  let resubscribeScheduled = false;

  /// Coalesce rapid addOracle/removeOracle calls (e.g., during a manager
  /// window rediscovery) into a single WS resubscribe on the next microtask.
  function scheduleResubscribe(): void {
    if (!authed || resubscribeScheduled) return;
    resubscribeScheduled = true;
    queueMicrotask(() => {
      resubscribeScheduled = false;
      resubscribeAll();
    });
  }

  function backoffMs(): number {
    return WS_RECONNECT_LADDER_MS[
      Math.min(reconnectAttempt, WS_RECONNECT_LADDER_MS.length - 1)
    ];
  }

  function send(payload: Record<string, unknown>): void {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify(payload));
  }

  function sendBatch(
    clientId: string,
    frequency: string,
    batch: Record<string, unknown>[],
    extraParams: Record<string, unknown> = {},
  ): void {
    if (batch.length === 0) return;
    const rpcId = nextRpcId++;
    const payload = {
      jsonrpc: "2.0",
      id: rpcId,
      method: "subscribe",
      params: [
        {
          frequency,
          client_id: clientId,
          batch,
          // SVI params are pushed on-chain at 1e9 scale; lower WS precision
          // quantizes short-dated variance inputs and can zero out `a`.
          options: {
            format: {
              timestamp: "ms",
              hexify: false,
              decimals: WS_SUBSCRIPTION_DECIMALS,
            },
          },
          ...extraParams,
        },
      ],
    };
    log.info({
      event: "ws_connecting",
      phase: "subscribe_out",
      rpcId,
      clientId,
      frequency,
      sidCount: batch.length,
      sampleSid: batch[0]?.sid,
      payload: JSON.stringify(payload).slice(0, 800),
    });
    send(payload);
  }

  /// Re-send all three batch categories (spot, forwards, SVI) under stable
  /// client_ids. Each client_id owns one batch server-side; re-sending the
  /// same client_id replaces its sub list wholesale (not additive), so we
  /// always send the full current set. Past-expiry oracles are filtered —
  /// BlockScholes rejects mark.px for expiries in the past and a single bad
  /// entry poisons the whole batch.
  function resubscribeAll(): void {
    const now = Date.now();
    const active = [...oracles.values()].filter((o) => o.expiryMs > now);
    const underlyings = [...new Set(active.map((o) => o.underlying))];

    const spotBatch = underlyings.map((asset) => ({
      sid: `spot_${asset}`,
      feed: "index.px",
      asset: "spot",
      base_asset: asset,
      quote_asset: "USD",
    }));
    sendBatchedWithChunks("spot", "1000ms", spotBatch);

    const fwdBatch = active.map((o) => ({
      sid: o.fwdSid,
      feed: "mark.px",
      asset: "future",
      base_asset: o.underlying,
      expiry: isoSeconds(o.expiryMs),
    }));
    sendBatchedWithChunks("forwards", "1000ms", fwdBatch);

    const sviBatch = active.map((o) => ({
      sid: o.sviSid,
      feed: "model.params",
      exchange: "composite",
      asset: "option",
      base_asset: o.underlying,
      model: "SVI",
      expiry: isoSeconds(o.expiryMs),
    }));
    sendBatchedWithChunks("svi", "20000ms", sviBatch, {
      retransmit_frequency: "20000ms",
    });

    log.info({
      event: "ws_subscribed",
      underlyings,
      oracleCount: active.length,
      spotSids: spotBatch.length,
      fwdSids: fwdBatch.length,
      sviSids: sviBatch.length,
    });
  }

  /// Chunk into N batches if the batch exceeds MAX_SUBS_PER_BATCH. Uses
  /// deterministic chunk-index in the client_id suffix so resends produce
  /// the same ids (stable).
  function sendBatchedWithChunks(
    prefix: string,
    frequency: string,
    items: Record<string, unknown>[],
    extraParams: Record<string, unknown> = {},
  ): void {
    if (items.length === 0) return;
    if (items.length <= MAX_SUBS_PER_BATCH) {
      sendBatch(prefix, frequency, items, extraParams);
      return;
    }
    for (let i = 0; i < items.length; i += MAX_SUBS_PER_BATCH) {
      const chunk = items.slice(i, i + MAX_SUBS_PER_BATCH);
      const chunkIdx = Math.floor(i / MAX_SUBS_PER_BATCH);
      sendBatch(`${prefix}_${chunkIdx}`, frequency, chunk, extraParams);
    }
  }

  function connect(): void {
    if (stopped) return;
    log.info({ event: "ws_connecting", attempt: reconnectAttempt });
    ws = new WebSocket(config.blockscholesWsUrl);
    authed = false;

    ws.addEventListener("open", () => {
      send({
        jsonrpc: "2.0",
        id: 1,
        method: "authenticate",
        params: { api_key: config.blockscholesApiKey },
      });
    });

    ws.addEventListener("message", (event: MessageEvent) => {
      lastFrame = Date.now();
      const raw = event.data.toString();
      let parsed: any;
      try {
        parsed = JSON.parse(raw);
      } catch {
        log.warn({
          event: "ws_frame_dropped",
          reason: "parse_error",
          raw: raw.slice(0, 500),
        });
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
        log.warn({
          event: "ws_subscribe_error",
          rpcId: parsed.id,
          error: parsed.error,
        });
        return;
      }

      if (isWsSubscriptionAck(parsed)) {
        return;
      }

      const extracted = extractWsValues(parsed);
      if (extracted.length > 0) {
        for (const value of extracted) {
          applyValue(value);
        }
        return;
      }

      // Unhandled message — log once so we can see what the server is sending
      // back for our subscribe RPCs. Truncate raw so a huge frame doesn't
      // flood logs.
      log.info({
        event: "ws_frame_dropped",
        reason: "unhandled_shape",
        rpcId: parsed.id,
        keys: Object.keys(parsed),
        raw: raw.slice(0, 500),
      });
    });

    ws.addEventListener("close", () => {
      if (stopped) return;
      log.warn({
        event: "ws_reconnect",
        attempt: reconnectAttempt + 1,
        backoffMs: backoffMs(),
      });
      reconnectTimer = setTimeout(() => {
        reconnectAttempt++;
        connect();
      }, backoffMs());
    });

    ws.addEventListener("error", (e: Event) => {
      log.warn({
        event: "ws_frame_dropped",
        reason: "socket_error",
        err: String(e),
      });
    });
  }

  function applyValue(value: ExtractedWsValue): void {
    if (value.kind === "spot") {
      const first = priceCache.spot === null;
      priceCache.spot = { value: value.value, receivedAtMs: value.timestampMs };
      if (first)
        log.info({ event: "ws_connected", sid: value.sid, value: value.value });
      return;
    }

    if (value.kind === "forward") {
      const first = !priceCache.forwards.has(value.oracleId);
      priceCache.forwards.set(value.oracleId, {
        value: value.value,
        receivedAtMs: value.timestampMs,
      });
      if (first) {
        log.info({
          event: "ws_connected",
          sid: `fwd_${value.oracleId}`,
          oracleId: value.oracleId,
          value: value.value,
        });
      }
      return;
    }

    const prev = sviCache.get(value.oracleId);
    sviCache.set(value.oracleId, {
      params: value.params,
      receivedAtMs: value.timestampMs,
      lastPushedAtMs: prev?.lastPushedAtMs ?? null,
    });
    if (!prev) {
      log.info({
        event: "ws_connected",
        sid: `svi_${value.oracleId}`,
        oracleId: value.oracleId,
      });
    }
  }

  return {
    start: () => {
      connect();
    },
    stop: () => {
      stopped = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      ws?.close();
    },
    syncOracles: (nextOracles) => {
      const next = new Map<OracleId, OracleSub>();
      for (const oracle of nextOracles) {
        next.set(oracle.id, toOracleSub(oracle));
      }
      if (oracleTargetsEqual(oracles, next)) return;
      oracles.clear();
      for (const [oracleId, sub] of next) {
        oracles.set(oracleId, sub);
      }
      scheduleResubscribe();
    },
    isConnected: () => ws?.readyState === WebSocket.OPEN,
    lastFrameReceivedMs: () => lastFrame,
  };
}

function isoSeconds(expiryMs: number): string {
  // BlockScholes wants "YYYY-MM-DDTHH:MM:SSZ" (no milliseconds).
  return new Date(expiryMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}
