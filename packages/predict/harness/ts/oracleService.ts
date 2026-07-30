// Continuous oracle updater (substrate component of `harness live`).
//
// Streams real Pyth Pro + Block Scholes data onto the propbook feeds at high frequency,
// stamping each update with the provider's REAL publish time (clamped to <= Clock,
// monotonic). The feed ids come from the keeper (feeds.json); the data comes from a
// `MarketSource` chosen by env: a shared hub snapshot (parallel runs), a recorded replay,
// or this localnet's own provider WS pair. Each push also writes snapshot.json for the
// trade generator (the keeper settles independently via the Pyth Lazer history endpoint).
import { existsSync, readFileSync } from "node:fs";

import { getSigner, getSignerForAddress } from "../../devtools/ts/env.js";
import { atomicWriteFile } from "./io.js";
import {
  type MarketSource,
  DirectWsSource,
  HubSource,
  ReplaySource,
  serializableSnapshot,
} from "./marketSource.js";
import { type Feeds } from "./predictSetup.js";
import {
  buildOracleRefreshGridTx,
  clampedPythTimestampMs,
  clampedSourceTimestampMs,
  executeWithSignerAndWait,
} from "./runtime.js";

const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = run until SIGTERM
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const GAS_BUDGET = 1_000_000_000;
const SCALE_1E9 = 1_000_000_000;
const DEFAULT_GRID_SPEC = "60000:3,300000:3,3600000:3";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const INSTANCE_DIR = process.env.INSTANCE_DIR ?? ".";

// The keeper (single setup owner) publishes the feed ids; wait for them, then stream.
async function waitForFeeds(): Promise<Feeds> {
  const path = `${INSTANCE_DIR}/feeds.json`;
  for (let i = 0; i < 120; i++) {
    if (existsSync(path)) {
      try { return JSON.parse(readFileSync(path, "utf8")); } catch { /* torn read mid-write; retry */ }
    }
    await sleep(1000);
  }
  throw new Error("feeds.json not published by the keeper within 120s");
}

async function submit(tx: any, signer: any): Promise<string> {
  const r = await executeWithSignerAndWait(
    tx,
    signer,
    "oracle-refresh",
    GAS_BUDGET,
    { effects: true },
  );
  return r.digest;
}

// A shared hub snapshot (parallel runs), a recorded replay, or our own provider WS pair.
function makeSource(): { source: MarketSource; mode: string } {
  if (process.env.HUB_SNAPSHOT) return { source: new HubSource(process.env.HUB_SNAPSHOT), mode: "hub" };
  if (process.env.REPLAY_FILE) return { source: new ReplaySource(process.env.REPLAY_FILE), mode: "replay" };
  return { source: new DirectWsSource(), mode: "direct-ws" };
}

async function main() {
  const feeds = await waitForFeeds();
  console.log(`[updater] feeds from keeper: pyth=${feeds.pythFeedId.slice(0, 10)} svi=${feeds.bsSviStoreId.slice(0, 10)}`);

  // Warm a ROLLING grid of boundary expiries. GRID_SPEC = "periodMs:count,..." (the launcher sets
  // it from the keeper's cadence set). gridNow() = the next `count` boundaries of each period from
  // now, re-evaluated each loop so the grid rolls forward as boundaries pass and the keeper's new
  // markets stay warm. Deduped: with multiple cadences periods share boundaries (e.g. the top of the
  // hour is in all three) — a duplicate expiry would mean duplicate sids in the BS batch.
  const gridNow = () => [
    ...new Set(
      (process.env.GRID_SPEC ?? DEFAULT_GRID_SPEC).split(",").flatMap((part) => {
        const [period, count] = part.split(":").map(Number);
        const base = Math.floor(Date.now() / period) * period;
        return Array.from({ length: count }, (_, i) => base + (i + 1) * period);
      }),
    ),
  ];
  const { source, mode } = makeSource();
  await source.start(gridNow());
  console.log(`[updater] source=${mode}; streaming a rolling grid (GRID_SPEC=${process.env.GRID_SPEC ?? DEFAULT_GRID_SPEC})...`);

  const updaterAddress = process.env.UPDATER_ADDRESS;
  const signer = updaterAddress ? getSignerForAddress(updaterAddress) : getSigner();
  console.log(`[updater] submitting as ${signer.getPublicKey().toSuiAddress().slice(0, 12)} (${updaterAddress ? "dedicated" : "publisher"})`);

  let shutdown = false;
  process.on("SIGTERM", () => { shutdown = true; });
  process.on("SIGINT", () => { shutdown = true; });

  const start = Date.now();
  let pushes = 0;
  let skips = 0;
  // Dual-clock accounting: per series, how often the provider re-sent an unchanged model time
  // (a pinned retransmission) vs advanced it. This is the empirical probe for the on-chain
  // model-time freshness contract — a provider that pins a series past the freshness window
  // would halt pricing, and this summary is where that behavior becomes visible.
  const lastFwdTs = new Map<number, number>();
  const lastSviTs = new Map<number, number>();
  let lastBsSpotTs = 0;
  let pinnedSpot = 0;
  let pinnedFwd = 0;
  let pinnedSvi = 0;
  let missingTs = 0;
  while (!shutdown && (DURATION_MS === 0 || Date.now() - start < DURATION_MS)) {
    await sleep(LOOP_MS);
    source.ensureExpiries(gridNow()); // roll the warmed grid forward as boundaries pass
    const snap = source.latest();
    if (!snap || snap.expiries.size === 0) { skips++; continue; }
    // The envelope is when WE (the relayer) package the batch: base it on the freshest
    // input clock so no series' model time postdates it merely from cross-stream skew.
    let latestInputMs = Number(snap.publishedAtMs);
    if (snap.bsSpotTsMs > latestInputMs) latestInputMs = snap.bsSpotTsMs;
    for (const e of snap.expiries.values()) {
      if (e.forwardTsMs > latestInputMs) latestInputMs = e.forwardTsMs;
      if (e.sviTsMs > latestInputMs) latestInputMs = e.sviTsMs;
    }
    const ts = await clampedSourceTimestampMs(BigInt(latestInputMs));
    if (ts === null) { skips++; continue; }
    // Pyth rides its OWN stream clock, not the envelope above: stamping the cached Pyth
    // value with the cross-stream max would keep a stalled Pyth stream artificially fresh
    // on-chain. A stalled stream returns null here — the push proceeds without the Pyth
    // leg and the feed ages out honestly, keeping the BS-forward fallback exercisable.
    const pythTs = await clampedPythTimestampMs(snap.publishedAtMs);
    if (snap.bsSpotTsMs !== 0 && snap.bsSpotTsMs === lastBsSpotTs) pinnedSpot++;
    if (snap.bsSpotTsMs === 0) missingTs++;
    lastBsSpotTs = snap.bsSpotTsMs;
    const grid = [...snap.expiries.entries()].map(([expiry, e]) => {
      if (e.forwardTsMs === 0 || e.sviTsMs === 0) missingTs++;
      if (lastFwdTs.get(expiry) === e.forwardTsMs && e.forwardTsMs !== 0) pinnedFwd++;
      if (lastSviTs.get(expiry) === e.sviTsMs && e.sviTsMs !== 0) pinnedSvi++;
      lastFwdTs.set(expiry, e.forwardTsMs);
      lastSviTs.set(expiry, e.sviTsMs);
      return {
        expiry: BigInt(expiry),
        forward: e.forward1e9,
        forwardTsMs: BigInt(e.forwardTsMs),
        svi: {
          a: e.svi1e9.a,
          aNegative: e.svi1e9.aNegative,
          b: e.svi1e9.b,
          sigma: e.svi1e9.sigma,
          rho: e.svi1e9.rho,
          rhoNegative: e.svi1e9.rhoNegative,
          m: e.svi1e9.m,
          mNegative: e.svi1e9.mNegative,
        },
        sviTsMs: BigInt(e.sviTsMs),
      };
    });
    try {
      const digest = await submit(
        buildOracleRefreshGridTx(
          {
            pythFeedId: feeds.pythFeedId,
            bsValueStoreId: feeds.bsValueStoreId,
            bsSviStoreId: feeds.bsSviStoreId,
          },
          snap.spot1e9,
          pythTs,
          { value1e9: snap.bsSpot1e9, tsMs: BigInt(snap.bsSpotTsMs) },
          grid, ts,
        ),
        signer,
      );
      // Publish the snapshot for the trade generator ONLY after the on-chain refresh landed —
      // otherwise traders price/guard off oracle data that never made it on-chain, producing
      // spurious guard aborts that look like harness failures.
      atomicWriteFile(
        `${INSTANCE_DIR}/snapshot.json`,
        JSON.stringify(serializableSnapshot({ ...snap, publishedAtMs: ts })),
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
  console.log(
    `[updater] dual-clock: ${pinnedSpot} pinned spot + ${pinnedFwd} pinned fwd + ${pinnedSvi} pinned svi retransmissions observed` +
    (missingTs > 0 ? ` (${missingTs} entries lacked a provider timestamp — signed at the envelope)` : ""),
  );
  if (pushes === 0 && mode !== "replay") throw new Error("no successful pushes");
  console.log("=== UPDATER OK: real-data oracle stream landed on-chain ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[updater] FAIL:", e); process.exit(1); });
