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
export const DUSDC_PACKAGE_ID = requireEnv("DUSDC_PACKAGE_ID");
export const TREASURY_CAP_ID = requireEnv("TREASURY_CAP_ID");
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
