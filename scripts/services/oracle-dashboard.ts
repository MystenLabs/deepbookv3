// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal dashboard for monitoring oracle feed data from the indexer.
/// Reads from Postgres and refreshes every 2s.
///
/// Usage: pnpm oracle-dashboard

import pg from "pg";

const FLOAT_SCALING = 1e9;
const REFRESH_MS = 2_000;
const DB_CONFIG = {
  host: "localhost",
  port: 5433,
  database: "predict",
  user: process.env.PGUSER ?? process.env.USER,
};

const pool = new pg.Pool(DB_CONFIG);

interface OracleRow {
  oracle_id: string;
  expiry: string;
  spot: string;
  forward: string;
  onchain_timestamp: string;
  update_count: string;
}

interface DeploymentRow {
  oracle_id: string;
  oracle_cap_id: string;
  expiry: string;
  package: string;
  checkpoint_timestamp_ms: string;
}

function decode(raw: string): number {
  return Number(BigInt(raw)) / FLOAT_SCALING;
}

function formatPrice(raw: string): string {
  return decode(raw).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function formatExpiry(expiryMs: string): string {
  const d = new Date(Number(expiryMs));
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
    hour12: false,
  });
}

function formatAge(onchainMs: string): string {
  const diffMs = Date.now() - Number(onchainMs);
  if (diffMs < 0) return "0s";
  const secs = Math.floor(diffMs / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ${secs % 60}s`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

function pad(str: string, len: number): string {
  return str.padEnd(len);
}

function rpad(str: string, len: number): string {
  return str.padStart(len);
}

function shortAddr(addr: string): string {
  return addr.slice(0, 10) + "..." + addr.slice(-6);
}

function formatTimestamp(ms: string): string {
  return new Date(Number(ms)).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

// Shared layout width — derived from the price table columns
const PRICE_COLS = [16, 14, 14, 8, 10, 10];
const W = 2 + PRICE_COLS.reduce((s, c) => s + c, 0) + (PRICE_COLS.length - 1) * 3;
const dline = "═".repeat(W);

const textRow = (content: string) => `║${content.padEnd(W)}║`;

const tableRow = (cols: number[], ...cells: string[]) => {
  const inner = "  " + cells.join(" │ ");
  return `║${inner.padEnd(W)}║`;
};

const tableSep = (cols: number[]) => {
  const inner = "──" + cols.map((c) => "─".repeat(c)).join("─┼─");
  return `║${inner}║`;
};

async function render() {
  // Deployment info (static, but re-queried for simplicity)
  const { rows: deployRows } = await pool.query<DeploymentRow>(
    "SELECT oracle_id, oracle_cap_id, expiry, package, checkpoint_timestamp_ms FROM oracle_created ORDER BY expiry",
  );

  // Latest price per oracle
  const { rows } = await pool.query<OracleRow>(`
    SELECT DISTINCT ON (a.oracle_id)
      a.oracle_id,
      a.expiry,
      p.spot,
      p.forward,
      p.onchain_timestamp,
      counts.update_count
    FROM oracle_activated a
    JOIN oracle_prices_updated p ON p.oracle_id = a.oracle_id
    LEFT JOIN (
      SELECT oracle_id, COUNT(*)::text AS update_count
      FROM oracle_prices_updated
      GROUP BY oracle_id
    ) counts ON counts.oracle_id = a.oracle_id
    ORDER BY a.oracle_id, p.onchain_timestamp DESC
  `);
  rows.sort((a, b) => Number(a.expiry) - Number(b.expiry));

  const totalUpdates = rows.reduce((s, r) => s + Number(r.update_count), 0);
  const sviCount = await pool.query(
    "SELECT COUNT(*) as cnt FROM oracle_svi_updated",
  );

  const now = new Date().toLocaleTimeString("en-US", { hour12: false });
  const title = `  Oracle Feed Dashboard`;
  const refresh = `Last refresh: ${now}  `;

  const lines: string[] = [];

  // === Deployment Info Box ===
  lines.push(`╔${dline}╗`);
  lines.push(`║${title}${" ".repeat(W - title.length - refresh.length)}${refresh}║`);
  lines.push(`╠${dline}╣`);

  if (deployRows.length > 0) {
    const pkg = deployRows[0].package;
    const capId = deployRows[0].oracle_cap_id;
    const deployedAt = formatTimestamp(deployRows[0].checkpoint_timestamp_ms);

    lines.push(textRow(`  Package:    ${pkg}`));
    lines.push(textRow(`  Oracle Cap: ${capId}`));
    lines.push(textRow(`  Deployed:   ${deployedAt}`));
    lines.push(textRow(`  Network:    testnet`));
    lines.push(textRow(``));

    const dCols = [16, 68];
    lines.push(
      tableRow(dCols, pad("Expiry", dCols[0]), pad("Oracle ID", dCols[1])),
    );
    lines.push(tableSep(dCols));

    for (const d of deployRows) {
      lines.push(
        tableRow(
          dCols,
          pad(formatExpiry(d.expiry), dCols[0]),
          pad(d.oracle_id, dCols[1]),
        ),
      );
    }
  }

  // === Live Prices Box ===
  lines.push(`╠${dline}╣`);
  lines.push(
    tableRow(
      PRICE_COLS,
      pad("Expiry", PRICE_COLS[0]),
      rpad("Spot", PRICE_COLS[1]),
      rpad("Forward", PRICE_COLS[2]),
      rpad("Age", PRICE_COLS[3]),
      rpad("Updates", PRICE_COLS[4]),
      pad("Status", PRICE_COLS[5]),
    ),
  );
  lines.push(tableSep(PRICE_COLS));

  for (const row of rows) {
    const ageMs = Date.now() - Number(row.onchain_timestamp);
    const stale = ageMs > 30_000;

    lines.push(
      tableRow(
        PRICE_COLS,
        pad(formatExpiry(row.expiry), PRICE_COLS[0]),
        rpad(formatPrice(row.spot), PRICE_COLS[1]),
        rpad(formatPrice(row.forward), PRICE_COLS[2]),
        rpad(formatAge(row.onchain_timestamp), PRICE_COLS[3]),
        rpad(row.update_count, PRICE_COLS[4]),
        pad(stale ? "○ stale" : "● active", PRICE_COLS[5]),
      ),
    );
  }

  // === Stats Footer ===
  lines.push(`╠${dline}╣`);
  const stats = `  Price updates: ${totalUpdates}  │  SVI updates: ${sviCount.rows[0].cnt}  │  Oracles: ${rows.length}`;
  lines.push(`║${stats.padEnd(W)}║`);
  lines.push(`╚${dline}╝`);

  console.clear();
  console.log(lines.join("\n"));
}

async function main() {
  // Verify connection
  await pool.query("SELECT 1");
  console.log("Connected to predict database. Starting dashboard...\n");

  // Initial render
  await render();

  // Refresh loop
  setInterval(async () => {
    try {
      await render();
    } catch (err) {
      console.error("Render error:", err);
    }
  }, REFRESH_MS);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
