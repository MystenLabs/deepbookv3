// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { SuiJsonRpcClient, SuiTransactionBlockResponse } from "@mysten/sui/jsonRpc";
import type { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { Logger } from "./logger";
import type { Lane, ServiceState } from "./types";
import { nextAvailableLane, releaseLane, totalPoolSui } from "./gas-pool";
import { addUpdatePrices, addUpdateSvi } from "./ptb-build";

// Minimum balance (in SUI) a lane must have to be selected for a tick. Below
// this, the lane sits out and we warn on low pool.
const LANE_MIN_SUI = 1;
const LOW_POOL_WARN_SUI = 10;

export type Executor = {
  start: () => void;
  stop: () => void;
  lastSuccessfulTickMs: () => number;
};

export function makeExecutor(
  state: ServiceState,
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  log: Logger,
): Executor {
  let timer: ReturnType<typeof setInterval> | null = null;
  let lastSuccess = 0;

  async function tick(): Promise<void> {
    state.clock.tickId += 1;
    const tickId = state.clock.tickId;

    const lane = nextAvailableLane(state.lanes, LANE_MIN_SUI);
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

    const spot = state.priceCache.spot;
    const now = Date.now();
    const spotFresh = spot && now - spot.receivedAtMs <= config.priceCacheStaleMs;

    let priceUpdates = 0;
    if (spotFresh) {
      for (const oracle of state.oracles.values()) {
        if (now >= oracle.expiryMs) continue;
        const fwd = state.priceCache.forwards.get(oracle.id);
        if (!fwd || now - fwd.receivedAtMs > config.priceCacheStaleMs) continue;
        addUpdatePrices(tx, config.predictPackageId, {
          oracleId: oracle.id,
          capId: config.oracleCapId,
          spot: spot!.value,
          forward: fwd.value,
        });
        priceUpdates++;
      }
    }

    const sviPushes: Array<{ oracleId: string; receivedAtMs: number }> = [];
    for (const oracle of state.oracles.values()) {
      if (now >= oracle.expiryMs) continue;
      const svi = state.sviCache.get(oracle.id);
      if (!svi) continue;
      if (svi.lastPushedAtMs !== null && svi.receivedAtMs <= svi.lastPushedAtMs) continue;
      addUpdateSvi(tx, config.predictPackageId, {
        oracleId: oracle.id,
        capId: config.oracleCapId,
        params: svi.params,
      });
      sviPushes.push({ oracleId: oracle.id, receivedAtMs: svi.receivedAtMs });
    }

    if (priceUpdates === 0 && sviPushes.length === 0) {
      releaseLane(lane, lane.lastTxDigest ?? "");
      log.debug({
        event: spotFresh ? "tick_skipped_empty" : "tick_skipped_stale_prices",
        tickId,
      });
      return;
    }

    lane.available = false;

    let resp: SuiTransactionBlockResponse;
    try {
      resp = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true },
      });
    } catch (err) {
      log.error({ event: "tx_failed", tickId, laneId: lane.id, err: String(err) });
      releaseLane(lane, "");
      return;
    }

    log.info({
      event: "tx_submitted",
      tickId,
      laneId: lane.id,
      txDigest: resp.digest,
      priceUpdates,
      sviPushes: sviPushes.length,
    });

    client
      .waitForTransaction({ digest: resp.digest, options: { showEffects: true } })
      .then((final) => applyTxEffects(state, final, lane, sviPushes, log))
      .catch((err) => {
        log.error({ event: "tx_failed", tickId, laneId: lane.id, txDigest: resp.digest, err: String(err) });
        releaseLane(lane, resp.digest);
      });

    lastSuccess = Date.now();

    const totalSui = totalPoolSui(state.lanes);
    if (totalSui < LOW_POOL_WARN_SUI) {
      log.warn({ event: "lane_low", totalSui });
    }
  }

  return {
    start: () => {
      timer = setInterval(
        () => { tick().catch((err) => log.error({ event: "tx_failed", err: String(err) })); },
        config.executorTickMs,
      );
    },
    stop: () => {
      if (timer) clearInterval(timer);
      timer = null;
    },
    lastSuccessfulTickMs: () => lastSuccess,
  };
}

function applyTxEffects(
  state: ServiceState,
  resp: SuiTransactionBlockResponse,
  lane: Lane,
  sviPushes: Array<{ oracleId: string; receivedAtMs: number }>,
  log: Logger,
): void {
  const success = resp.effects?.status.status === "success";
  if (!success) {
    log.error({ event: "tx_failed", txDigest: resp.digest, status: resp.effects?.status });
    releaseLane(lane, resp.digest);
    return;
  }

  for (const { oracleId, receivedAtMs } of sviPushes) {
    const sample = state.sviCache.get(oracleId);
    if (sample) sample.lastPushedAtMs = receivedAtMs;
  }

  const newGas = newGasCoinRef(resp, lane.gasCoinId);
  if (newGas) {
    lane.gasCoinVersion = newGas.version;
    lane.gasCoinDigest = newGas.digest;
    lane.gasCoinBalanceApproxMist += gasNet(resp);
  }

  releaseLane(lane, resp.digest);
  log.info({ event: "tx_finalized", laneId: lane.id, txDigest: resp.digest });
}

function newGasCoinRef(
  resp: SuiTransactionBlockResponse,
  gasCoinId: string,
): { version: string; digest: string } | undefined {
  const mutated = resp.effects?.mutated ?? [];
  for (const ref of mutated) {
    if (ref.reference.objectId === gasCoinId) {
      return { version: ref.reference.version, digest: ref.reference.digest };
    }
  }
  return undefined;
}

function gasNet(resp: SuiTransactionBlockResponse): number {
  const u = resp.effects?.gasUsed;
  if (!u) return 0;
  return Number(u.storageRebate) - Number(u.computationCost) - Number(u.storageCost) - Number(u.nonRefundableStorageFee);
}
