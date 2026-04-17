// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { loadConfig } from "./config";
import { makeLogger } from "./logger";
import type { ServiceState } from "./types";
import { ensureCapsAndCoins } from "./bootstrap";
import { discoverOracles } from "./registry";
import { makeSubscriber } from "./subscriber";
import { pushTick, runManagerWindow, shouldRunManagerWindowNow } from "./executor";
import { makeHealthServer } from "./healthz";

async function main(): Promise<void> {
  const config = loadConfig();
  const log = makeLogger("service");
  log.info({ event: "service_started", network: config.network });

  const client = new SuiJsonRpcClient({ url: config.suiRpcUrl, network: config.network });
  const { secretKey } = decodeSuiPrivateKey(config.suiSignerKey);
  const signer = Ed25519Keypair.fromSecretKey(secretKey);

  const { capIds, lanes } = await ensureCapsAndCoins(
    client,
    signer,
    config,
    makeLogger("bootstrap"),
  );

  const oracles = await discoverOracles(
    client,
    config,
    capIds,
    Date.now(),
    makeLogger("registry"),
  );

  const state: ServiceState = {
    oracles,
    lanes,
    capIds,
    priceCache: { spot: null, forwards: new Map() },
    sviCache: new Map(),
    managerInFlight: false,
    laneHint: 0,
    lastPushMs: 0,
  };

  const subscriber = makeSubscriber(
    config,
    state.priceCache,
    state.sviCache,
    makeLogger("subscriber"),
  );
  for (const oracle of state.oracles.values()) {
    subscriber.addOracle(oracle.id, oracle.underlying, oracle.expiryMs);
  }
  subscriber.start();

  const executorLog = makeLogger("executor");
  const managerLog = makeLogger("manager");

  // Run the manager once synchronously on boot so any orphan / pending /
  // settled oracles from prior runs get reconciled before the push loop
  // starts. SVI won't be cached yet, so inactive oracles wait for the next
  // manager window after SVI frames arrive.
  await runManagerWindow(state, client, signer, config, subscriber, managerLog);

  const pushTimer = setInterval(() => {
    if (shouldRunManagerWindowNow(state, Date.now(), config.priceCacheStaleMs)) {
      runManagerWindow(state, client, signer, config, subscriber, managerLog).catch((err) =>
        managerLog.error({ event: "tx_failed", err: String(err) }),
      );
      return;
    }

    pushTick(state, client, signer, config, executorLog).catch((err) =>
      executorLog.error({ event: "tx_failed", err: String(err) }),
    );
  }, config.pushTickMs);

  const managerTimer = setInterval(() => {
    runManagerWindow(state, client, signer, config, subscriber, managerLog).catch((err) =>
      managerLog.error({ event: "tx_failed", err: String(err) }),
    );
  }, config.managerIntervalMs);

  const summaryLog = makeLogger("service");
  const summaryTimer = setInterval(() => {
    const now = Date.now();
    const byStatus: Record<string, number> = {};
    for (const o of state.oracles.values()) {
      byStatus[o.status] = (byStatus[o.status] ?? 0) + 1;
    }
    summaryLog.info({
      event: "cache_summary",
      totalOracles: state.oracles.size,
      byStatus,
      spotCached: state.priceCache.spot !== null,
      spotAgeMs: state.priceCache.spot ? now - state.priceCache.spot.receivedAtMs : null,
      forwardsCached: state.priceCache.forwards.size,
      sviCached: state.sviCache.size,
      wsConnected: subscriber.isConnected(),
      lastWsFrameAgeMs: subscriber.lastFrameReceivedMs() ? now - subscriber.lastFrameReceivedMs() : null,
      lastPushAgeMs: state.lastPushMs ? now - state.lastPushMs : null,
      managerInFlight: state.managerInFlight,
    });
    summaryLog.info({
      event: "lane_summary",
      lanes: state.lanes.map((l) => ({ id: l.id, available: l.available })),
      laneHint: state.laneHint,
    });
  }, 10_000);

  const health = makeHealthServer(
    config.healthzPort,
    subscriber,
    state,
    makeLogger("healthz"),
  );
  health.start();

  const shutdown = (sig: string) => {
    log.info({ event: "service_shutdown", signal: sig });
    clearInterval(pushTimer);
    clearInterval(managerTimer);
    clearInterval(summaryTimer);
    subscriber.stop();
    health.stop();
    setTimeout(() => process.exit(0), 2000);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  process.on("uncaughtException", (err) => {
    log.fatal({ event: "service_fatal", err: String(err), stack: err.stack });
    process.exit(1);
  });
}

main().catch((err) => {
  console.error("fatal:", err);
  process.exit(1);
});
