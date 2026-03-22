import { BLOCKSCHOLES_API_KEY, FLOAT_SCALING } from "./config.js";
import type { ScaledSVIParams } from "./types.js";

const BASE_URL = "https://prod-data.blockscholes.com";
const HEADERS = {
  "Content-Type": "application/json",
  "X-API-Key": BLOCKSCHOLES_API_KEY,
};

// Match the working demo: frequency=1m, decimals=5, timestamp=s
const LATEST_BODY_OPTS = {
  start: "LATEST",
  end: "LATEST",
  frequency: "1m",
  options: { format: { timestamp: "s", hexify: false, decimals: 5 } },
};

async function postJSON<T>(endpoint: string, body: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${BASE_URL}${endpoint}`, {
    method: "POST",
    headers: HEADERS,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "(no body)");
    throw new Error(`Block Scholes ${endpoint} returned ${res.status}: ${text}`);
  }
  return (await res.json()) as T;
}

interface BSDataEntry extends Record<string, unknown> {
  timestamp: number;
}

interface BSResponse {
  data: BSDataEntry[] | Record<string, never>;
  error?: { message: string };
}

function extractFirstEntry(resp: BSResponse): BSDataEntry {
  if (!Array.isArray(resp.data) || resp.data.length === 0) {
    throw new Error(resp.error?.message ?? "Block Scholes response has no data entries");
  }
  return resp.data[0];
}

/** Fetch current BTC spot index price (returns USD float) */
export async function fetchSpotPrice(): Promise<number> {
  const resp = await postJSON<BSResponse>("/api/v1/price/index", {
    base_asset: "BTC",
    asset_type: "spot",
    ...LATEST_BODY_OPTS,
  });
  const entry = extractFirstEntry(resp);
  const v = entry.v;
  if (typeof v !== "number") throw new Error("Spot price response missing 'v' field");
  return v;
}

/** Fetch forward (futures mark) price for a specific expiry (returns USD float) */
export async function fetchForwardPrice(expiryIso: string): Promise<number> {
  const resp = await postJSON<BSResponse>("/api/v1/price/mark", {
    base_asset: "BTC",
    asset_type: "future",
    expiry: expiryIso,
    ...LATEST_BODY_OPTS,
  });
  const entry = extractFirstEntry(resp);
  const v = entry.v;
  if (typeof v !== "number") throw new Error("Forward price response missing 'v' field");
  return v;
}

/** Fetch SVI params for a specific expiry (returns raw floats) */
export async function fetchSVIParams(
  expiryIso: string,
): Promise<{ a: number; b: number; rho: number; m: number; sigma: number }> {
  const resp = await postJSON<BSResponse>("/api/v1/modelparams", {
    exchange: "composite",
    base_asset: "BTC",
    expiry: expiryIso,
    model: "SVI",
    ...LATEST_BODY_OPTS,
  });
  const entry = extractFirstEntry(resp);
  // API returns alpha, beta, rho, m, sigma
  const a = entry.alpha;
  const b = entry.beta;
  const rho = entry.rho;
  const m = entry.m;
  const sigma = entry.sigma;
  if (typeof a !== "number" || typeof b !== "number" || typeof rho !== "number" ||
      typeof m !== "number" || typeof sigma !== "number") {
    throw new Error(`Block Scholes SVI response missing fields: ${JSON.stringify(entry)}`);
  }
  return { a, b, rho, m, sigma };
}

/** Scale a float to u64 using FLOAT_SCALING (1e9) */
export function scaleToU64(value: number): bigint {
  return BigInt(Math.round(value * Number(FLOAT_SCALING)));
}

/** Scale SVI params to on-chain format (magnitude + is_negative for rho, m) */
export function scaleSVIParams(raw: {
  a: number;
  b: number;
  rho: number;
  m: number;
  sigma: number;
}): ScaledSVIParams {
  return {
    a: scaleToU64(raw.a),
    b: scaleToU64(raw.b),
    rho: scaleToU64(Math.abs(raw.rho)),
    rho_negative: raw.rho < 0,
    m: scaleToU64(Math.abs(raw.m)),
    m_negative: raw.m < 0,
    sigma: scaleToU64(raw.sigma),
  };
}

/**
 * Discover live expiries using the Block Scholes catalog endpoint.
 * Returns expiry ISO strings for all active BTC options on deribit.
 * Filters to future expiries only.
 */
export async function discoverExpiries(): Promise<string[]> {
  const now = new Date();
  const start = now.toISOString().replace(/\.\d{3}Z$/, "Z");
  const end = new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

  const resp = await postJSON<BSResponse>("/api/v1/catalog", {
    exchanges: ["deribit"],
    base_assets: ["BTC"],
    asset_types: ["option"],
    start,
    end,
  });

  if (!Array.isArray(resp.data)) {
    throw new Error(resp.error?.message ?? "Catalog returned no data");
  }

  const expiries = new Set<string>();
  for (const entry of resp.data) {
    const expiry = entry.expiry;
    if (typeof expiry === "string" && new Date(expiry).getTime() > Date.now()) {
      expiries.add(expiry);
    }
  }

  return [...expiries].sort();
}
