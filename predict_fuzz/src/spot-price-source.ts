/**
 * Spot price source for fuzz worker.
 *
 * The fuzz worker only needs a BTC spot price to generate reasonable strikes.
 * This interface abstracts over live Block Scholes API vs CSV replay.
 */

import { readFileSync } from "fs";

export interface SpotPriceSource {
  /** Get the current spot price in USD. Returns null if exhausted. */
  next(): Promise<number | null>;
}

/**
 * Live spot price from Block Scholes API.
 * Wraps the existing fetchSpotPrice() with polling.
 */
export class LiveSpotSource implements SpotPriceSource {
  private fetchFn: () => Promise<number>;

  constructor(fetchFn: () => Promise<number>) {
    this.fetchFn = fetchFn;
  }

  async next(): Promise<number | null> {
    return this.fetchFn();
  }
}

/**
 * CSV spot price replay.
 *
 * Accepts any CSV with a header row. Specify which column contains the price.
 * Timestamps are optional — if present, used for logging only.
 *
 * Supported formats:
 *   - Simple: timestamp,price
 *   - OHLCV: Date,Open,High,Low,Close,Volume  (uses Close by default)
 *   - Custom: specify priceColumn name
 */
export class CsvSpotSource implements SpotPriceSource {
  private prices: number[];
  private cursor = 0;

  /**
   * @param csvPath Path to CSV file
   * @param priceColumn Column name containing the price (default: auto-detect)
   */
  constructor(csvPath: string, priceColumn?: string) {
    const content = readFileSync(csvPath, "utf8");
    const lines = content.trim().split("\n");
    if (lines.length < 2) throw new Error(`CSV has no data rows: ${csvPath}`);

    const headers = lines[0].split(",").map((h) => h.trim());

    // Auto-detect price column
    const col =
      priceColumn ??
      headers.find((h) => /^(close|price|spot|Close)$/i.test(h)) ??
      headers[1]; // fallback to second column

    const colIdx = headers.indexOf(col);
    if (colIdx === -1) {
      throw new Error(
        `Column "${col}" not found in CSV. Available: ${headers.join(", ")}`,
      );
    }

    this.prices = lines.slice(1).map((line) => {
      const value = line.split(",")[colIdx]?.trim();
      const num = Number(value);
      if (isNaN(num)) throw new Error(`Invalid price value: "${value}" in ${csvPath}`);
      return num;
    });
  }

  async next(): Promise<number | null> {
    if (this.cursor >= this.prices.length) return null;
    return this.prices[this.cursor++];
  }

  total(): number {
    return this.prices.length;
  }
}
