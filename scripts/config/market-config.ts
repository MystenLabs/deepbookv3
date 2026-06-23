import * as fs from "fs";
import * as path from "path";

export interface MarketConfig {
  asset: string;
  oracleEnvKey: string;
  quoteAssetEnvKey: string;
  minStrikeEnvKey: string;
  tickSizeEnvKey: string;
  defaults: {
    minStrike: string;
    tickSize: string;
  };
  enabled: boolean;
}

export interface TradingConfig {
  cycleIntervalMs: number;
  maxPositionFraction: number;
  kellyFraction: number;
  confidenceThreshold: number;
  claimRetryLimit: number;
  oracleRotationBufferMinutes: number;
}

export interface SignalConfig {
  rsiPeriod: number;
  emaFast: number;
  emaSlow: number;
  atrPeriod: number;
  volumePeriod: number;
  momentumPeriod: number;
  weights: {
    rsi: number;
    ema: number;
    momentum: number;
    volume: number;
    volatility: number;
    ml: number;
  };
}

export interface PredictConfig {
  version: string;
  description: string;
  markets: MarketConfig[];
  trading: TradingConfig;
  signal: SignalConfig;
}

const CONFIG_PATH = path.join(__dirname, "markets.json");

let _cachedConfig: PredictConfig | null = null;

export function loadConfig(): PredictConfig {
  if (_cachedConfig) return _cachedConfig;

  if (!fs.existsSync(CONFIG_PATH)) {
    throw new Error(`Config not found: ${CONFIG_PATH}`);
  }

  const raw = fs.readFileSync(CONFIG_PATH, "utf8");
  _cachedConfig = JSON.parse(raw) as PredictConfig;

  console.log(
    `[CONFIG] Loaded ${_cachedConfig.markets.filter((m) => m.enabled).length} enabled markets from markets.json`,
  );
  return _cachedConfig;
}

export function reloadConfig(): PredictConfig {
  _cachedConfig = null;
  return loadConfig();
}

/**
 * Resolve market config by reading env vars with fallback to defaults.
 * Markets with missing oracle IDs are auto-disabled.
 */
export function resolveMarkets(config: PredictConfig) {
  const getEnv = (key: string, fallback?: string) => process.env[key] || fallback;

  return config.markets
    .filter((m) => m.enabled)
    .map((m) => {
      const oracleId = getEnv(m.oracleEnvKey, "");
      const quoteAsset = getEnv(m.quoteAssetEnvKey, "");
      const minStrike = BigInt(getEnv(m.minStrikeEnvKey, m.defaults.minStrike));
      const tickSize = BigInt(getEnv(m.tickSizeEnvKey, m.defaults.tickSize));

      if (!oracleId) {
        console.warn(`[CONFIG] ${m.asset} disabled: ${m.oracleEnvKey} not set`);
        return null;
      }

      return {
        asset: m.asset,
        oracleId,
        quoteAsset,
        minStrike,
        tickSize,
      };
    })
    .filter(Boolean) as Array<{
    asset: string;
    oracleId: string;
    quoteAsset: string;
    minStrike: bigint;
    tickSize: bigint;
  }>;
}
