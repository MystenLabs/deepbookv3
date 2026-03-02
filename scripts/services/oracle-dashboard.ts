// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal dashboard for monitoring oracle feed data via the predict-server API.
/// Refreshes every 2s.
///
/// Usage: pnpm oracle-dashboard

const API_BASE =
  process.env.PREDICT_API_URL ??
  "https://predict-server.testnet.mystenlabs.com";
const FLOAT_SCALING = 1e9;
const REFRESH_MS = 2_000;

interface OracleInfo {
  oracle_id: string;
  oracle_cap_id: string;
  expiry: number;
  status: string;
  activated_at: number | null;
  settlement_price: number | null;
  settled_at: number | null;
  created_checkpoint: number;
}

interface PriceInfo {
  oracle_id: string;
  spot: number;
  forward: number;
  onchain_timestamp: number;
  package: string;
  checkpoint: number;
}

async function apiFetch<T>(path: string): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`);
  if (!res.ok) throw new Error(`API ${path}: ${res.status}`);
  return res.json() as Promise<T>;
}

function formatPrice(raw: number): string {
  return (raw / FLOAT_SCALING).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function formatExpiry(expiryMs: number): string {
  const d = new Date(expiryMs);
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
    hour12: false,
  });
}

function formatAge(onchainMs: number): string {
  const diffMs = Date.now() - onchainMs;
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

// Shared layout width — wide enough for 0x... addresses in deployment table
const PRICE_COLS = [16, 14, 14, 8, 10];
const W = 90;
const dline = "═".repeat(W);

const textRow = (content: string) => `║${content.padEnd(W)}║`;

const tableRow = (_cols: number[], ...cells: string[]) => {
  const inner = "  " + cells.join(" │ ");
  return `║${inner.padEnd(W)}║`;
};

const tableSep = (cols: number[]) => {
  const inner = "──" + cols.map((c) => "─".repeat(c)).join("─┼─");
  return `║${inner}║`;
};

async function render() {
  const oracles = await apiFetch<OracleInfo[]>("/oracles");
  oracles.sort((a, b) => a.expiry - b.expiry);

  // Fetch latest price for each active oracle in parallel
  const priceResults = await Promise.allSettled(
    oracles
      .filter((o) => o.status === "active")
      .map((o) =>
        apiFetch<PriceInfo>(`/oracles/${o.oracle_id}/prices/latest`),
      ),
  );

  const priceMap = new Map<string, PriceInfo>();
  for (const result of priceResults) {
    if (result.status === "fulfilled" && result.value) {
      priceMap.set(result.value.oracle_id, result.value);
    }
  }

  const now = new Date().toLocaleTimeString("en-US", { hour12: false });
  const title = `  Oracle Feed Dashboard`;
  const refresh = `Last refresh: ${now}  `;

  const lines: string[] = [];

  // === Deployment Info Box ===
  lines.push(`╔${dline}╗`);
  lines.push(`║${title}${" ".repeat(W - title.length - refresh.length)}${refresh}║`);
  lines.push(`╠${dline}╣`);

  if (oracles.length > 0) {
    const firstPrice = priceMap.values().next().value as PriceInfo | undefined;
    const pkg = firstPrice?.package ?? "N/A";
    const capId = oracles[0].oracle_cap_id;

    lines.push(textRow(`  Package:    ${pkg}`));
    lines.push(textRow(`  Oracle Cap: ${capId}`));
    lines.push(textRow(`  Source:     ${API_BASE}`));
    lines.push(textRow(``));

    const dCols = [16, 68];
    lines.push(
      tableRow(dCols, pad("Expiry", dCols[0]), pad("Oracle ID", dCols[1])),
    );
    lines.push(tableSep(dCols));

    for (const o of oracles) {
      lines.push(
        tableRow(
          dCols,
          pad(formatExpiry(o.expiry), dCols[0]),
          pad(o.oracle_id, dCols[1]),
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
      pad("Status", PRICE_COLS[4]),
    ),
  );
  lines.push(tableSep(PRICE_COLS));

  for (const oracle of oracles) {
    const price = priceMap.get(oracle.oracle_id);
    if (!price) {
      lines.push(
        tableRow(
          PRICE_COLS,
          pad(formatExpiry(oracle.expiry), PRICE_COLS[0]),
          rpad("—", PRICE_COLS[1]),
          rpad("—", PRICE_COLS[2]),
          rpad("—", PRICE_COLS[3]),
          pad(oracle.status, PRICE_COLS[4]),
        ),
      );
      continue;
    }

    const ageMs = Date.now() - price.onchain_timestamp;
    const stale = ageMs > 30_000;

    lines.push(
      tableRow(
        PRICE_COLS,
        pad(formatExpiry(oracle.expiry), PRICE_COLS[0]),
        rpad(formatPrice(price.spot), PRICE_COLS[1]),
        rpad(formatPrice(price.forward), PRICE_COLS[2]),
        rpad(formatAge(price.onchain_timestamp), PRICE_COLS[3]),
        pad(stale ? "○ stale" : "● active", PRICE_COLS[4]),
      ),
    );
  }

  // === Stats Footer ===
  lines.push(`╠${dline}╣`);
  const activeCount = oracles.filter((o) => o.status === "active").length;
  const stats = `  Active oracles: ${activeCount}  │  Total: ${oracles.length}`;
  lines.push(`║${stats.padEnd(W)}║`);
  lines.push(`╚${dline}╝`);

  console.clear();
  console.log(lines.join("\n"));
}

async function main() {
  // Verify API connectivity
  const res = await fetch(`${API_BASE}/health`);
  if (!res.ok) throw new Error(`API /health: ${res.status}`);
  console.log(`Connected to ${API_BASE}. Starting dashboard...\n`);

  await render();

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
