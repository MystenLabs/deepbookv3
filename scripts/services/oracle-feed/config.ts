// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { getJsonRpcFullnodeUrl } from "@mysten/sui/jsonRpc";
import {
  predictPackageID,
  predictRegistryID,
  predictObjectID,
  predictAdminCapID,
} from "../../config/constants.js";
import type { Tier } from "./types";

export type Network = "testnet" | "mainnet";

export type Config = {
  network: Network;
  suiRpcUrl: string;
  suiSignerKey: string;
  predictPackageId: string;
  registryId: string;
  predictId: string;
  adminCapId: string;
  blockscholesApiKey: string;
  blockscholesWsUrl: string;
  tiersEnabled: Tier[];
  expiriesPerTier: number;
  minLookaheadMs: number;
  underlying: string;
  strikeMin: number;
  strikeMax: number;
  tickSize: number;
  laneCount: number;
  gasPoolFloorSui: number;
  logLevel: string;
  pushTickMs: number;
  managerIntervalMs: number;
  priceCacheStaleMs: number;
  safetyWindowMs: number;
  healthzPort: number;
};

const BLOCKSCHOLES_WS_URL = "wss://prod-websocket-api.blockscholes.com/";
const TIERS_ENABLED: Tier[] = ["15m", "1h", "1d", "1w"];
const EXPIRIES_PER_TIER = 4;

// BlockScholes rejects mark.px for short-dated flex expiries; force the first
// rotated expiry out at least 1h so subscribes succeed.
const MIN_LOOKAHEAD_MS = 60 * 60 * 1000;

const UNDERLYING = "BTC";
const STRIKE_MIN_SCALED = 50_000 * 1_000_000_000;
const STRIKE_MAX_SCALED = 150_000 * 1_000_000_000;
const TICK_SIZE_SCALED = 1 * 1_000_000_000;

// OracleSVICap is an owned object; parallel txs need distinct caps per lane.
const LANE_COUNT = 10;
const GAS_POOL_FLOOR_SUI = 20;
const PUSH_TICK_MS = 1_000;
const MANAGER_INTERVAL_MS = 5 * 60_000;
const PRICE_CACHE_STALE_MS = 3_000;
// Drop oracles from push batches within this window of expiry — prevents
// in-flight tx from racing on-chain settlement.
const SAFETY_WINDOW_MS = 5_000;
const HEALTHZ_PORT = 8080;

function required(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

function parseTiers(raw: string): Tier[] {
  const allowed: Tier[] = ["15m", "1h", "1d", "1w"];
  const parts = raw.split(",").map((s) => s.trim()).filter(Boolean);
  for (const p of parts) {
    if (!allowed.includes(p as Tier)) throw new Error(`Invalid tier in ORACLE_TIERS: ${p}`);
  }
  return parts as Tier[];
}

export function loadConfig(): Config {
  const network = required("NETWORK") as Network;
  if (network !== "testnet" && network !== "mainnet") {
    throw new Error(`Invalid NETWORK: ${network}`);
  }

  const packageId = predictPackageID[network];
  const registryId = predictRegistryID[network];
  const predictId = predictObjectID[network];
  const adminCapId = predictAdminCapID[network];
  if (!packageId || !registryId || !predictId || !adminCapId) {
    throw new Error(
      `predict package/registry/object/adminCap not set for ${network} in ` +
        `constants.ts — run pnpm predict-redeploy first.`,
    );
  }

  return {
    network,
    suiRpcUrl: process.env.RPC_URL ?? getJsonRpcFullnodeUrl(network),
    suiSignerKey: required("PRIVATE_KEY"),
    predictPackageId: packageId,
    registryId,
    predictId,
    adminCapId,
    blockscholesApiKey: required("BLOCKSCHOLES_API_KEY"),
    blockscholesWsUrl: BLOCKSCHOLES_WS_URL,
    tiersEnabled: process.env.ORACLE_TIERS ? parseTiers(process.env.ORACLE_TIERS) : TIERS_ENABLED,
    expiriesPerTier: process.env.EXPIRIES_PER_TIER
      ? Math.max(1, parseInt(process.env.EXPIRIES_PER_TIER, 10))
      : EXPIRIES_PER_TIER,
    minLookaheadMs: process.env.MIN_LOOKAHEAD_MS
      ? Math.max(0, parseInt(process.env.MIN_LOOKAHEAD_MS, 10))
      : MIN_LOOKAHEAD_MS,
    underlying: UNDERLYING,
    strikeMin: STRIKE_MIN_SCALED,
    strikeMax: STRIKE_MAX_SCALED,
    tickSize: TICK_SIZE_SCALED,
    laneCount: process.env.LANE_COUNT
      ? Math.max(1, parseInt(process.env.LANE_COUNT, 10))
      : LANE_COUNT,
    gasPoolFloorSui: GAS_POOL_FLOOR_SUI,
    logLevel: process.env.LOG_LEVEL ?? "info",
    pushTickMs: PUSH_TICK_MS,
    managerIntervalMs: MANAGER_INTERVAL_MS,
    priceCacheStaleMs: PRICE_CACHE_STALE_MS,
    safetyWindowMs: SAFETY_WINDOW_MS,
    healthzPort: HEALTHZ_PORT,
  };
}
