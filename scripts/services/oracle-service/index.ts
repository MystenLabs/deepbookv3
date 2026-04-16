import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { loadConfig } from "./config";
import { makeLogger } from "./logger";
import type { ServiceState } from "./types";
import { newQueue, enqueue } from "./intent-queue";
import { newLaneState } from "./gas-pool";
import { newRegistry, discoverOracles } from "./registry";
import { ensureCapsAndCoins } from "./bootstrap";
import { makeSubscriber } from "./subscriber";
import { makeRotationManager } from "./rotation";
import { makeExecutor } from "./executor";
import { makeHealthServer } from "./healthz";

async function main(): Promise<void> {
  const config = loadConfig();
  const log = makeLogger("service");
  log.info({ event: "service_started", network: config.network });

  const client = new SuiClient({ url: config.suiRpcUrl });

  const { secretKey } = decodeSuiPrivateKey(config.suiSignerKey);
  const signer = Ed25519Keypair.fromSecretKey(secretKey);

  const bootstrapLog = makeLogger("bootstrap");
  const { capIds, lanes } = await ensureCapsAndCoins(client, signer, config, bootstrapLog);

  const registryLog = makeLogger("registry");
  const now = Date.now();
  const byId = await discoverOracles(client, config, capIds, now, registryLog);
  const registry = newRegistry();
  for (const [id, state] of byId) {
    registry.byId.set(id, state);
    let inner = registry.byExpiry.get(state.tier);
    if (!inner) {
      inner = new Map();
      registry.byExpiry.set(state.tier, inner);
    }
    inner.set(state.expiryMs, id);
  }

  const state: ServiceState = {
    registry,
    priceCache: { spot: null, forwards: new Map() },
    sviCache: new Map(),
    intents: newQueue(),
    lanes: newLaneState(lanes),
    adminCapInFlight: false,
    clock: { tickId: 0 },
  };

  for (const oracle of state.registry.byId.values()) {
    const missingCaps = capIds.filter((c) => !oracle.registeredCapIds.has(c));
    switch (oracle.status) {
      case "inactive":
        enqueue(state.intents, { kind: "bootstrap_oracle", oracleId: oracle.id, retries: 0 });
        break;
      case "active":
        if (missingCaps.length > 0) {
          enqueue(state.intents, { kind: "register_caps", oracleId: oracle.id, capIds: missingCaps, retries: 0 });
        }
        break;
      case "pending_settlement":
        enqueue(state.intents, { kind: "settle_nudge", oracleId: oracle.id, retries: 0 });
        enqueue(state.intents, { kind: "compact", oracleId: oracle.id, retries: 0 });
        break;
      case "settled":
        enqueue(state.intents, { kind: "compact", oracleId: oracle.id, retries: 0 });
        break;
    }
  }

  const subscriber = makeSubscriber(config, state.priceCache, state.sviCache, makeLogger("subscriber"));
  for (const oracle of state.registry.byId.values()) {
    subscriber.addOracle(oracle.id, oracle.expiryMs);
  }
  subscriber.start();

  const rotation = makeRotationManager(state, config, makeLogger("rotation"));
  rotation.start();

  const executor = makeExecutor(state, client, signer, config, subscriber, makeLogger("executor"));
  executor.start();

  const health = makeHealthServer(config.healthzPort, subscriber, executor, makeLogger("healthz"));
  health.start();

  const shutdown = (sig: string) => {
    log.info({ event: "service_started", msg: `shutting_down_${sig}` });
    executor.stop();
    rotation.stop();
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
