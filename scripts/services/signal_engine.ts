/**
 * Signal Engine — Public Interface
 *
 * Full implementation is private. This module exports the types
 * and a stub generator for testing and integration.
 */

export interface MarketData {
  closes: number[];
  highs: number[];
  lows: number[];
  volumes: number[];
  timestamps: number[];
}

export interface SignalResult {
  direction: "UP" | "DOWN" | "HOLD";
  score: number;
  confidence: number;
  components: {
    rsi: number;
    ema: number;
    momentum: number;
    funding: number;
    volume: number;
    volatility: number;
    ml: number;
  };
  kellySize: number;
  session: "ASIAN" | "EU" | "US" | "OFF";
}

/**
 * Generate signal from market data.
 * Full implementation uses: RSI (14), EMA crossover (9/21),
 * ATR volatility filter, volume profile, ML ensemble, Kelly sizing.
 */
export function generateSignal(
  data: MarketData,
  winRate: number = 0.55,
  avgWin: number = 1.2,
  avgLoss: number = 1.0,
): SignalResult {
  // Public stub — returns HOLD with zero confidence.
  // Full implementation available in private repository.
  return {
    direction: "HOLD",
    score: 0,
    confidence: 0,
    components: {
      rsi: 50,
      ema: 0,
      momentum: 0,
      funding: 0,
      volume: 1,
      volatility: 0,
      ml: 0,
    },
    kellySize: 0,
    session: "OFF",
  };
}

/**
 * Fetch market data from exchange APIs.
 */
export async function fetchMarketData(asset: string): Promise<MarketData> {
  // Public stub — throws in public version.
  // Full implementation fetches from Binance/Bybit with fallback chain.
  throw new Error(
    `fetchMarketData(${asset}) — full implementation is private`,
  );
}

/**
 * Fetch funding rate from exchange APIs.
 */
export async function fetchFundingRate(asset: string): Promise<number> {
  throw new Error(
    `fetchFundingRate(${asset}) — full implementation is private`,
  );
}
