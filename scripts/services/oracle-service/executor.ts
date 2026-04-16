import type { SuiClient, SuiTransactionBlockResponse } from "@mysten/sui/client";
import type { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { Logger } from "./logger";
import type {
  Intent,
  Lane,
  OracleState,
  ServiceState,
  Tier,
} from "./types";
import { intentUsesAdminCap } from "./types";
import { nextAvailableLane, releaseLane, laneEligibleForCreate, poolStats } from "./gas-pool";
import { finalizeFailure, finalizeSuccess, markInflight } from "./intent-queue";
import {
  addActivate,
  addCompact,
  addCreateOracle,
  addRegisterCap,
  addSettleNudge,
  addUpdatePrices,
  addUpdateSvi,
} from "./ptb-build";
import { gasNetFromEffects, newGasCoinVersionFromEffects, parseOracleEvents } from "./ptb-effects";
import type { Subscriber } from "./subscriber";

export type Executor = {
  start: () => void;
  stop: () => void;
  lastSuccessfulTickMs: () => number;
};

export function makeExecutor(
  state: ServiceState,
  client: SuiClient,
  signer: Keypair,
  config: Config,
  subscriber: Subscriber,
  log: Logger,
): Executor {
  let timer: ReturnType<typeof setInterval> | null = null;
  let lastSuccess = 0;

  async function tick(): Promise<void> {
    state.clock.tickId += 1;
    const tickId = state.clock.tickId;

    const lane = nextAvailableLane(state.lanes, config.laneMinSui);
    if (!lane) {
      log.warn({ event: "tick_skipped_no_lane", tickId });
      return;
    }

    const tx = new Transaction();
    tx.setSender(signer.toSuiAddress());
    tx.setGasPayment([{
      objectId: lane.gasCoinId,
      version: lane.gasCoinVersion,
      digest: lane.gasCoinDigest,
    }]);

    const includedIntents: Intent[] = [];
    let txUsesAdminCap = false;

    const head = state.intents.pending[0];
    if (head) {
      const usesAdmin = intentUsesAdminCap(head.kind);
      const needsCreateReserve = head.kind === "create_oracle";
      if (usesAdmin && state.adminCapInFlight) {
        log.debug({ event: "intent_skipped_admin_cap", tickId, intent: head });
      } else if (needsCreateReserve && !laneEligibleForCreate(lane, config.laneCreateReserveSui)) {
        log.debug({ event: "lane_excluded_create", tickId, laneId: lane.id });
      } else {
        buildIntentCalls(tx, head, lane, config, state);
        state.intents.pending.shift();
        includedIntents.push(head);
        if (usesAdmin) txUsesAdminCap = true;
      }
    }

    for (const oracle of state.registry.byId.values()) {
      if (oracle.status !== "active" && oracle.status !== "pending_settlement") continue;
      const spot = state.priceCache.spot;
      const fwd = state.priceCache.forwards.get(oracle.id);
      if (!spot || !fwd) continue;
      const now = Date.now();
      if (now - spot.receivedAtMs > config.priceCacheStaleMs) continue;
      if (now - fwd.receivedAtMs > config.priceCacheStaleMs) continue;
      addUpdatePrices(tx, config.predictPackageId, {
        oracleId: oracle.id,
        capId: lane.capId,
        spot: spot.value,
        forward: fwd.value,
      });
    }

    const sviPushes: Array<{ oracleId: string; receivedAtMs: number }> = [];
    for (const oracle of state.registry.byId.values()) {
      if (oracle.status !== "active") continue;
      const svi = state.sviCache.get(oracle.id);
      if (!svi) continue;
      if (svi.lastPushedAtMs !== null && svi.receivedAtMs <= svi.lastPushedAtMs) continue;
      addUpdateSvi(tx, config.predictPackageId, {
        oracleId: oracle.id,
        capId: lane.capId,
        params: svi.params,
      });
      sviPushes.push({ oracleId: oracle.id, receivedAtMs: svi.receivedAtMs });
    }

    const commandCount = (tx as any).getData?.()?.commands?.length ?? 0;
    if (commandCount === 0) {
      releaseLane(lane, lane.lastTxDigest ?? "");
      log.debug({ event: "tick_skipped_empty", tickId });
      return;
    }

    lane.available = false;
    if (txUsesAdminCap) state.adminCapInFlight = true;

    let resp: SuiTransactionBlockResponse;
    try {
      resp = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showEvents: true, showObjectChanges: true },
      });
    } catch (err) {
      log.error({ event: "tx_failed", tickId, laneId: lane.id, err: String(err) });
      releaseLane(lane, "");
      if (txUsesAdminCap) state.adminCapInFlight = false;
      for (const i of includedIntents) state.intents.pending.unshift({ ...i, retries: i.retries + 1 });
      return;
    }

    markInflight(state.intents, resp.digest, includedIntents);
    log.info({
      event: "tx_submitted",
      tickId,
      laneId: lane.id,
      txDigest: resp.digest,
      commandCount,
    });

    client.waitForTransaction({ digest: resp.digest, options: { showEffects: true, showEvents: true, showObjectChanges: true } })
      .then((final) => {
        applyTxEffects(state, config, final, lane, includedIntents, sviPushes, subscriber, log);
      })
      .catch((err) => {
        log.error({ event: "tx_failed", tickId, laneId: lane.id, txDigest: resp.digest, err: String(err) });
        const retried = finalizeFailure(state.intents, resp.digest, config.intentMaxRetries);
        for (const i of retried) {
          if ((i.retries ?? 0) > config.intentMaxRetries) {
            log.error({ event: "intent_failed_final", intent: i });
          }
        }
        releaseLane(lane, resp.digest);
        if (txUsesAdminCap) state.adminCapInFlight = false;
      });

    lastSuccess = Date.now();
  }

  return {
    start: () => {
      timer = setInterval(() => { tick().catch((err) => log.error({ event: "tx_failed", err: String(err) })); }, config.executorTickMs);
    },
    stop: () => {
      if (timer) clearInterval(timer);
      timer = null;
    },
    lastSuccessfulTickMs: () => lastSuccess,
  };
}

function buildIntentCalls(
  tx: Transaction,
  intent: Intent,
  lane: Lane,
  config: Config,
  state: ServiceState,
): void {
  switch (intent.kind) {
    case "create_oracle":
      addCreateOracle(tx, config.predictPackageId, {
        registryId: config.registryId,
        predictId: config.predictId,
        adminCapId: config.adminCapId,
        capId: lane.capId,
        underlying: "BTC",
        expiryMs: intent.expiryMs,
        minStrike: config.strikeMin,
        tickSize: config.tickSize,
      });
      return;
    case "bootstrap_oracle": {
      const oracle = state.registry.byId.get(intent.oracleId);
      if (!oracle) return;
      const missing = state.lanes.lanes
        .map((l) => l.capId)
        .filter((c) => !oracle.registeredCapIds.has(c));
      for (const cap of missing) {
        addRegisterCap(tx, config.predictPackageId, {
          oracleId: oracle.id,
          adminCapId: config.adminCapId,
          capIdToRegister: cap,
        });
      }
      addActivate(tx, config.predictPackageId, { oracleId: oracle.id, capId: lane.capId });
      return;
    }
    case "register_caps":
      for (const cap of intent.capIds) {
        addRegisterCap(tx, config.predictPackageId, {
          oracleId: intent.oracleId,
          adminCapId: config.adminCapId,
          capIdToRegister: cap,
        });
      }
      return;
    case "activate":
      addActivate(tx, config.predictPackageId, { oracleId: intent.oracleId, capId: lane.capId });
      return;
    case "compact":
      addCompact(tx, config.predictPackageId, {
        predictId: config.predictId,
        oracleId: intent.oracleId,
        capId: lane.capId,
      });
      return;
    case "settle_nudge": {
      const spot = state.priceCache.spot;
      const fwd = state.priceCache.forwards.get(intent.oracleId);
      if (!spot || !fwd) return;
      addSettleNudge(tx, config.predictPackageId, {
        oracleId: intent.oracleId,
        capId: lane.capId,
        spot: spot.value,
        forward: fwd.value,
      });
      return;
    }
  }
}

function applyTxEffects(
  state: ServiceState,
  config: Config,
  resp: SuiTransactionBlockResponse,
  lane: Lane,
  included: Intent[],
  sviPushes: Array<{ oracleId: string; receivedAtMs: number }>,
  subscriber: Subscriber,
  log: Logger,
): void {
  const success = resp.effects?.status.status === "success";
  const usedAdmin = included.some((i) => intentUsesAdminCap(i.kind));

  if (!success) {
    log.error({ event: "tx_failed", txDigest: resp.digest, status: resp.effects?.status });
    finalizeFailure(state.intents, resp.digest, config.intentMaxRetries);
    releaseLane(lane, resp.digest);
    if (usedAdmin) state.adminCapInFlight = false;
    return;
  }

  const events = parseOracleEvents(resp.events ?? [], config.predictPackageId);

  for (const e of events.created) {
    const intent = included.find(
      (i) => i.kind === "create_oracle" && i.expiryMs === e.expiryMs,
    );
    const tier = (intent as any)?.tier as Tier | undefined;
    if (!tier) continue;
    const oracle: OracleState = {
      id: e.oracleId,
      underlying: "BTC",
      expiryMs: e.expiryMs,
      tier,
      status: "inactive",
      lastTimestampMs: 0,
      registeredCapIds: new Set(),
      matrixCompacted: false,
    };
    state.registry.byId.set(oracle.id, oracle);
    let inner = state.registry.byExpiry.get(tier);
    if (!inner) {
      inner = new Map();
      state.registry.byExpiry.set(tier, inner);
    }
    inner.set(e.expiryMs, oracle.id);
    state.intents.pending.push({ kind: "bootstrap_oracle", oracleId: oracle.id, retries: 0 });
    subscriber.addOracle(oracle.id, oracle.expiryMs);
    log.info({ event: "oracle_created", oracleId: oracle.id, tier, expiryMs: e.expiryMs, txDigest: resp.digest });
  }

  for (const i of included) {
    if (i.kind === "bootstrap_oracle" || i.kind === "register_caps" || i.kind === "activate") {
      const oracle = state.registry.byId.get((i as any).oracleId);
      if (!oracle) continue;
      for (const lane2 of state.lanes.lanes) oracle.registeredCapIds.add(lane2.capId);
      if (i.kind === "bootstrap_oracle" || i.kind === "activate") {
        oracle.status = "active";
        log.info({ event: "oracle_activated", oracleId: oracle.id, txDigest: resp.digest });
      }
    }
    if (i.kind === "compact") {
      const oracle = state.registry.byId.get(i.oracleId);
      if (oracle) {
        oracle.matrixCompacted = true;
        log.info({ event: "oracle_compacted", oracleId: oracle.id, txDigest: resp.digest });
        state.registry.byId.delete(oracle.id);
        const inner = state.registry.byExpiry.get(oracle.tier);
        inner?.delete(oracle.expiryMs);
        subscriber.removeOracle(oracle.id);
      }
    }
  }

  for (const e of events.settled) {
    const oracle = state.registry.byId.get(e.oracleId);
    if (!oracle) continue;
    oracle.status = "settled";
    oracle.lastTimestampMs = e.timestampMs;
    state.intents.pending.push({ kind: "compact", oracleId: oracle.id, retries: 0 });
    log.info({ event: "oracle_settled", oracleId: oracle.id, settlementPrice: e.settlementPrice, txDigest: resp.digest });
  }

  for (const { oracleId, receivedAtMs } of sviPushes) {
    const sample = state.sviCache.get(oracleId);
    if (sample) sample.lastPushedAtMs = receivedAtMs;
  }

  const newRef = newGasCoinVersionFromEffects(resp, lane.gasCoinId);
  if (newRef) {
    lane.gasCoinVersion = newRef.version;
    lane.gasCoinDigest = newRef.digest;
    const net = gasNetFromEffects(resp.effects as any);
    lane.gasCoinBalanceApproxMist += net;
  }

  finalizeSuccess(state.intents, resp.digest);
  releaseLane(lane, resp.digest);
  if (usedAdmin) state.adminCapInFlight = false;

  log.info({ event: "tx_finalized", laneId: lane.id, txDigest: resp.digest });

  const stats = poolStats(state.lanes, config.laneCreateReserveSui, config.laneMinSui);
  if (stats.totalSui < 100) {
    log.fatal({ event: "gas_pool_fatal", totalSui: stats.totalSui });
  } else if (stats.belowCreateReserve >= state.lanes.lanes.length / 2) {
    log.error({ event: "gas_pool_low", stats });
  }
}
