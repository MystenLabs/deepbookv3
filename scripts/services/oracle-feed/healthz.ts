// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { createServer, type Server } from "node:http";
import type { Logger } from "./logger";
import type { Subscriber } from "./subscriber";
import type { ServiceState } from "./types";

// Grace window for the very first push after boot. Avoids a 503 window
// between `start()` and the first successful push.
const BOOT_GRACE_MS = 30_000;

export type HealthServer = {
  start: () => void;
  stop: () => void;
};

export function makeHealthServer(
  port: number,
  subscriber: Subscriber,
  state: ServiceState,
  log: Logger,
): HealthServer {
  let server: Server | null = null;
  let bootTs = 0;

  function isHealthy(): { ok: boolean; reason?: string } {
    const now = Date.now();
    const wsOk = subscriber.isConnected() || now - subscriber.lastFrameReceivedMs() < 60_000;
    // During a manager window, push is paused — don't flag as unhealthy.
    const pushOk =
      state.managerInFlight ||
      now - state.lastPushMs < 10_000 ||
      (state.lastPushMs === 0 && now - bootTs < BOOT_GRACE_MS);
    if (!wsOk) return { ok: false, reason: "ws_stale" };
    if (!pushOk) return { ok: false, reason: "push_stale" };
    return { ok: true };
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
