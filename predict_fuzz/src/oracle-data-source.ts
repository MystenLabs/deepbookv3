/**
 * Generic oracle data source interface.
 *
 * Abstracts over CSV replay, parquet replay, and live Block Scholes feeds.
 * The consumer doesn't care where the data comes from — the interface is the same.
 */

import type { ScaledSVIParams } from "./types.js";

/** A single oracle snapshot at a point in time, containing prices + SVI for one or more expiries. */
export interface OracleSnapshot {
  /** Timestamp in milliseconds (on-chain timestamp for replays, Date.now() for live). */
  timestamp: number;
  /** BTC spot price in USD (float). */
  spot: number;
  /** Per-expiry data: forward price + SVI params. */
  expiries: ExpiryData[];
}

export interface ExpiryData {
  /** Expiry ISO string, e.g. "2026-01-14T08:00:00Z" */
  expiry_iso: string;
  /** Expiry as epoch ms */
  expiry_ms: number;
  /** Forward price in USD (float) */
  forward: number;
  /** Risk-free rate as float (e.g. 0.0422) */
  risk_free_rate: number;
  /** Raw SVI params (floats) — null if this snapshot only has prices */
  svi: {
    a: number;
    b: number;
    rho: number;
    m: number;
    sigma: number;
  } | null;
}

/** Scale a float to u64 using FLOAT_SCALING (1e9). */
export function scaleToU64(value: number): bigint {
  return BigInt(Math.round(value * 1e9));
}

/** Scale raw SVI params to on-chain format (magnitude + is_negative). */
export function scaleExpiryData(data: ExpiryData): {
  forward: bigint;
  risk_free_rate: bigint;
  svi: ScaledSVIParams | null;
} {
  return {
    forward: scaleToU64(data.forward),
    risk_free_rate: scaleToU64(data.risk_free_rate),
    svi: data.svi
      ? {
          a: scaleToU64(data.svi.a),
          b: scaleToU64(data.svi.b),
          rho: scaleToU64(Math.abs(data.svi.rho)),
          rho_negative: data.svi.rho < 0,
          m: scaleToU64(Math.abs(data.svi.m)),
          m_negative: data.svi.m < 0,
          sigma: scaleToU64(data.svi.sigma),
        }
      : null,
  };
}

/**
 * Oracle data source — yields snapshots one at a time.
 *
 * Implementations:
 * - CsvOracleSource: replays from indexed oracle event CSVs
 * - ParquetOracleSource: replays from Block Scholes parquet data
 * - LiveOracleSource: fetches live from Block Scholes API (existing oracle-updater logic)
 */
export interface OracleDataSource {
  /** Fetch the next oracle snapshot, or null if exhausted. */
  next(): Promise<OracleSnapshot | null>;
  /** Total number of snapshots (if known). Used for progress reporting. */
  totalSnapshots(): number | null;
  /** Available expiry ISO strings in this data source. */
  expiries(): string[];
}
