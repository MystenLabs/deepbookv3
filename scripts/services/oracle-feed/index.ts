// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { SuiJsonRpcClient, type CoinStruct } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { loadConfig } from "./config";
import { makeLogger } from "./logger";
import type { Lane, OracleState, ServiceState } from "./types";
import { newLaneState } from "./gas-pool";
import { makeSubscriber } from "./subscriber";
import { makeExecutor } from "./executor";
import { makeHealthServer } from "./healthz";

// Number of gas lanes to use. One tx can be in-flight per lane. Pulumi only
// ever runs a single replica, so 3 lanes is a comfortable head room for
// parallel price + SVI txs without burning excess gas coins.
const LANE_COUNT = 3;

async function main(): Promise<void> {
  const config = loadConfig();
  const log = makeLogger("service");
  log.info({
    event: "service_started",
    network: config.network,
    oracleCount: config.oracles.length,
  });

  const client = new SuiJsonRpcClient({ url: config.suiRpcUrl, network: config.network });

  const { secretKey } = decodeSuiPrivateKey(config.suiSignerKey);
  const signer = Ed25519Keypair.fromSecretKey(secretKey);
  const address = signer.toSuiAddress();

  const coins = await getTopSuiCoins(client, address, LANE_COUNT);
  if (coins.length < LANE_COUNT) {
    throw new Error(
      `Signer ${address} has ${coins.length} SUI coin(s) but ${LANE_COUNT} lanes are needed. ` +
      `Split a coin via the Sui CLI or fund more gas.`,
    );
  }
  const lanes: Lane[] = coins.map((coin, i) => ({
    id: i,
    gasCoinId: coin.coinObjectId,
    gasCoinVersion: coin.version,
    gasCoinDigest: coin.digest,
    gasCoinBalanceApproxMist: Number(coin.balance),
    available: true,
    lastTxDigest: null,
  }));

  const oracles = new Map<string, OracleState>();
  for (const entry of config.oracles) {
    oracles.set(entry.oracleId, {
      id: entry.oracleId,
      underlying: entry.underlying,
      expiryMs: entry.expiryMs,
    });
    log.info({
      event: "oracle_loaded",
      oracleId: entry.oracleId,
      underlying: entry.underlying,
      expiry: entry.expiry,
    });
  }

  const state: ServiceState = {
    oracles,
    priceCache: { spot: null, forwards: new Map() },
    sviCache: new Map(),
    lanes: newLaneState(lanes),
    clock: { tickId: 0 },
  };

  const subscriber = makeSubscriber(config, state.priceCache, state.sviCache, makeLogger("subscriber"));
  for (const oracle of state.oracles.values()) {
    subscriber.addOracle(oracle.id, oracle.underlying, oracle.expiryMs);
  }
  subscriber.start();

  const executor = makeExecutor(state, client, signer, config, makeLogger("executor"));
  executor.start();

  const health = makeHealthServer(config.healthzPort, subscriber, executor, makeLogger("healthz"));
  health.start();

  const shutdown = (sig: string) => {
    log.info({ event: "service_shutdown", signal: sig });
    executor.stop();
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

async function getTopSuiCoins(
  client: SuiJsonRpcClient,
  address: string,
  count: number,
): Promise<CoinStruct[]> {
  const out: CoinStruct[] = [];
  let cursor: string | null | undefined = null;
  do {
    const resp = await client.getCoins({ owner: address, coinType: "0x2::sui::SUI", cursor });
    out.push(...resp.data);
    cursor = resp.hasNextPage ? resp.nextCursor : null;
  } while (cursor);
  out.sort((a, b) => Number(BigInt(b.balance) - BigInt(a.balance)));
  return out.slice(0, count);
}

main().catch((err) => {
  console.error("fatal:", err);
  process.exit(1);
});
