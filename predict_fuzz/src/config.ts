import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import path from "path";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.resolve(ROOT, "../.env");

function loadEnvFile(): Record<string, string> {
  if (!existsSync(ENV_PATH)) return {};
  const lines = readFileSync(ENV_PATH, "utf8").replace(/\r/g, "").split("\n");
  const env: Record<string, string> = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIdx = trimmed.indexOf("=");
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    let value = trimmed.slice(eqIdx + 1).trim();
    // Strip surrounding quotes
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
  return env;
}

const envVars = loadEnvFile();

function requireEnv(name: string): string {
  const value = envVars[name] || process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name} (check ${ENV_PATH})`);
  return value;
}

function optionalEnv(name: string, fallback: string): string {
  return envVars[name] || process.env[name] || fallback;
}

// Wallet private keys (suiprivkey format)
export const DEPLOYER_KEY = requireEnv("DEPLOYER_KEY");
export const ORACLE_KEY = requireEnv("ORACLE_KEY");
export const MINTER_KEY = requireEnv("MINTER_KEY");

// DUSDC (set after init)
export const DUSDC_PACKAGE_ID = optionalEnv("DUSDC_PACKAGE_ID", "");
export const TREASURY_CAP_ID = optionalEnv("TREASURY_CAP_ID", "");

// Block Scholes
export const BLOCKSCHOLES_API_KEY = requireEnv("BLOCKSCHOLES_API_KEY");

// Network
export const SUI_RPC_URL = optionalEnv("SUI_RPC_URL", "https://fullnode.testnet.sui.io:443");

// Constants
export const FLOAT_SCALING = 1_000_000_000n; // 1e9
export const DUSDC_DECIMALS = 6;
export const RISK_FREE_RATE = 35_000_000n; // 3.5% in FLOAT_SCALING
export const CLOCK_ID = "0x6";

// Fuzz parameters
export const TARGET_NOTIONAL_MIN = 5_000_000;    // $5 in DUSDC base units
export const TARGET_NOTIONAL_MAX = 200_000_000;   // $200 in DUSDC base units
export const ORACLES_PER_PACKAGE = 3;
export const MINTS_PER_ORACLE = 3;
export const GAS_POOL_BUFFER = 10;
export const GAS_COIN_AMOUNT = 500_000_000n;       // 0.5 SUI in MIST

// Logging
export const LOG_LEVEL = optionalEnv("LOG_LEVEL", "info") as "debug" | "info" | "warn" | "error";

// Paths (relative to predict_fuzz/)
export const PROJECT_ROOT = path.resolve(ROOT, "..");
export const MANIFEST_PATH = path.resolve(PROJECT_ROOT, "packages.json");
export const MANIFEST_LOCK_PATH = path.resolve(PROJECT_ROOT, "packages.json.lock");
export const DIGESTS_DIR = path.resolve(PROJECT_ROOT, "digests");
export const REPLAYS_DIR = path.resolve(PROJECT_ROOT, "replays");
export const ORACLE_DATA_DIR = path.resolve(PROJECT_ROOT, "oracle-data");
export const LOGS_DIR = path.resolve(PROJECT_ROOT, "logs");
export const ANALYSIS_DIR = path.resolve(PROJECT_ROOT, "analysis");
export const ENV_PATH_EXPORT = ENV_PATH;

// Helper to reload DUSDC config after init
export function getDusdcConfig(): { packageId: string; treasuryCapId: string } {
  const reloaded = loadEnvFile();
  const packageId = reloaded.DUSDC_PACKAGE_ID || DUSDC_PACKAGE_ID;
  const treasuryCapId = reloaded.TREASURY_CAP_ID || TREASURY_CAP_ID;
  if (!packageId) throw new Error("DUSDC_PACKAGE_ID not set. Run init first.");
  if (!treasuryCapId) throw new Error("TREASURY_CAP_ID not set. Run init first.");
  return { packageId, treasuryCapId };
}

export function getDusdcType(): string {
  const { packageId } = getDusdcConfig();
  return `${packageId}::dusdc::DUSDC`;
}
