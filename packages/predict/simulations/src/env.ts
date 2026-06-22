import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { fromBase64 } from "@mysten/sui/utils";

function resolveInstanceDir(): string {
  const dir = process.env.INSTANCE_DIR;
  if (dir) return dir;
  return fileURLToPath(new URL("..", import.meta.url));
}

const instanceDir = resolveInstanceDir();
const ENV_FILE = path.join(instanceDir, ".env.localnet");
const DEFAULT_KEYSTORE_PATH = path.join(instanceDir, "localnet", "sui.keystore");

function loadEnv(): Record<string, string> {
  const lines = readFileSync(ENV_FILE, "utf8").replace(/\r/g, "").split("\n");
  const env: Record<string, string> = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const [key, ...rest] = line.split("=");
    if (key && rest.length) env[key.trim()] = rest.join("=").trim();
  }
  return env;
}

function requireEnv(name: string): string {
  const value = env[name];
  if (!value) {
    throw new Error(`Missing ${name} in ${ENV_FILE}`);
  }
  return value;
}

const env = loadEnv();

export const PACKAGE_ID = requireEnv("PACKAGE_ID");
export const REGISTRY_ID = requireEnv("REGISTRY_ID");
export const ADMIN_CAP_ID = requireEnv("ADMIN_CAP_ID");
// The `account` package (deterministic accounts that replace the predict manager) is
// published transitively with predict. `PredictApp` is authorized on the registry by
// run.sh, so only the package + registry ids are needed at runtime.
export const ACCOUNT_PACKAGE_ID = requireEnv("ACCOUNT_PACKAGE_ID");
export const ACCOUNT_REGISTRY_ID = requireEnv("ACCOUNT_REGISTRY_ID");
export const PROTOCOL_CONFIG_ID = requireEnv("PROTOCOL_CONFIG_ID");
export const POOL_VAULT_ID = requireEnv("POOL_VAULT_ID");
// `predict_math` was renamed to `fixed_math` (package + named address).
export const FIXED_MATH_PACKAGE_ID = requireEnv("FIXED_MATH_PACKAGE_ID");
// propbook owns the extracted Pyth + Block Scholes feeds; its `OracleRegistry` is
// created and shared at propbook publish (package init).
export const PROPBOOK_PACKAGE_ID = requireEnv("PROPBOOK_PACKAGE_ID");
export const ORACLE_REGISTRY_ID = requireEnv("ORACLE_REGISTRY_ID");
// propbook `RegistryAdminCap`, minted to the publisher at propbook init. Needed to
// admin-bind the Pyth + BS feeds to a canonical underlying before market creation.
export const ORACLE_REGISTRY_ADMIN_CAP_ID = requireEnv("ORACLE_REGISTRY_ADMIN_CAP_ID");
// STUB Block Scholes signed-data verifier package (mints the verified `Update`).
export const BLOCK_SCHOLES_ORACLE_PACKAGE_ID = requireEnv("BLOCK_SCHOLES_ORACLE_PACKAGE_ID");
export const DUSDC_PACKAGE_ID = requireEnv("DUSDC_PACKAGE_ID");
export const DUSDC_CURRENCY_ID = requireEnv("DUSDC_CURRENCY_ID");
export const TREASURY_CAP_ID = requireEnv("TREASURY_CAP_ID");
export const WORMHOLE_PACKAGE_ID = requireEnv("WORMHOLE_PACKAGE_ID");
export const WORMHOLE_STATE_ID = requireEnv("WORMHOLE_STATE_ID");
export const PYTH_LAZER_PACKAGE_ID = requireEnv("PYTH_LAZER_PACKAGE_ID");
export const PYTH_LAZER_STATE_ID = requireEnv("PYTH_LAZER_STATE_ID");
export const LOCAL_PYTH_GOVERNANCE_CHAIN = Number(requireEnv("LOCAL_PYTH_GOVERNANCE_CHAIN"));
export const LOCAL_PYTH_GOVERNANCE_CONTRACT = requireEnv("LOCAL_PYTH_GOVERNANCE_CONTRACT");
export const LOCAL_PYTH_RECEIVER_CHAIN = Number(requireEnv("LOCAL_PYTH_RECEIVER_CHAIN"));
export const LOCAL_PYTH_GUARDIAN_PRIVATE_KEY = requireEnv("LOCAL_PYTH_GUARDIAN_PRIVATE_KEY");
export const LOCAL_PYTH_SIGNER_PRIVATE_KEY = requireEnv("LOCAL_PYTH_SIGNER_PRIVATE_KEY");
export const LOCAL_PYTH_SIGNER_PUBLIC_KEY = requireEnv("LOCAL_PYTH_SIGNER_PUBLIC_KEY");
export const LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS = requireEnv(
  "LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS",
);
export const ACTIVE_ADDRESS = requireEnv("ACTIVE_ADDRESS");
export const RPC_URL = requireEnv("RPC_URL");
export const KEYSTORE_PATH = env.KEYSTORE_PATH
  ? path.resolve(env.KEYSTORE_PATH)
  : DEFAULT_KEYSTORE_PATH;

export function getSigner(): Ed25519Keypair {
  const keystore = JSON.parse(readFileSync(KEYSTORE_PATH, "utf8"));

  for (const priv of keystore) {
    const raw = fromBase64(priv);
    if (raw[0] !== 0) continue;
    const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
    if (pair.getPublicKey().toSuiAddress() === ACTIVE_ADDRESS) {
      return pair;
    }
  }

  throw new Error(`Keypair not found for ${ACTIVE_ADDRESS}`);
}
