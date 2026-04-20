// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { createServer, type Server } from "node:http";
import type { Config } from "./config";
import type { Logger } from "./logger";
import type { Subscriber } from "./subscriber";
import type { ServiceState } from "./types";

// Grace window for the very first push after boot. Avoids a 503 window
// between `start()` and the first successful push.
const BOOT_GRACE_MS = 30_000;
const PUSH_FRESH_MS = 10_000;
// Separate ws threshold from push threshold — ws can go briefly quiet between
// auth/resubscribe without being a real problem.
const WS_STALE_MS = 60_000;

export type HealthServer = {
  start: () => void;
  stop: () => void;
};

export type HealthVerdict = { ok: boolean; reason?: string };

/// Pure verdict builder, extracted so tests can exercise every branch without
/// having to stand up an HTTP server or a real Subscriber.
export function evaluateHealth(opts: {
  now: number;
  bootTs: number;
  wsConnected: boolean;
  lastWsFrameAtMs: number;
  lastPushMs: number;
  managerInFlight: boolean;
  managerGraceMs: number;
}): HealthVerdict {
  const wsOk = opts.wsConnected || opts.now - opts.lastWsFrameAtMs < WS_STALE_MS;
  const pushFreshMs = opts.now - opts.lastPushMs;
  const bootGraceOk =
    opts.lastPushMs === 0 && opts.now - opts.bootTs < BOOT_GRACE_MS;
  const pushFresh = pushFreshMs < PUSH_FRESH_MS;
  // During a manager window, push is paused — don't flag as unhealthy, but
  // cap the grace at managerGraceMs so a stuck manager loop surfaces as
  // push_stale instead of silently hiding.
  const managerGraceOk = opts.managerInFlight && pushFreshMs < opts.managerGraceMs;
  const pushOk = bootGraceOk || pushFresh || managerGraceOk;
  if (!wsOk) return { ok: false, reason: "ws_stale" };
  if (!pushOk) return { ok: false, reason: "push_stale" };
  return { ok: true };
}

export function makeHealthServer(
  port: number,
  subscriber: Subscriber,
  state: ServiceState,
  config: Config,
  log: Logger,
): HealthServer {
  let server: Server | null = null;
  let bootTs = 0;

  function isHealthy(): HealthVerdict {
    return evaluateHealth({
      now: Date.now(),
      bootTs,
      wsConnected: subscriber.isConnected(),
      lastWsFrameAtMs: subscriber.lastFrameReceivedMs(),
      lastPushMs: state.lastPushMs,
      managerInFlight: state.managerInFlight,
      managerGraceMs: config.managerGraceMs,
    });
  }

  return {
    start: () => {
      bootTs = Date.now();
      server = createServer((req, res) => {
        if (req.url !== "/healthz") {
          res.writeHead(404);
          res.end();
          return;
        }
        const h = isHealthy();
        const body = {
          status: h.ok ? "ok" : "degraded",
          reason: h.reason,
          push_paused_for_manager: state.managerInFlight,
        };
        if (h.ok) {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify(body));
          log.debug({ event: "health_ok" });
        } else {
          res.writeHead(503, { "content-type": "application/json" });
          res.end(JSON.stringify(body));
          log.warn({ event: "health_degraded", reason: h.reason });
        }
      });
      server.listen(port);
    },
    stop: () => {
      server?.close();
      server = null;
    },
  };
}
