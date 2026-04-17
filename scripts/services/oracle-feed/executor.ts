// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type {
  SuiEvent,
  SuiJsonRpcClient,
  SuiTransactionBlockResponse,
} from "@mysten/sui/jsonRpc";
import type { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { Logger } from "./logger";
import type { Lane, OracleState, PriceSample, ServiceState, Tier } from "./types";
import type { Subscriber } from "./subscriber";
import { expectedExpiriesForTier } from "./expiry";
import { discoverOracles } from "./registry";
import {
  addActivate,
  addCompact,
  addCreateOracle,
  addRegisterCap,
  addSettleNudge,
  addUpdatePrices,
  addUpdateSvi,
} from "./ptb-build";

/// Push-tick: pick the next available lane round-robin, build a PTB batching
/// all fresh update_prices + update_svi calls for active oracles, submit it.
/// Skipped while the manager window is running.
export async function pushTick(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  log: Logger,
): Promise<void> {
  if (state.managerInFlight) {
    log.info({ event: "tick_skipped_manager" });
    return;
  }

  const lane = nextAvailableLane(state);
  if (!lane) {
    const busy = state.lanes.filter((l) => !l.available).map((l) => l.id);
    log.info({ event: "tick_skipped_no_lane", busyLanes: busy });
    return;
  }

  const now = Date.now();
  const spot = state.priceCache.spot;
  if (!spot) {
    log.info({ event: "tick_skipped_stale_prices", reason: "no_spot", laneId: lane.id });
    return;
  }
  const spotAgeMs = now - spot.receivedAtMs;
  if (!hasFreshPriceSample(spot, now, config.priceCacheStaleMs)) {
    log.info({
      event: "tick_skipped_stale_prices",
      reason: "stale_spot",
      laneId: lane.id,
      spotAgeMs,
    });
    return;
  }

  const tx = newLaneTx(signer, lane);
  const sviPushes: Array<{ oracleId: string; receivedAtMs: number }> = [];
  let priceUpdates = 0;
  let skippedNotActive = 0;
  let skippedSafety = 0;
  let skippedNoForward = 0;
  let skippedStaleForward = 0;

  for (const oracle of state.oracles.values()) {
    if (oracle.status !== "active") { skippedNotActive++; continue; }
    if (now >= oracle.expiryMs - config.safetyWindowMs) { skippedSafety++; continue; }
    const fwd = state.priceCache.forwards.get(oracle.id);
    if (!fwd) { skippedNoForward++; continue; }
    if (now - fwd.receivedAtMs > config.priceCacheStaleMs) { skippedStaleForward++; continue; }
    addUpdatePrices(tx, config.predictPackageId, {
      oracleId: oracle.id,
      capId: lane.capId,
      spot: spot.value,
      forward: fwd.value,
    });
    priceUpdates++;
    const svi = state.sviCache.get(oracle.id);
    if (svi && (svi.lastPushedAtMs === null || svi.receivedAtMs > svi.lastPushedAtMs)) {
      addUpdateSvi(tx, config.predictPackageId, {
        oracleId: oracle.id,
        capId: lane.capId,
        params: svi.params,
      });
      sviPushes.push({ oracleId: oracle.id, receivedAtMs: svi.receivedAtMs });
    }
  }

  if (priceUpdates === 0 && sviPushes.length === 0) {
    log.info({
      event: "tick_skipped_empty",
      laneId: lane.id,
      totalOracles: state.oracles.size,
      skippedNotActive,
      skippedSafety,
      skippedNoForward,
      skippedStaleForward,
      spotAgeMs,
    });
    return;
  }

  log.info({
    event: "tx_submitting",
    laneId: lane.id,
    priceUpdates,
    sviPushes: sviPushes.length,
    spotAgeMs,
  });
  const resp = await executeLaneTx(tx, lane, client, signer, log);
  if (!resp) return;
  state.lastPushMs = Date.now();
  for (const { oracleId, receivedAtMs } of sviPushes) {
    const sample = state.sviCache.get(oracleId);
    if (sample) sample.lastPushedAtMs = receivedAtMs;
  }
  log.info({
    event: "tx_submitted",
    laneId: lane.id,
    txDigest: resp.digest,
    priceUpdates,
    sviPushes: sviPushes.length,
    latencyMs: Date.now() - now,
  });
}

export function shouldRunManagerWindowNow(
  state: ServiceState,
  now: number,
  staleAfterMs: number,
): boolean {
  for (const oracle of state.oracles.values()) {
    if (oracle.status === "inactive" && state.sviCache.has(oracle.id)) {
      return true;
    }

    if (oracle.status === "active" && now >= oracle.expiryMs) {
      return true;
    }

    if (
      oracle.status === "pending_settlement" &&
      hasFreshPriceSample(state.priceCache.spot, now, staleAfterMs)
    ) {
      return true;
    }

    if (oracle.status === "settled") {
      return true;
    }
  }

  return false;
}

/// Manager window: pause push mode, rediscover on-chain oracles, then run
/// lifecycle steps serially (create → bootstrap → settle → compact). Each
/// step awaits its tx; a failed step is logged and the loop continues, so
/// the next window retries it.
export async function runManagerWindow(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  subscriber: Subscriber,
  log: Logger,
): Promise<void> {
  if (state.managerInFlight) return;
  state.managerInFlight = true;
  log.info({ event: "manager_started" });
  try {
    await waitForAllLanesIdle(state.lanes);

    const now = Date.now();
    const discovered = await discoverOracles(client, config, state.capIds, now, log);
    reconcileLocalOracles(state, subscriber, discovered);

    const lane0 = state.lanes[0];

    for (const tier of config.tiersEnabled) {
      const wanted = expectedExpiriesForTier(
        tier,
        now,
        config.expiriesPerTier,
        config.minLookaheadMs,
      );
      for (const expiryMs of wanted) {
        const have = [...state.oracles.values()].some(
          (o) => o.tier === tier && o.expiryMs === expiryMs,
        );
        if (have) continue;
        await createOracleStep(state, client, signer, config, subscriber, lane0, tier, expiryMs, log);
      }
    }

    for (const oracle of [...state.oracles.values()]) {
      if (oracle.status === "inactive" && state.sviCache.has(oracle.id)) {
        await bootstrapOracleStep(state, client, signer, config, lane0, oracle, log);
      }
    }
    for (const oracle of [...state.oracles.values()]) {
      if (oracle.status === "pending_settlement") {
        await settleOracleStep(state, client, signer, config, lane0, oracle, log);
      }
    }
    for (const oracle of [...state.oracles.values()]) {
      if (oracle.status === "settled") {
        await compactOracleStep(state, client, signer, config, subscriber, lane0, oracle, log);
      }
    }
  } finally {
    state.managerInFlight = false;
    log.info({ event: "manager_finished" });
  }
}

function reconcileLocalOracles(
  state: ServiceState,
  subscriber: Subscriber,
  discovered: Map<string, OracleState>,
): void {
  for (const [id, oracle] of discovered) {
    const existing = state.oracles.get(id);
    if (existing) {
      existing.status = oracle.status;
      existing.registeredCapIds = oracle.registeredCapIds;
    } else {
      state.oracles.set(id, oracle);
      subscriber.addOracle(oracle.id, oracle.underlying, oracle.expiryMs);
    }
  }
  for (const id of [...state.oracles.keys()]) {
    if (!discovered.has(id)) {
      state.oracles.delete(id);
      subscriber.removeOracle(id);
    }
  }
}

async function createOracleStep(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  subscriber: Subscriber,
  lane: Lane,
  tier: Tier,
  expiryMs: number,
  log: Logger,
): Promise<void> {
  const tx = newLaneTx(signer, lane);
  addCreateOracle(tx, config.predictPackageId, {
    registryId: config.registryId,
    predictId: config.predictId,
    adminCapId: config.adminCapId,
    capId: lane.capId,
    underlying: config.underlying,
    expiryMs,
    minStrike: config.strikeMin,
    tickSize: config.tickSize,
  });

  const resp = await executeLaneTx(tx, lane, client, signer, log, { showEvents: true });
  if (!resp) return;

  // create_oracle does NOT register the cap arg on authorized_caps — the
  // oracle boots with an empty set. bootstrap registers all N caps.
  for (const e of parseOracleEvents(resp.events ?? [], config.predictPackageId).created) {
    if (e.expiryMs !== expiryMs) continue;
    const oracle: OracleState = {
      id: e.oracleId,
      underlying: e.underlyingAsset,
      expiryMs: e.expiryMs,
      tier,
      status: "inactive",
      registeredCapIds: new Set(),
    };
    state.oracles.set(oracle.id, oracle);
    subscriber.addOracle(oracle.id, oracle.underlying, oracle.expiryMs);
    log.info({ event: "oracle_created", oracleId: oracle.id, tier, expiryMs, txDigest: resp.digest });
  }
}

async function bootstrapOracleStep(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  lane: Lane,
  oracle: OracleState,
  log: Logger,
): Promise<void> {
  const svi = state.sviCache.get(oracle.id);
  if (!svi) return;

  const tx = newLaneTx(signer, lane);
  // Filter already-registered caps — VecSet::insert aborts on duplicates.
  const missing = state.lanes
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
  addUpdateSvi(tx, config.predictPackageId, {
    oracleId: oracle.id,
    capId: lane.capId,
    params: svi.params,
  });

  const resp = await executeLaneTx(tx, lane, client, signer, log, { oracleId: oracle.id });
  if (!resp) return;
  for (const cap of state.lanes.map((l) => l.capId)) oracle.registeredCapIds.add(cap);
  oracle.status = "active";
  svi.lastPushedAtMs = svi.receivedAtMs;
  log.info({ event: "oracle_activated", oracleId: oracle.id, txDigest: resp.digest });
}

async function settleOracleStep(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  lane: Lane,
  oracle: OracleState,
  log: Logger,
): Promise<void> {
  const now = Date.now();
  const spot = state.priceCache.spot;
  if (!spot) return;
  if (!hasFreshPriceSample(spot, now, config.priceCacheStaleMs)) {
    log.warn({
      event: "tick_skipped_stale_prices",
      oracleId: oracle.id,
      reason: "stale_spot_for_settlement",
      spotAgeMs: now - spot.receivedAtMs,
    });
    return;
  }
  // update_prices in the pending_settlement branch ignores the forward arg
  // entirely. Pass the cached forward if we have one, else fall back to spot.
  const fwd = state.priceCache.forwards.get(oracle.id);
  const forwardValue = fwd ? fwd.value : spot.value;

  const tx = newLaneTx(signer, lane);
  // Orphan rescue: past runs may have left oracles with empty authorized_caps.
  const needsRegister = !oracle.registeredCapIds.has(lane.capId);
  if (needsRegister) {
    addRegisterCap(tx, config.predictPackageId, {
      oracleId: oracle.id,
      adminCapId: config.adminCapId,
      capIdToRegister: lane.capId,
    });
  }
  addSettleNudge(tx, config.predictPackageId, {
    oracleId: oracle.id,
    capId: lane.capId,
    spot: spot.value,
    forward: forwardValue,
  });

  const resp = await executeLaneTx(tx, lane, client, signer, log, {
    oracleId: oracle.id,
    showEvents: true,
  });
  if (!resp) return;
  if (needsRegister) oracle.registeredCapIds.add(lane.capId);
  for (const e of parseOracleEvents(resp.events ?? [], config.predictPackageId).settled) {
    if (e.oracleId !== oracle.id) continue;
    oracle.status = "settled";
    log.info({
      event: "oracle_settled",
      oracleId: oracle.id,
      settlementPrice: e.settlementPrice,
      txDigest: resp.digest,
    });
  }
}

async function compactOracleStep(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  subscriber: Subscriber,
  lane: Lane,
  oracle: OracleState,
  log: Logger,
): Promise<void> {
  const tx = newLaneTx(signer, lane);
  const needsRegister = !oracle.registeredCapIds.has(lane.capId);
  if (needsRegister) {
    addRegisterCap(tx, config.predictPackageId, {
      oracleId: oracle.id,
      adminCapId: config.adminCapId,
      capIdToRegister: lane.capId,
    });
  }
  addCompact(tx, config.predictPackageId, {
    predictId: config.predictId,
    oracleId: oracle.id,
    capId: lane.capId,
  });

  const resp = await executeLaneTx(tx, lane, client, signer, log, { oracleId: oracle.id });
  if (!resp) return;
  log.info({ event: "oracle_compacted", oracleId: oracle.id, txDigest: resp.digest });
  state.oracles.delete(oracle.id);
  subscriber.removeOracle(oracle.id);
}

function newLaneTx(signer: Keypair, lane: Lane): Transaction {
  const tx = new Transaction();
  tx.setSender(signer.toSuiAddress());
  tx.setGasPayment([{
    objectId: lane.gasCoinId,
    version: lane.gasCoinVersion,
    digest: lane.gasCoinDigest,
  }]);
  return tx;
}

/// Sign, submit, check status, update lane gas coin ref. Returns undefined on
/// any failure (RPC error or non-success effects) — the caller logs nothing
/// extra and skips its post-success logic.
async function executeLaneTx(
  tx: Transaction,
  lane: Lane,
  client: SuiJsonRpcClient,
  signer: Keypair,
  log: Logger,
  ctx: { oracleId?: string; showEvents?: boolean } = {},
): Promise<SuiTransactionBlockResponse | undefined> {
  lane.available = false;
  try {
    const resp = await client.signAndExecuteTransaction({
      transaction: tx,
      signer,
      options: { showEffects: true, showEvents: !!ctx.showEvents },
    });
    if (resp.effects?.status.status !== "success") {
      log.error({
        event: "tx_failed",
        laneId: lane.id,
        oracleId: ctx.oracleId,
        txDigest: resp.digest,
        status: resp.effects?.status,
      });
      return undefined;
    }
    const mutated = resp.effects?.mutated ?? [];
    for (const ref of mutated) {
      if (ref.reference.objectId === lane.gasCoinId) {
        lane.gasCoinVersion = ref.reference.version;
        lane.gasCoinDigest = ref.reference.digest;
        break;
      }
    }
    return resp;
  } catch (err) {
    log.error({
      event: "tx_failed",
      laneId: lane.id,
      oracleId: ctx.oracleId,
      err: String(err),
    });
    return undefined;
  } finally {
    lane.available = true;
  }
}

function nextAvailableLane(state: ServiceState): Lane | undefined {
  const n = state.lanes.length;
  for (let i = 0; i < n; i++) {
    const idx = (state.laneHint + i) % n;
    const lane = state.lanes[idx];
    if (lane.available) {
      state.laneHint = (idx + 1) % n;
      return lane;
    }
  }
  return undefined;
}

export function hasFreshPriceSample(
  sample: PriceSample,
  now: number,
  staleAfterMs: number,
): boolean {
  return now - sample.receivedAtMs <= staleAfterMs;
}

export async function waitForAllLanesIdle(
  lanes: Lane[],
  timeoutMs = 15_000,
  pollMs = 100,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (lanes.every((lane) => lane.available)) return;
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
  throw new Error("manager window timed out waiting for lanes to drain");
}

type ParsedEvents = {
  created: Array<{ oracleId: string; underlyingAsset: string; expiryMs: number }>;
  settled: Array<{ oracleId: string; settlementPrice: number; timestampMs: number }>;
};

function parseOracleEvents(events: SuiEvent[], packageId: string): ParsedEvents {
  const created: ParsedEvents["created"] = [];
  const settled: ParsedEvents["settled"] = [];
  const createdType = `${packageId}::registry::OracleCreated`;
  const settledType = `${packageId}::oracle::OracleSettled`;
  for (const e of events) {
    if (e.type === createdType) {
      const p = e.parsedJson as Record<string, string>;
      created.push({
        oracleId: p.oracle_id,
        underlyingAsset: p.underlying_asset,
        expiryMs: Number(p.expiry),
      });
    } else if (e.type === settledType) {
      const p = e.parsedJson as Record<string, string>;
      settled.push({
        oracleId: p.oracle_id,
        settlementPrice: Number(p.settlement_price),
        timestampMs: Number(p.timestamp),
      });
    }
  }
  return { created, settled };
}
