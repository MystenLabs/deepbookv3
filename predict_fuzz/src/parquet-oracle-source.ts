/**
 * Parquet oracle data source.
 *
 * Replays oracle data from Block Scholes parquet exports.
 *
 * File structure: {scenario}/year=YYYY/month=MM/data.zstd.parquet
 * Scenarios: gap_up, drift_down, sideways
 *
 * Parquet schema:
 *   - qualified_name: varchar (e.g. "v2composite.option.BTC.SVI.listed.live.params")
 *   - isodate: varchar (snapshot timestamp, e.g. "2026-01-13T18:54:40.000Z")
 *   - params: varchar (JSON array of per-expiry entries)
 *   - year: bigint (partition)
 *   - month: varchar (partition)
 *
 * Each params entry:
 *   { expiry_str, forward, rd, spot, svi_a, svi_b, svi_m, svi_rho, svi_sigma }
 *
 * Note: This implementation shells out to `duckdb` CLI since there's no
 * lightweight TS parquet reader that handles zstd. DuckDB is fast and handles
 * it transparently.
 */

import { execSync } from "child_process";
import { readdirSync, existsSync } from "fs";
import path from "path";
import type { OracleDataSource, OracleSnapshot, ExpiryData } from "./oracle-data-source.js";

interface ParquetRow {
  isodate: string;
  params: string;
}

interface ParquetParam {
  expiry_str: string;
  forward: number;
  rd: number;
  spot: number;
  svi_a: number;
  svi_b: number;
  svi_m: number;
  svi_rho: number;
  svi_sigma: number;
}

function discoverParquetFiles(dataDir: string): string[] {
  const files: string[] = [];

  function walk(dir: string) {
    if (!existsSync(dir)) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.name.endsWith(".parquet")) {
        files.push(full);
      }
    }
  }

  walk(dataDir);
  return files.sort();
}

function loadParquetRows(filePaths: string[]): ParquetRow[] {
  if (filePaths.length === 0) return [];

  const globPattern =
    filePaths.length === 1
      ? `'${filePaths[0]}'`
      : `'${filePaths.join("','")}'`;

  // Use read_parquet with list of files
  const query = `COPY (
    SELECT isodate, params
    FROM read_parquet([${globPattern}])
    ORDER BY isodate
  ) TO '/dev/stdout' (FORMAT JSON, ARRAY true);`;

  try {
    const output = execSync(`duckdb -c "${query}"`, {
      encoding: "utf8",
      maxBuffer: 200 * 1024 * 1024,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return JSON.parse(output) as ParquetRow[];
  } catch (err: any) {
    throw new Error(
      `Failed to read parquet files via duckdb. Is duckdb installed?\n${err.stderr?.slice(0, 500) ?? err.message}`,
    );
  }
}

/**
 * Parquet replay oracle data source.
 *
 * Reads Block Scholes parquet exports (zstd-compressed) via duckdb CLI.
 * Each row contains a snapshot timestamp and a JSON array of per-expiry SVI params.
 */
export class ParquetOracleSource implements OracleDataSource {
  private snapshots: OracleSnapshot[];
  private cursor = 0;
  private allExpiries: string[];

  /**
   * @param dataDir Path to scenario directory (e.g. "data/samples/gap_up")
   *                or a single parquet file path.
   * @param expiryFilter Optional: only include these expiries (ISO strings).
   *                     If omitted, all expiries in the data are included.
   */
  constructor(dataDir: string, expiryFilter?: string[]) {
    const stat = existsSync(dataDir);
    if (!stat) throw new Error(`Parquet data path not found: ${dataDir}`);

    const files = dataDir.endsWith(".parquet")
      ? [dataDir]
      : discoverParquetFiles(dataDir);

    if (files.length === 0) {
      throw new Error(`No parquet files found in ${dataDir}`);
    }

    const rows = loadParquetRows(files);
    const expirySet = expiryFilter ? new Set(expiryFilter) : null;
    const discoveredExpiries = new Set<string>();

    this.snapshots = rows.map((row) => {
      const params: ParquetParam[] = JSON.parse(row.params);
      const timestamp = new Date(row.isodate).getTime();
      const spot = params[0]?.spot ?? 0;

      const expiries: ExpiryData[] = params
        .filter((p) => !expirySet || expirySet.has(p.expiry_str))
        .map((p) => {
          discoveredExpiries.add(p.expiry_str);
          return {
            expiry_iso: p.expiry_str,
            expiry_ms: new Date(p.expiry_str).getTime(),
            forward: p.forward,
            risk_free_rate: p.rd,
            svi: {
              a: p.svi_a,
              b: p.svi_b,
              rho: p.svi_rho,
              m: p.svi_m,
              sigma: p.svi_sigma,
            },
          };
        });

      return { timestamp, spot, expiries };
    });

    this.allExpiries = [...discoveredExpiries].sort();
  }

  async next(): Promise<OracleSnapshot | null> {
    if (this.cursor >= this.snapshots.length) return null;
    return this.snapshots[this.cursor++];
  }

  totalSnapshots(): number | null {
    return this.snapshots.length;
  }

  expiries(): string[] {
    return this.allExpiries;
  }
}
