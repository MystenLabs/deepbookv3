import type { Tier } from "./types";
import { ALL_TIERS } from "./types";

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

  strikeMin: number;
  strikeMax: number;
  tickSize: number;

  gasPoolFloorSui: number;
  laneCreateReserveSui: number;
  laneMinSui: number;
  laneCount: number;

  logLevel: string;
  executorTickMs: number;
  rotationTickMs: number;
  priceCacheStaleMs: number;
  wsPingIntervalMs: number;
  wsPongTimeoutMs: number;
  intentMaxRetries: number;
  healthzPort: number;
};

function required(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

function optional(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

function optionalInt(key: string, fallback: number): number {
  const value = process.env[key];
  if (value === undefined) return fallback;
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`Invalid number for ${key}: ${value}`);
  return n;
}

function parseTiers(raw: string): Tier[] {
  const parts = raw.split(",").map((s) => s.trim()).filter(Boolean);
  for (const p of parts) {
    if (!ALL_TIERS.includes(p as Tier)) throw new Error(`Unknown tier: ${p}`);
  }
  return parts as Tier[];
}

function defaultRpc(network: Network): string {
  return network === "mainnet"
    ? "https://fullnode.mainnet.sui.io"
    : "https://fullnode.testnet.sui.io";
}

export function loadConfig(): Config {
  const network = required("NETWORK") as Network;
  if (network !== "testnet" && network !== "mainnet") {
    throw new Error(`Invalid NETWORK: ${network}`);
  }
  return {
    network,
    suiRpcUrl: optional("SUI_RPC_URL", defaultRpc(network)),
    suiSignerKey: required("SUI_SIGNER_KEY"),
    predictPackageId: required("PREDICT_PACKAGE_ID"),
    registryId: required("REGISTRY_ID"),
    predictId: required("PREDICT_ID"),
    adminCapId: required("ADMIN_CAP_ID"),

    blockscholesApiKey: required("BLOCKSCHOLES_API_KEY"),
    blockscholesWsUrl: optional("BLOCKSCHOLES_WS_URL", "wss://prod-websocket-api.blockscholes.com/"),

    tiersEnabled: parseTiers(optional("TIERS_ENABLED", "15m,1h,1d,1w")),

    strikeMin: optionalInt("STRIKE_MIN", 50_000),
    strikeMax: optionalInt("STRIKE_MAX", 150_000),
    tickSize: optionalInt("TICK_SIZE", 1),

    gasPoolFloorSui: optionalInt("GAS_POOL_FLOOR_SUI", 600),
    laneCreateReserveSui: optionalInt("LANE_CREATE_RESERVE_SUI", 5),
    laneMinSui: optionalInt("LANE_MIN_SUI", 1),
    laneCount: optionalInt("LANE_COUNT", 20),

    logLevel: optional("LOG_LEVEL", "info"),
    executorTickMs: optionalInt("EXECUTOR_TICK_MS", 1000),
    rotationTickMs: optionalInt("ROTATION_TICK_MS", 60_000),
    priceCacheStaleMs: optionalInt("PRICE_CACHE_STALE_MS", 3000),
    wsPingIntervalMs: optionalInt("WS_PING_INTERVAL_MS", 20_000),
    wsPongTimeoutMs: optionalInt("WS_PONG_TIMEOUT_MS", 10_000),
    intentMaxRetries: optionalInt("INTENT_MAX_RETRIES", 5),
    healthzPort: optionalInt("HEALTHZ_PORT", 8080),
  };
}
