// Live testnet config for the random-trade simulation. Unlike the localnet
// `simulations/` harness (which publishes its own packages, mints DUSDC, and pushes
// its own oracle updates), this targets the ALREADY-DEPLOYED testnet predict stack and
// relies on the live propbook price-pusher for fresh Pyth + Block Scholes feeds.
import { readFileSync } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { fileURLToPath } from "node:url";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { fromBase64 } from "@mysten/sui/utils";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_DEPLOY = path.resolve(HERE, "..", "..", "deploy", "deployment.testnet.json");
const ACCOUNT_DEPLOY = path.resolve(HERE, "..", "..", "..", "account", "deploy", "deployment.testnet.json");
const PROPBOOK_DEPLOY = path.resolve(HERE, "..", "..", "..", "propbook", "deploy", "deployment.testnet.json");

const load = (p: string) => JSON.parse(readFileSync(p, "utf8"));
const predict = load(PREDICT_DEPLOY);
const account = load(ACCOUNT_DEPLOY);
const propbook = load(PROPBOOK_DEPLOY);

export const RPC_URL = process.env.RPC_URL ?? "https://fullnode.testnet.sui.io:443";
export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "testnet" });

// Reserved system objects.
export const CLOCK_ID = "0x6";
export const ACCUMULATOR_ROOT_ID = "0xacc"; // sui::accumulator::AccumulatorRoot singleton

// Predict.
export const PREDICT_PACKAGE_ID: string = predict.predict_package_id;
export const REGISTRY_ID: string = predict.registry_shared_object_id;
export const PROTOCOL_CONFIG_ID: string = predict.protocol_config_shared_object_id;
export const POOL_VAULT_ID: string = predict.pool_vault_shared_object_id;
export const MIN_TICK_SIZE: bigint = BigInt(predict.min_tick_size);
// (markets) -> first market id + its expiry (the deploy created one BTC market).
const marketEntries = Object.entries(predict.markets ?? {}) as [string, string][];
export const MARKETS = marketEntries.map(([expiry, id]) => ({ expiry: BigInt(expiry), id }));

// Account framework.
export const ACCOUNT_PACKAGE_ID: string = account.account_package_id;
export const ACCOUNT_REGISTRY_ID: string = account.account_registry_shared_object_id;

// Propbook oracle.
export const ORACLE_REGISTRY_ID: string = propbook.shared_objects.oracle_registry_shared_object_id;
export const PYTH_FEED_ID: string = propbook.shared_objects.pyth_feed_shared_object_id;
export const BLOCK_SCHOLES_FEED_ID: string = propbook.shared_objects.block_scholes_feed_shared_object_id;

// Quote asset.
export const DUSDC_PACKAGE_ID: string = predict.dependencies.dusdc_package_id;
export const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;

// Contract constants mirrored from packages/predict/sources/constants.move.
export const POS_INF_TICK = (1n << 24n) - 1n; // tick_bits = 24
export const POSITION_LOT_SIZE = 10_000n;
export const FLOAT_SCALING = 1_000_000_000n; // 1x leverage
export const TICK_SIZE: bigint = MIN_TICK_SIZE; // the deploy market uses tick_size == min_tick_size

export function targetPredict(module: string, fn: string): `${string}::${string}::${string}` {
  return `${PREDICT_PACKAGE_ID}::${module}::${fn}`;
}
export function targetAccount(module: string, fn: string): `${string}::${string}::${string}` {
  return `${ACCOUNT_PACKAGE_ID}::${module}::${fn}`;
}

/** Load the active deployer keypair from the sui keystore (matched by address). */
export function getSigner(): { keypair: Ed25519Keypair; address: string } {
  const expected = predict.deployer as string;
  const keystorePath = process.env.SUI_KEYSTORE ?? path.join(os.homedir(), ".sui", "sui_config", "sui.keystore");
  const keys: string[] = JSON.parse(readFileSync(keystorePath, "utf8"));
  for (const b64 of keys) {
    const raw = fromBase64(b64);
    if (raw[0] !== 0x00) continue; // 0x00 = ed25519 scheme flag
    const kp = Ed25519Keypair.fromSecretKey(raw.slice(1));
    if (kp.getPublicKey().toSuiAddress() === expected) return { keypair: kp, address: expected };
  }
  throw new Error(`deployer keypair ${expected} not found in ${keystorePath}`);
}
