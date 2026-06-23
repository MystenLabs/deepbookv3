/**
 * Backtesting Engine
 *
 * Simulates the signal engine against historical kline data.
 * Fetches 15m candles from Binance, runs the signal generator,
 * and tracks simulated PnL with configurable initial capital.
 *
 * Usage:
 *   npx tsx scripts/services/backtest.ts BTC 10000
 *   npx tsx scripts/services/backtest.ts ETH 5000 --days 30
 */

import axios from "axios";
import * as path from "path";
import * as fs from "fs";
import {
  MarketData,
  SignalResult,
} from "./signal_engine.ts";

interface BacktestTrade {
  timestamp: number;
  direction: "UP" | "DOWN";
  entryPrice: number;
  exitPrice: number | null;
  pnl: number;
  pnlPct: number;
  confidence: number;
  kellySize: number;
  closed: boolean;
}

/**
 * Simple public signal generator for backtesting.
 * Uses basic RSI + momentum — NOT the full private strategy.
 */
function simpleSignal(data: MarketData): SignalResult {
  const closes = data.closes;
  const len = closes.length;
  if (len < 20) {
    return { direction: "HOLD", score: 0, confidence: 0, components: { rsi: 50, ema: 0, momentum: 0, funding: 0, volume: 1, volatility: 0, ml: 0 }, kellySize: 0, session: "OFF" };
  }

  // Simple RSI
  let gains = 0, losses = 0;
  for (let i = Math.max(1, len - 14); i < len; i++) {
    const diff = closes[i] - closes[i - 1];
    if (diff > 0) gains += diff; else losses -= diff;
  }
  const rsi = losses === 0 ? 100 : 100 - 100 / (1 + gains / losses);

  // Simple momentum (5-period)
  const momentum = len >= 5 ? (closes[len - 1] - closes[len - 5]) / closes[len - 5] : 0;

  // Score
  const rsiScore = (rsi - 50) / 50;
  const momScore = Math.max(-1, Math.min(1, momentum * 15));
  const rawScore = rsiScore * 0.5 + momScore * 0.5;

  const direction = rawScore > 0.05 ? "UP" : rawScore < -0.05 ? "DOWN" : "HOLD";
  const confidence = Math.min(1, Math.abs(rawScore) * 3);
  const kellySize = confidence > 0.2 ? 0.05 : 0.02;

  return {
    direction,
    score: rawScore,
    confidence,
    components: { rsi, ema: 0, momentum, funding: 0, volume: 1, volatility: 0, ml: 0 },
    kellySize,
    session: "OFF",
  };
}

interface BacktestResult {
  asset: string;
  period: string;
  initialCapital: number;
  finalCapital: number;
  totalPnl: number;
  totalPnlPct: number;
  totalTrades: number;
  winners: number;
  losers: number;
  winRate: number;
  avgWinPnl: number;
  avgLossPnl: number;
  profitFactor: number;
  maxDrawdown: number;
  maxDrawdownPct: number;
  sharpeRatio: number;
  trades: BacktestTrade[];
}

/**
 * Fetch historical klines from Binance
 */
async function fetchHistoricalKlines(
  asset: string,
  interval: string,
  limit: number,
  startTime?: number,
): Promise<MarketData> {
  const symbol = asset === "BTC" ? "BTCUSDT" : `${asset}USDT`;
  const params: any = { symbol, interval, limit };
  if (startTime) params.startTime = startTime;

  const res = await axios.get(
    "https://api.binance.com/api/v3/klines",
    { params, timeout: 15000 },
  );

  const klines = res.data;
  if (!Array.isArray(klines) || klines.length < 20) {
    throw new Error(`Insufficient data for ${asset}: got ${klines?.length || 0} candles`);
  }

  return {
    closes: klines.map((k: any[]) => parseFloat(k[4])),
    highs: klines.map((k: any[]) => parseFloat(k[2])),
    lows: klines.map((k: any[]) => parseFloat(k[3])),
    volumes: klines.map((k: any[]) => parseFloat(k[5])),
    timestamps: klines.map((k: any[]) => k[0]),
  };
}

/**
 * Fetch all historical klines in chunks (Binance limits 1000 per request)
 */
async function fetchFullHistory(
  asset: string,
  daysBack: number,
): Promise<MarketData> {
  const now = Date.now();
  const startMs = now - daysBack * 24 * 60 * 60 * 1000;
  const interval = "15m";
  const chunkSize = 1000;

  let allCloses: number[] = [];
  let allHighs: number[] = [];
  let allLows: number[] = [];
  let allVolumes: number[] = [];
  let allTimestamps: number[] = [];

  let cursor = startMs;
  while (cursor < now) {
    const chunk = await fetchHistoricalKlines(asset, interval, chunkSize, cursor);
    if (chunk.closes.length === 0) break;

    allCloses.push(...chunk.closes);
    allHighs.push(...chunk.highs);
    allLows.push(...chunk.lows);
    allVolumes.push(...chunk.volumes);
    allTimestamps.push(...chunk.timestamps);

    // Move cursor past last candle
    cursor = chunk.timestamps[chunk.timestamps.length - 1] + 1;
    if (chunk.closes.length < chunkSize) break;

    // Rate limit: 100ms between requests
    await new Promise((r) => setTimeout(r, 100));
  }

  console.log(
    `[BACKTEST] Fetched ${allCloses.length} candles for ${asset} (${daysBack} days)`,
  );

  return {
    closes: allCloses,
    highs: allHighs,
    lows: allLows,
    volumes: allVolumes,
    timestamps: allTimestamps,
  };
}

/**
 * Run backtest simulation
 */
export async function runBacktest(
  asset: string,
  initialCapital: number,
  daysBack: number = 7,
  options: {
    positionSizePct?: number;
    confidenceThreshold?: number;
    stopLossPct?: number;
    takeProfitPct?: number;
    winRate?: number;
    avgWin?: number;
    avgLoss?: number;
  } = {},
): Promise<BacktestResult> {
  const {
    positionSizePct = 0.1,
    confidenceThreshold = 0.05,
    stopLossPct = 0.03,
    takeProfitPct = 0.05,
    winRate = 0.55,
    avgWin = 1.2,
    avgLoss = 1.0,
  } = options;

  const data = await fetchFullHistory(asset, daysBack);
  const warmupPeriod = 50; // Need enough data for RSI/EMA
  const candleIntervalMs = 15 * 60 * 1000; // 15m

  let capital = initialCapital;
  let peakCapital = initialCapital;
  let maxDrawdown = 0;
  let maxDrawdownPct = 0;
  const returns: number[] = [];

  const trades: BacktestTrade[] = [];
  let openTrade: BacktestTrade | null = null;
  let openTradePosition = 0;

  for (let i = warmupPeriod; i < data.closes.length; i++) {
    // Slice data up to current candle
    const slice: MarketData = {
      closes: data.closes.slice(0, i + 1),
      highs: data.highs.slice(0, i + 1),
      lows: data.lows.slice(0, i + 1),
      volumes: data.volumes.slice(0, i + 1),
      timestamps: data.timestamps.slice(0, i + 1),
    };

    const currentPrice = data.closes[i];
    const currentHigh = data.highs[i];
    const currentLow = data.lows[i];
    const timestamp = data.timestamps[i];

    // Close open trade if stop-loss or take-profit hit
    if (openTrade) {
      const entryPrice = openTrade.entryPrice;
      const isUp = openTrade.direction === "UP";

      let shouldClose = false;
      let exitPrice = currentPrice;

      // Stop loss
      if (isUp) {
        const dropPct = (entryPrice - currentLow) / entryPrice;
        if (dropPct >= stopLossPct) {
          shouldClose = true;
          exitPrice = entryPrice * (1 - stopLossPct);
        }
        // Take profit
        const risePct = (currentHigh - entryPrice) / entryPrice;
        if (risePct >= takeProfitPct) {
          shouldClose = true;
          exitPrice = entryPrice * (1 + takeProfitPct);
        }
      } else {
        const risePct = (currentHigh - entryPrice) / entryPrice;
        if (risePct >= stopLossPct) {
          shouldClose = true;
          exitPrice = entryPrice * (1 + stopLossPct);
        }
        const dropPct = (entryPrice - currentLow) / entryPrice;
        if (dropPct >= takeProfitPct) {
          shouldClose = true;
          exitPrice = entryPrice * (1 - takeProfitPct);
        }
      }

      // Close at candle end if position has been open for 4 candles (1 hour)
      if (i - warmupPeriod > 4 && timestamp - openTrade.timestamp > candleIntervalMs * 4) {
        shouldClose = true;
        exitPrice = currentPrice;
      }

      if (shouldClose) {
        const pnl = isUp
          ? (exitPrice - entryPrice) / entryPrice
          : (entryPrice - exitPrice) / entryPrice;

        openTrade.exitPrice = exitPrice;
        openTrade.pnlPct = pnl;
        openTrade.closed = true;

        const tradePnl = pnl * openTradePosition;
        openTrade.pnl = tradePnl;
        capital += tradePnl;

        returns.push(pnl);
        peakCapital = Math.max(peakCapital, capital);
        const dd = peakCapital - capital;
        const ddPct = dd / peakCapital;
        if (dd > maxDrawdown) maxDrawdown = dd;
        if (ddPct > maxDrawdownPct) maxDrawdownPct = ddPct;

        openTrade = null;
      }
    }

    // Open new trade if no position
    if (!openTrade && i >= warmupPeriod + 10) {
      const signal: SignalResult = simpleSignal(slice);

      if (
        signal.direction !== "HOLD" &&
        signal.confidence >= confidenceThreshold
      ) {
        const positionSize = capital * positionSizePct * Math.min(signal.kellySize * 2, 1);
        if (positionSize > 1) {
          openTradePosition = positionSize;
          openTrade = {
            timestamp,
            direction: signal.direction,
            entryPrice: currentPrice,
            exitPrice: null,
            pnl: 0,
            pnlPct: 0,
            confidence: signal.confidence,
            kellySize: signal.kellySize,
            closed: false,
          };
          trades.push(openTrade);
        }
      }
    }
  }

  // Close any remaining open trade at last price
  if (openTrade) {
    const lastPrice = data.closes[data.closes.length - 1];
    const isUp = openTrade.direction === "UP";
    const pnl = isUp
      ? (lastPrice - openTrade.entryPrice) / openTrade.entryPrice
      : (openTrade.entryPrice - lastPrice) / openTrade.entryPrice;

    openTrade.exitPrice = lastPrice;
    openTrade.pnlPct = pnl;
    openTrade.closed = true;
    const tradePnl = pnl * openTradePosition;
    openTrade.pnl = tradePnl;
    capital += tradePnl;
    returns.push(pnl);
  }

  const winners = trades.filter((t) => t.closed && t.pnlPct > 0).length;
  const losers = trades.filter((t) => t.closed && t.pnlPct <= 0).length;
  const winTrades = trades.filter((t) => t.closed && t.pnlPct > 0);
  const lossTrades = trades.filter((t) => t.closed && t.pnlPct <= 0);

  const avgWinPnl =
    winTrades.length > 0
      ? winTrades.reduce((s, t) => s + t.pnlPct, 0) / winTrades.length
      : 0;
  const avgLossPnl =
    lossTrades.length > 0
      ? lossTrades.reduce((s, t) => s + Math.abs(t.pnlPct), 0) / lossTrades.length
      : 0;

  // Profit factor
  const grossProfit = winTrades.reduce((s, t) => s + t.pnlPct, 0);
  const grossLoss = lossTrades.reduce((s, t) => s + Math.abs(t.pnlPct), 0);
  const profitFactor = grossLoss > 0 ? grossProfit / grossLoss : grossProfit > 0 ? Infinity : 0;

  // Sharpe ratio (annualized, assuming 15m candles)
  const avgReturn = returns.length > 0 ? returns.reduce((a, b) => a + b, 0) / returns.length : 0;
  const stdReturn =
    returns.length > 1
      ? Math.sqrt(
          returns.reduce((s, r) => s + (r - avgReturn) ** 2, 0) / (returns.length - 1),
        )
      : 0;
  const candlesPerYear = (365 * 24 * 60) / 15;
  const sharpeRatio =
    stdReturn > 0 ? (avgReturn / stdReturn) * Math.sqrt(candlesPerYear) : 0;

  const startDate = new Date(data.timestamps[warmupPeriod]).toISOString().slice(0, 10);
  const endDate = new Date(data.timestamps[data.timestamps.length - 1]).toISOString().slice(0, 10);

  return {
    asset,
    period: `${startDate} to ${endDate} (${daysBack}d)`,
    initialCapital,
    finalCapital: capital,
    totalPnl: capital - initialCapital,
    totalPnlPct: ((capital - initialCapital) / initialCapital) * 100,
    totalTrades: trades.length,
    winners,
    losers,
    winRate: trades.length > 0 ? (winners / trades.length) * 100 : 0,
    avgWinPnl: avgWinPnl * 100,
    avgLossPnl: avgLossPnl * 100,
    profitFactor,
    maxDrawdown,
    maxDrawdownPct: maxDrawdownPct * 100,
    sharpeRatio,
    trades,
  };
}

/**
 * Pretty-print backtest results
 */
export function printResults(result: BacktestResult): void {
  console.log("\n" + "=".repeat(60));
  console.log(`  BACKTEST RESULTS: ${result.asset}`);
  console.log("=".repeat(60));
  console.log(`  Period:            ${result.period}`);
  console.log(`  Initial Capital:   $${result.initialCapital.toLocaleString()}`);
  console.log(`  Final Capital:     $${result.finalCapital.toLocaleString()}`);
  console.log(`  Total PnL:         $${result.totalPnl.toFixed(2)} (${result.totalPnlPct.toFixed(2)}%)`);
  console.log("-".repeat(60));
  console.log(`  Total Trades:      ${result.totalTrades}`);
  console.log(`  Winners:           ${result.winners}`);
  console.log(`  Losers:            ${result.losers}`);
  console.log(`  Win Rate:          ${result.winRate.toFixed(1)}%`);
  console.log(`  Avg Win:           ${result.avgWinPnl.toFixed(2)}%`);
  console.log(`  Avg Loss:          ${result.avgLossPnl.toFixed(2)}%`);
  console.log(`  Profit Factor:     ${result.profitFactor === Infinity ? "Inf" : result.profitFactor.toFixed(2)}`);
  console.log("-".repeat(60));
  console.log(`  Max Drawdown:      $${result.maxDrawdown.toFixed(2)} (${result.maxDrawdownPct.toFixed(2)}%)`);
  console.log(`  Sharpe Ratio:      ${result.sharpeRatio.toFixed(2)}`);
  console.log("=".repeat(60));

  // Last 10 trades
  const recent = result.trades.slice(-10);
  if (recent.length > 0) {
    console.log("\n  Recent Trades:");
    console.log("  " + "-".repeat(56));
    for (const t of recent) {
      const date = new Date(t.timestamp).toISOString().slice(0, 16);
      const dir = t.direction.padEnd(4);
      const pnl = t.closed ? `${(t.pnlPct * 100).toFixed(2)}%`.padStart(8) : "  OPEN";
      const conf = `${(t.confidence * 100).toFixed(0)}%`.padStart(4);
      console.log(`  ${date}  ${dir}  conf=${conf}  pnl=${pnl}`);
    }
  }
  console.log("");
}

/**
 * Save results to JSON file
 */
export function saveResults(result: BacktestResult, filename?: string): string {
  const dir = path.join(process.cwd(), "logs");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const name = filename || `backtest_${result.asset}_${Date.now()}.json`;
  const filepath = path.join(dir, name);

  // Strip individual trades for summary file (too large)
  const summary = { ...result, trades: result.trades.length + " trades (see full log)" };
  fs.writeFileSync(filepath, JSON.stringify(summary, null, 2));
  console.log(`[BACKTEST] Results saved to ${filepath}`);
  return filepath;
}

// CLI entry point
const isMainModule =
  process.argv[1] &&
  (import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/")) ||
   process.argv[1].includes("backtest"));

if (isMainModule) {
  const asset = process.argv[2] || "BTC";
  const capital = parseFloat(process.argv[3]) || 10000;
  const daysIdx = process.argv.indexOf("--days");
  const days = daysIdx !== -1 ? parseInt(process.argv[daysIdx + 1]) || 7 : 7;

  console.log(`[BACKTEST] Running ${asset} backtest: $${capital} over ${days} days...`);

  runBacktest(asset, capital, days)
    .then((result) => {
      printResults(result);
      saveResults(result);
    })
    .catch((e) => {
      console.error("[BACKTEST] Failed:", e.message);
      process.exit(1);
    });
}
