// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { createServer, type Server } from "node:http";
import type { Logger } from "./logger";
import type { Subscriber } from "./subscriber";
import type { Executor } from "./executor";

// Grace window for the very first tick after service boot. Avoids a 503
// window between `start()` and the executor's first successful tick.
const BOOT_GRACE_MS = 30_000;

export type HealthServer = {
  start: () => void;
  stop: () => void;
};

export function makeHealthServer(
  port: number,
  subscriber: Subscriber,
  executor: Executor,
  log: Logger,
): HealthServer {
  let server: Server | null = null;
  let bootTs = 0;

  function isHealthy(): { ok: boolean; reason?: string } {
    const now = Date.now();
    const wsOk = subscriber.isConnected() || now - subscriber.lastFrameReceivedMs() < 60_000;
    const tickOk =
      now - executor.lastSuccessfulTickMs() < 10_000 ||
      (executor.lastSuccessfulTickMs() === 0 && now - bootTs < BOOT_GRACE_MS);
    if (!wsOk) return { ok: false, reason: "ws_stale" };
    if (!tickOk) return { ok: false, reason: "executor_stale" };
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
        if (h.ok) {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ status: "ok" }));
          log.debug({ event: "health_ok" });
        } else {
          res.writeHead(503, { "content-type": "application/json" });
          res.end(JSON.stringify({ status: "degraded", reason: h.reason }));
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
