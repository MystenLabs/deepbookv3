// Market-data sources behind one `MarketSource` interface.
//
// - DirectWsSource owns the provider WS pair (Pyth Lazer spot + Block Scholes per-expiry
//   forward/SVI). Used by a single `harness up` and by the shared hub.
// - HubSource reads a global snapshot written by ONE hub, so N parallel localnets share a
//   single WS pair instead of opening one each.
// - ReplaySource re-plays a recorded hub stream (deterministic market dynamics): it maps
//   recorded expiries onto the current grid by sorted position and stamps fresh timestamps,
//   so the recorded spot path + term structure run against the replay localnet's clock.
import { readFileSync } from "node:fs";

import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import WebSocket from "ws";

import { harnessKey } from "./io.js";

export const isoSec = (ms: number): string => new Date(ms).toISOString().slice(0, 19) + "Z";

export interface Svi {
  alpha: number;
  beta: number;
  rho: number;
  m: number;
  sigma: number;
}
export interface MarketSnapshot {
  spot1e9: bigint;
  publishedAtMs: bigint;
  expiries: Map<number, { forward: number; svi: Svi }>;
}
export interface MarketSource {
  start(expiries: number[]): Promise<void>;
  ensureExpiries(want: number[]): void;
  latest(): MarketSnapshot | null;
  stop(): void;
}

// Parse a snapshot JSON object ({spot1e9, publishedAtMs, expiries:{ms:{forward,svi}}}) into a
// MarketSnapshot. mapByPosition remaps the recorded expiries onto `wanted` by sorted index
// (replay); otherwise it filters to exactly the wanted expiries (hub).
function snapshotFrom(h: any, wanted: number[], mapByPosition: boolean): MarketSnapshot {
  const expiries = new Map<number, { forward: number; svi: Svi }>();
  if (mapByPosition) {
    const recorded = Object.keys(h.expiries ?? {}).map(Number).sort((a, b) => a - b);
    const sortedWanted = [...wanted].sort((a, b) => a - b);
    for (let i = 0; i < sortedWanted.length && i < recorded.length; i++) {
      const e = h.expiries[String(recorded[i])];
      if (e) expiries.set(sortedWanted[i], { forward: e.forward, svi: e.svi });
    }
  } else {
    for (const ms of wanted) {
      const e = h.expiries?.[String(ms)];
      if (e) expiries.set(ms, { forward: e.forward, svi: e.svi });
    }
  }
  return { spot1e9: BigInt(h.spot1e9), publishedAtMs: BigInt(h.publishedAtMs), expiries };
}

const PYTH_TOKEN = harnessKey("PYTH_PRO_API_KEY");
const BS_KEY = harnessKey("BLOCK_SCHOLES_API_KEY");

// Pyth Lazer history endpoint (settlement, independent of the live stream): the EXACT spot
// at a past timestamp. Mirrors deepbook-services' fetchExactLazerPayload (POST /v1/price,
// exact-timestamp assertion, fixed_rate channel so a print lands on the ms boundary), but
// returns the value (1e9) — the harness re-signs it with its own key (the pyth_feed trusts
// the local signer, not Pyth's signature) before inserting it at the expiry key.
const PYTH_HISTORY_URL = "https://pyth-lazer.dourolabs.app/v1/price";
const PYTH_HISTORY_CHANNEL = "fixed_rate@200ms";

export async function fetchExactSpot1e9(expiryMs: number, retries = 3): Promise<bigint> {
  const timestampUs = expiryMs * 1000;
  // Bounded retry/backoff: the exact-ts price is deterministic, so a rate-limit (429), a 5xx,
  // a transient network error, or the endpoint not-yet-having the print is safe to retry. This
  // keeps a transient blip from deferring the flush — which, repeated, grows the active set
  // past the single-PTB flush gas wall.
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * 2 ** (attempt - 1))); // 0.5s, 1s, 2s
    try {
      const res = await fetch(PYTH_HISTORY_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${PYTH_TOKEN}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          timestamp: timestampUs, priceFeedIds: [1], properties: ["price", "exponent"],
          formats: ["leEcdsa"], jsonBinaryEncoding: "base64", parsed: true, channel: PYTH_HISTORY_CHANNEL,
        }),
      });
      if (!res.ok) throw new Error(`pyth history HTTP ${res.status}: ${(await res.text()).slice(0, 120)}`);
      const root: any = await res.json();
      if (String(root?.parsed?.timestampUs ?? "") !== String(timestampUs))
        throw new Error(`pyth history: expected ts ${timestampUs}us, got ${root?.parsed?.timestampUs}us`);
      const feed = (root.parsed.priceFeeds ?? []).find((f: any) => Number(f.priceFeedId) === 1);
      if (feed?.price == null) throw new Error("pyth history: no price for feed 1");
      return BigInt(Math.round(Number(feed.price) * 10 ** (Number(feed.exponent ?? -8) + 9)));
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr;
}

// Direct provider-WS source: Pyth Lazer (spot) + Block Scholes (per-expiry fwd/svi).
export class DirectWsSource implements MarketSource {
  #pyth: PythLazerClient | null = null;
  #bs: WebSocket | null = null;
  #spot1e9: bigint | null = null;
  #spotMs = 0n;
  #fwd = new Map<number, number>();
  #svi = new Map<number, Svi>();
  #expiries: number[] = [];
  #bsOpen = false;

  async start(expiries: number[]): Promise<void> {
    this.#expiries = expiries;
    this.#pyth = await PythLazerClient.create({
      token: PYTH_TOKEN,
      webSocketPoolConfig: { urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"], numConnections: 1 },
    });
    this.#pyth.addMessageListener((ev: any) => {
      if (ev.type !== "binary" || !ev.value.parsed) return;
      const f = ev.value.parsed.priceFeeds?.[0];
      if (f?.price == null) return;
      const exp = Number(f.exponent ?? -8);
      this.#spot1e9 = BigInt(Math.round(Number(f.price) * 10 ** (exp + 9)));
      this.#spotMs = BigInt(Math.floor(Number(ev.value.parsed.timestampUs) / 1000));
    });
    this.#pyth.subscribe({
      type: "subscribe", subscriptionId: 1, priceFeedIds: [1],
      properties: ["price", "exponent"], formats: ["leEcdsa"],
      deliveryFormat: "binary", parsed: true, channel: "real_time",
    });
    await this.#startBs();
  }

  async #startBs(): Promise<void> {
    const ws = new WebSocket("wss://prod-websocket-api.blockscholes.com/");
    this.#bs = ws;
    ws.on("open", () =>
      ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "authenticate", params: { api_key: BS_KEY } })));
    ws.on("message", (raw) => {
      let f: any; try { f = JSON.parse(String(raw)); } catch { return; }
      if (f.result === "ok") {
        this.#bsOpen = true;
        for (const ms of this.#expiries) this.#subscribeBsExpiry(ms);
        return;
      }
      if (f.method !== "subscription") return;
      const list = Array.isArray(f.params) ? f.params : f.params ? [f.params] : [];
      for (const entry of list) for (const v of entry?.data?.values || []) {
        const sid: string = v.sid || "";
        if (sid.startsWith("fwd_") && Number.isFinite(Number(v.v))) this.#fwd.set(Number(sid.slice(4)), Number(v.v));
        else if (sid.startsWith("svi_")) this.#svi.set(Number(sid.slice(4)), { alpha: +v.alpha || 0, beta: +v.beta || 0, rho: +v.rho || 0, m: +v.m || 0, sigma: +v.sigma || 0 });
      }
    });
    ws.on("error", (e) => console.warn("[bs] socket error:", String(e).slice(0, 120)));
  }

  #subscribeBsExpiry(ms: number): void {
    const ws = this.#bs;
    if (!ws) return;
    const fmt = { timestamp: "ms", hexify: false, decimals: 9 };
    const expiry = isoSec(ms);
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: ms, method: "subscribe", params: [{
      frequency: "1000ms", client_id: `fwd_${ms}`,
      batch: [{ sid: `fwd_${ms}`, feed: "mark.px", asset: "future", base_asset: "BTC", expiry }],
      options: { format: fmt },
    }] }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: ms + 1, method: "subscribe", params: [{
      frequency: "1000ms", retransmit_frequency: "1000ms", client_id: `svi_${ms}`,
      batch: [{ sid: `svi_${ms}`, feed: "model.params", exchange: "composite", asset: "option", base_asset: "BTC", model: "SVI", expiry }],
      options: { format: fmt },
    }] }));
  }

  // Roll the warmed grid forward: subscribe newly-wanted expiries. Passed boundaries drop
  // out of `want` (no longer pushed); BS stops serving them after expiry, so they age out.
  ensureExpiries(want: number[]): void {
    const prev = new Set(this.#expiries);
    this.#expiries = [...want];
    if (!this.#bsOpen) return;
    for (const ms of want) if (!prev.has(ms)) this.#subscribeBsExpiry(ms);
  }

  latest(): MarketSnapshot | null {
    if (this.#spot1e9 == null) return null;
    const expiries = new Map<number, { forward: number; svi: Svi }>();
    for (const ms of this.#expiries) {
      const forward = this.#fwd.get(ms);
      const svi = this.#svi.get(ms);
      if (forward != null && svi) expiries.set(ms, { forward, svi });
    }
    return { spot1e9: this.#spot1e9, publishedAtMs: this.#spotMs, expiries };
  }

  stop(): void {
    this.#pyth?.shutdown();
    this.#bs?.close();
  }
}

// Reads the global snapshot written by the hub; filters to the wanted expiries. No WS.
export class HubSource implements MarketSource {
  #wanted: number[] = [];
  constructor(private readonly path: string) {}
  async start(expiries: number[]): Promise<void> {
    this.#wanted = expiries;
  }
  ensureExpiries(want: number[]): void {
    this.#wanted = want;
  }
  latest(): MarketSnapshot | null {
    try {
      return snapshotFrom(JSON.parse(readFileSync(this.path, "utf8")), this.#wanted, false);
    } catch {
      return null;
    }
  }
  stop(): void {}
}

// Re-plays a recorded hub stream (JSONL of snapshots), one record per poll, remapping
// recorded expiries onto the current grid and stamping a fresh publish time so the values
// stay within the on-chain freshness window.
export class ReplaySource implements MarketSource {
  #records: any[] = [];
  #i = 0;
  #wanted: number[] = [];
  constructor(private readonly path: string) {}
  async start(expiries: number[]): Promise<void> {
    this.#wanted = expiries;
    this.#records = readFileSync(this.path, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  }
  ensureExpiries(want: number[]): void {
    this.#wanted = want;
  }
  latest(): MarketSnapshot | null {
    if (this.#records.length === 0) return null;
    const h = this.#records[Math.min(this.#i, this.#records.length - 1)];
    this.#i++;
    return { ...snapshotFrom(h, this.#wanted, true), publishedAtMs: BigInt(Date.now()) };
  }
  stop(): void {}
}
