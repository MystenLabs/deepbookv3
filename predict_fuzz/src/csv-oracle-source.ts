/**
 * CSV oracle data source.
 *
 * Replays oracle events from indexed CSV files (the format produced by the
 * deepbook indexer). Two CSV files: prices + SVI, merged by timestamp.
 *
 * Price CSV columns:
 *   event_digest, digest, sender, checkpoint, timestamp, checkpoint_timestamp_ms,
 *   package, oracle_id, spot, forward, onchain_timestamp
 *
 * SVI CSV columns:
 *   event_digest, digest, sender, checkpoint, timestamp, checkpoint_timestamp_ms,
 *   package, oracle_id, a, b, rho, rho_negative, m, m_negative, sigma,
 *   risk_free_rate, onchain_timestamp
 *
 * Values are already scaled to FLOAT_SCALING (1e9) integers.
 */

import { readFileSync } from "fs";
import type { OracleDataSource, OracleSnapshot, ExpiryData } from "./oracle-data-source.js";

interface RawEvent {
  timestamp: number;
  oracle_id: string;
  kind: "price" | "svi";
  // Price fields
  spot?: number;
  forward?: number;
  // SVI fields
  a?: number;
  b?: number;
  rho?: number;
  rho_negative?: boolean;
  m?: number;
  m_negative?: boolean;
  sigma?: number;
  risk_free_rate?: number;
}

function parseCsv(content: string): Record<string, string>[] {
  const lines = content.trim().split("\n");
  if (lines.length < 2) return [];
  const headers = lines[0].split(",");
  return lines.slice(1).map((line) => {
    const values = line.split(",");
    const row: Record<string, string> = {};
    for (let i = 0; i < headers.length; i++) {
      row[headers[i].trim()] = (values[i] ?? "").trim();
    }
    return row;
  });
}

function loadPriceEvents(csvPath: string): RawEvent[] {
  const content = readFileSync(csvPath, "utf8");
  const rows = parseCsv(content);
  return rows.map((row) => ({
    timestamp: Number(row.onchain_timestamp),
    oracle_id: row.oracle_id,
    kind: "price" as const,
    spot: Number(row.spot),
    forward: Number(row.forward),
  }));
}

function loadSviEvents(csvPath: string): RawEvent[] {
  const content = readFileSync(csvPath, "utf8");
  const rows = parseCsv(content);
  return rows.map((row) => ({
    timestamp: Number(row.onchain_timestamp),
    oracle_id: row.oracle_id,
    kind: "svi" as const,
    a: Number(row.a),
    b: Number(row.b),
    rho: Number(row.rho),
    rho_negative: row.rho_negative === "t",
    m: Number(row.m),
    m_negative: row.m_negative === "t",
    sigma: Number(row.sigma),
    risk_free_rate: Number(row.risk_free_rate),
  }));
}

const FLOAT_SCALING = 1_000_000_000;

/**
 * CSV replay oracle data source.
 *
 * Merges price + SVI events by timestamp and yields OracleSnapshots.
 * Since CSV values are pre-scaled to FLOAT_SCALING, we convert back to floats
 * for the generic interface. The consumer will re-scale when building transactions.
 */
export class CsvOracleSource implements OracleDataSource {
  private events: RawEvent[];
  private cursor = 0;
  private oracleExpiry: string;
  private lastSpot = 0;
  private lastForward = 0;
  private lastSvi: ExpiryData["svi"] = null;
  private lastRiskFreeRate = 0.035;

  /**
   * @param pricesCsvPath Path to oracle prices CSV
   * @param sviCsvPath Path to oracle SVI CSV
   * @param expiryIso The expiry these CSVs correspond to (e.g. "2026-03-13T08:00:00Z")
   */
  constructor(pricesCsvPath: string, sviCsvPath: string, expiryIso: string) {
    const priceEvents = loadPriceEvents(pricesCsvPath);
    const sviEvents = loadSviEvents(sviCsvPath);
    this.events = [...priceEvents, ...sviEvents].sort((a, b) => a.timestamp - b.timestamp);
    this.oracleExpiry = expiryIso;
  }

  async next(): Promise<OracleSnapshot | null> {
    if (this.cursor >= this.events.length) return null;

    const event = this.events[this.cursor++];

    if (event.kind === "price") {
      this.lastSpot = event.spot! / FLOAT_SCALING;
      this.lastForward = event.forward! / FLOAT_SCALING;
    } else {
      // SVI values are already in FLOAT_SCALING integers, convert back to raw floats.
      // rho and m need sign restoration.
      const rhoSign = event.rho_negative ? -1 : 1;
      const mSign = event.m_negative ? -1 : 1;
      this.lastSvi = {
        a: event.a! / FLOAT_SCALING,
        b: event.b! / FLOAT_SCALING,
        rho: (rhoSign * event.rho!) / FLOAT_SCALING,
        m: (mSign * event.m!) / FLOAT_SCALING,
        sigma: event.sigma! / FLOAT_SCALING,
      };
      this.lastRiskFreeRate = event.risk_free_rate! / FLOAT_SCALING;
    }

    // Only emit once we have at least a spot price
    if (this.lastSpot === 0) return this.next();

    return {
      timestamp: event.timestamp,
      spot: this.lastSpot,
      expiries: [
        {
          expiry_iso: this.oracleExpiry,
          expiry_ms: new Date(this.oracleExpiry).getTime(),
          forward: this.lastForward || this.lastSpot,
          risk_free_rate: this.lastRiskFreeRate,
          svi: event.kind === "svi" ? this.lastSvi : null,
        },
      ],
    };
  }

  totalSnapshots(): number | null {
    return this.events.length;
  }

  expiries(): string[] {
    return [this.oracleExpiry];
  }
}
