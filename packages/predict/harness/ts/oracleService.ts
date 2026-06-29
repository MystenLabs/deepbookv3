// Continuous oracle updater (substrate component of `harness up`).
//
// One-time setup (as publisher/admin): register the local Pyth trusted signer and
// create/bind the propbook feeds. Then a freshness-gated hot loop streams real
// Pyth Pro + Block Scholes data onto the feeds at high frequency, stamping each
// update with the provider's REAL publish time (clamped to <= Clock, monotonic).
//
// Data acquisition is behind a `MarketSource` interface. For a single localnet the
// source is a direct provider-WS client (this file). When we turn on parallel runs,
// the same interface is fed by a shared hub (one WS pair for all localnets) and,
// later, by a recorded snapshot stream for deterministic replay.
import { existsSync, readFileSync, writeFileSync } from "node:fs";

import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import WebSocket from "ws";

import { getSigner, getSignerForAddress } from "./env.js";
import { type Feeds } from "./predictSetup.js";
import { buildOracleRefreshGridTx, clampedSourceTimestampMs, client } from "./runtime.js";

const HARNESS_ENV = "/Users/aslantashtanov/Desktop/Projects/deepbookv3/packages/predict/harness/.env";
function harnessKey(name: string): string {
  for (const line of readFileSync(HARNESS_ENV, "utf8").split("\n")) {
    const m = line.match(new RegExp(`^${name}=(.*)$`));
    if (m) return m[1].trim().replace(/^["']|["']$/g, "");
  }
  throw new Error(`missing ${name} in harness .env`);
}
const PYTH_TOKEN = harnessKey("PYTH_PRO_API_KEY");
const BS_KEY = harnessKey("BLOCK_SCHOLES_API_KEY");

const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = run until SIGTERM
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const GAS_BUDGET = 1_000_000_000;
const SCALE_1E9 = 1_000_000_000;

const to1e9 = (x: number) => BigInt(Math.round(x * SCALE_1E9));
const isoSec = (ms: number) => new Date(ms).toISOString().slice(0, 19) + "Z";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const INSTANCE_DIR = process.env.INSTANCE_DIR ?? ".";

// The keeper (single setup owner) publishes the feed ids; wait for them, then stream.
async function waitForFeeds(): Promise<Feeds> {
  const path = `${INSTANCE_DIR}/feeds.json`;
  for (let i = 0; i < 120; i++) {
    if (existsSync(path)) return JSON.parse(readFileSync(path, "utf8"));
    await sleep(1000);
  }
  throw new Error("feeds.json not published by the keeper within 120s");
}

interface Svi { alpha: number; beta: number; rho: number; m: number; sigma: number }
interface MarketSnapshot {
  spot1e9: bigint;
  publishedAtMs: bigint;
  expiries: Map<number, { forward: number; svi: Svi }>;
}
interface MarketSource {
  start(expiries: number[]): Promise<void>;
  latest(): MarketSnapshot | null;
  stop(): void;
}

// Direct provider-WS source: Pyth Lazer (spot) + Block Scholes (per-expiry fwd/svi).
class DirectWsSource implements MarketSource {
  #pyth: PythLazerClient | null = null;
  #bs: WebSocket | null = null;
  #spot1e9: bigint | null = null;
  #spotMs = 0n;
  #fwd = new Map<number, number>();
  #svi = new Map<number, Svi>();
  #expiries: number[] = [];

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
      deliveryFormat: "binary", parsed: true, channel: "fixed_rate@200ms",
    });
    await this.#startBs();
  }

  async #startBs(): Promise<void> {
    const ws = new WebSocket("wss://prod-websocket-api.blockscholes.com/");
    this.#bs = ws;
    const fmt = { timestamp: "ms", hexify: false, decimals: 9 };
    ws.on("open", () =>
      ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "authenticate", params: { api_key: BS_KEY } })));
    ws.on("message", (raw) => {
      let f: any; try { f = JSON.parse(String(raw)); } catch { return; }
      if (f.result === "ok") {
        for (const ms of this.#expiries) {
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

async function submit(tx: any, signer: any): Promise<string> {
  tx.setSender(signer.getPublicKey().toSuiAddress());
  tx.setGasBudget(GAS_BUDGET);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer, options: { showEffects: true } });
  const status = (r as any).effects?.status?.status;
  if (status !== "success") throw new Error(`status=${JSON.stringify((r as any).effects?.status)}`);
  return r.digest;
}

async function main() {
  const feeds = await waitForFeeds();
  console.log(`[updater] feeds from keeper: pyth=${feeds.pythFeedId.slice(0, 10)} svi=${feeds.bsSviFeedId.slice(0, 10)}`);

  // Warm a grid of boundary expiries. GRID_SPEC = "periodMs:count,..." (the launcher
  // sets it from the keeper's cadence so the keeper's markets are always warm).
  const GRID = (process.env.GRID_SPEC ?? "60000:6").split(",").flatMap((part) => {
    const [period, count] = part.split(":").map(Number);
    const base = Math.floor(Date.now() / period) * period;
    return Array.from({ length: count }, (_, i) => base + (i + 1) * period);
  });
  const source = new DirectWsSource();
  await source.start(GRID);
  console.log(`[updater] streaming onto ${GRID.length} expiries: ${GRID.map(isoSec).join(", ")} (warming up)...`);

  const updaterAddress = process.env.UPDATER_ADDRESS;
  const signer = updaterAddress ? getSignerForAddress(updaterAddress) : getSigner();
  console.log(`[updater] submitting as ${signer.getPublicKey().toSuiAddress().slice(0, 12)} (${updaterAddress ? "dedicated" : "publisher"})`);

  let shutdown = false;
  process.on("SIGTERM", () => { shutdown = true; });
  process.on("SIGINT", () => { shutdown = true; });

  const start = Date.now();
  let pushes = 0;
  let skips = 0;
  while (!shutdown && (DURATION_MS === 0 || Date.now() - start < DURATION_MS)) {
    await sleep(LOOP_MS);
    const snap = source.latest();
    if (!snap || snap.expiries.size === 0) { skips++; continue; }
    const ts = await clampedSourceTimestampMs(snap.publishedAtMs);
    if (ts === null) { skips++; continue; }
    const grid = [...snap.expiries.entries()].map(([expiry, e]) => ({
      expiry: BigInt(expiry),
      forward: to1e9(e.forward),
      svi: {
        a: to1e9(e.svi.alpha), b: to1e9(e.svi.beta), sigma: to1e9(e.svi.sigma),
        rho: to1e9(Math.abs(e.svi.rho)), rhoNegative: e.svi.rho < 0,
        m: to1e9(Math.abs(e.svi.m)), mNegative: e.svi.m < 0,
      },
    }));
    // Publish the latest snapshot for the keeper (settlement price) + the trade generator.
    writeFileSync(`${INSTANCE_DIR}/snapshot.json`, JSON.stringify({
      spot1e9: snap.spot1e9.toString(),
      publishedAtMs: ts.toString(),
      expiries: Object.fromEntries([...snap.expiries.entries()]),
    }));
    try {
      const digest = await submit(
        buildOracleRefreshGridTx(
          {
            pythFeedId: feeds.pythFeedId, bsSpotFeedId: feeds.bsSpotFeedId,
            bsForwardFeedId: feeds.bsForwardFeedId, bsSviFeedId: feeds.bsSviFeedId,
          },
          snap.spot1e9, grid, ts,
        ),
        signer,
      );
      pushes++;
      if (pushes <= 3 || pushes % 5 === 0)
        console.log(`[updater] push #${pushes} spot=$${(Number(snap.spot1e9) / SCALE_1E9).toFixed(2)} expiries=${grid.length} ts=${ts} digest=${digest.slice(0, 8)}`);
    } catch (e) {
      skips++;
      console.warn(`[updater] push skipped: ${String(e).slice(0, 120)}`);
    }
  }
  source.stop();
  console.log(`\n[updater] done: ${pushes} pushes, ${skips} skips over ${((Date.now() - start) / 1000).toFixed(0)}s`);
  if (pushes === 0) throw new Error("no successful pushes");
  console.log("=== UPDATER OK: continuous real-data oracle stream landed on-chain ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[updater] FAIL:", e); process.exit(1); });
