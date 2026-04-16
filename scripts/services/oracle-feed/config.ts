// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { getJsonRpcFullnodeUrl } from "@mysten/sui/jsonRpc";
import {
  predictPackageID,
  predictOracleCapID,
} from "../../config/constants.js";
import {
  predictOracles,
  type OracleEntry,
} from "../../config/predict-oracles.js";

export type Network = "testnet" | "mainnet";

export type Config = {
  network: Network;
  suiRpcUrl: string;
  suiSignerKey: string;

  predictPackageId: string;
  oracleCapId: string;
  oracles: OracleEntry[];

  blockscholesApiKey: string;
  blockscholesWsUrl: string;

  logLevel: string;
  executorTickMs: number;
  priceCacheStaleMs: number;
  intentMaxRetries: number;
  healthzPort: number;
};

// Tuning knobs. Stable across deploys — baked into the image.
const BLOCKSCHOLES_WS_URL = "wss://prod-websocket-api.blockscholes.com/";
const EXECUTOR_TICK_MS = 1_000;
const PRICE_CACHE_STALE_MS = 3_000;
const INTENT_MAX_RETRIES = 5;
const HEALTHZ_PORT = 8080;

function required(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

export function loadConfig(): Config {
  const network = required("NETWORK") as Network;
  if (network !== "testnet" && network !== "mainnet") {
    throw new Error(`Invalid NETWORK: ${network}`);
  }

  const packageId = predictPackageID[network];
  const capId = predictOracleCapID[network];
  const oracles = predictOracles[network];
  if (!packageId || !capId) {
    throw new Error(
      `predictPackageID / predictOracleCapID not set for ${network} in constants.ts — run pnpm predict-redeploy first.`,
    );
  }
  if (oracles.length === 0) {
    throw new Error(
      `predictOracles[${network}] is empty in predict-oracles.ts — run pnpm predict-deploy-oracles first.`,
    );
  }

  return {
    network,
    suiRpcUrl: process.env.RPC_URL ?? getJsonRpcFullnodeUrl(network),
    suiSignerKey: required("PRIVATE_KEY"),

    predictPackageId: packageId,
    oracleCapId: capId,
    oracles,

    blockscholesApiKey: required("BLOCKSCHOLES_API_KEY"),
    blockscholesWsUrl: BLOCKSCHOLES_WS_URL,

    logLevel: process.env.LOG_LEVEL ?? "info",
    executorTickMs: EXECUTOR_TICK_MS,
    priceCacheStaleMs: PRICE_CACHE_STALE_MS,
    intentMaxRetries: INTENT_MAX_RETRIES,
    healthzPort: HEALTHZ_PORT,
  };
}
