/**
 * Live oracle data source from Block Scholes API.
 *
 * Wraps the existing blockscholes.ts fetch functions into the OracleDataSource
 * interface. Yields one snapshot per call to next(), with a configurable tick
 * interval. SVI params are included every sviInterval ticks.
 */

import {
  fetchSpotPrice,
  fetchForwardPrice,
  fetchSVIParams,
  discoverExpiries as discoverBSExpiries,
} from "./blockscholes.js";
import { RISK_FREE_RATE, FLOAT_SCALING } from "./config.js";
import type { OracleDataSource, OracleSnapshot, ExpiryData } from "./oracle-data-source.js";

const DEFAULT_TICK_MS = 2_000;
const DEFAULT_SVI_INTERVAL_MS = 20_000;

export class LiveOracleSource implements OracleDataSource {
  private liveExpiries: string[];
  private tickIntervalMs: number;
  private sviIntervalMs: number;
  private lastSviMs = 0;
  private started = false;

  /**
   * @param liveExpiries Expiry ISO strings to track. If empty, auto-discovers from Block Scholes.
   * @param tickIntervalMs How often next() should yield a new snapshot (default 2s).
   * @param sviIntervalMs How often to include SVI params (default 20s).
   */
  constructor(
    liveExpiries: string[] = [],
    tickIntervalMs = DEFAULT_TICK_MS,
    sviIntervalMs = DEFAULT_SVI_INTERVAL_MS,
  ) {
    this.liveExpiries = liveExpiries;
    this.tickIntervalMs = tickIntervalMs;
    this.sviIntervalMs = sviIntervalMs;
  }

  async next(): Promise<OracleSnapshot | null> {
    // Auto-discover expiries on first call
    if (!this.started) {
      if (this.liveExpiries.length === 0) {
        this.liveExpiries = await discoverBSExpiries();
      }
      this.started = true;
    }

    // Rate limit
    await sleep(this.tickIntervalMs);

    const now = Date.now();
    const includeSvi = now - this.lastSviMs >= this.sviIntervalMs;
    const spot = await fetchSpotPrice();

    const rfr = Number(RISK_FREE_RATE) / Number(FLOAT_SCALING);

    const expiries: ExpiryData[] = [];

    for (const expiryIso of this.liveExpiries) {
      let forward: number;
      try {
        forward = await fetchForwardPrice(expiryIso);
      } catch {
        // Fallback: synthetic forward = spot * e^(r*T)
        const ttm =
          (new Date(expiryIso).getTime() - now) / (365.25 * 24 * 60 * 60 * 1000);
        if (ttm <= 0) continue;
        forward = spot * Math.exp(rfr * ttm);
      }

      let svi: ExpiryData["svi"] = null;
      if (includeSvi) {
        try {
          const raw = await fetchSVIParams(expiryIso);
          svi = {
            a: raw.a,
            b: raw.b,
            rho: raw.rho,
            m: raw.m,
            sigma: raw.sigma,
          };
        } catch {
          // SVI not available for this expiry
        }
      }

      expiries.push({
        expiry_iso: expiryIso,
        expiry_ms: new Date(expiryIso).getTime(),
        forward,
        risk_free_rate: rfr,
        svi,
      });
    }

    if (includeSvi) {
      this.lastSviMs = now;
    }

    return {
      timestamp: now,
      spot,
      expiries,
    };
  }

  totalSnapshots(): number | null {
    return null; // infinite stream
  }

  expiries(): string[] {
    return this.liveExpiries;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
