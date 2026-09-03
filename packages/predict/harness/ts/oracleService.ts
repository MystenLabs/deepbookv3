// Continuous oracle updater (substrate component of `harness live`).
//
// Streams real Pyth Pro + Block Scholes data onto the propbook feeds at high frequency,
// preserving each update's provider source time while clamping the relayer's batch time to
// Clock. The feed ids come from the keeper (feeds.json); the data comes from a
// `MarketSource` chosen by env: a shared hub snapshot (parallel runs) or this localnet's
// own provider WS pair. Each push also writes snapshot.json for the
// trade generator (the keeper settles independently via the Pyth Lazer history endpoint).
import { existsSync, readFileSync } from "node:fs";

import { getSignerForAddress } from "../../devtools/ts/env.js";
import { atomicWriteFile } from "./io.js";
import {
  type MarketSource,
  DirectWsSource,
  HubSource,
  serializableSnapshot,
} from "./marketSource.js";
import { type Feeds } from "./predictSetup.js";
import { gridExpiries, requiredEnv, requiredNonnegativeInt } from "./runnerConfig.js";
import {
  buildOracleRefreshGridTx,
  clampedBatchTimestampMs,
  clampedPythTimestampMs,
  executeWithSignerAndWait,
} from "../../devtools/ts/runtime.js";

const DURATION_MS = requiredNonnegativeInt("DURATION_MS"); // 0 = run until SIGTERM
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const GAS_BUDGET = 1_000_000_000;
const SCALE_1E9 = 1_000_000_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const INSTANCE_DIR = requiredEnv("INSTANCE_DIR");
const GRID_SPEC = requiredEnv("GRID_SPEC");
const UPDATER_ADDRESS = requiredEnv("UPDATER_ADDRESS");

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

// A shared hub snapshot (parallel runs) or our own provider WS pair.
function makeSource(): { source: MarketSource; mode: string } {
  if (process.env.HUB_SNAPSHOT) return { source: new HubSource(process.env.HUB_SNAPSHOT), mode: "hub" };
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
  const gridNow = () => gridExpiries(GRID_SPEC);
  const { source, mode } = makeSource();
  await source.start(gridNow());
  console.log(`[updater] source=${mode}; streaming a rolling grid (GRID_SPEC=${GRID_SPEC})...`);

  const signer = getSignerForAddress(UPDATER_ADDRESS);
  console.log(`[updater] submitting as ${signer.getPublicKey().toSuiAddress().slice(0, 12)} (dedicated)`);

  let shutdown = false;
  process.on("SIGTERM", () => { shutdown = true; });
  process.on("SIGINT", () => { shutdown = true; });

  const start = Date.now();
  let pushes = 0;
  let skips = 0;
  // Source-clock accounting: per series, how often the provider re-sent an unchanged source time
  // (a pinned retransmission) vs advanced it. This is the empirical probe for the on-chain
  // source-time freshness contract — a provider that pins a series past the freshness window
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
    // The batch timestamp is when WE (the relayer) package the batch. Base it on the freshest
    // input clock so no observation source time postdates the signed envelope from stream skew.
    let latestInputMs = Number(snap.pythSourceTimestampMs);
    if (snap.bsSpotSourceTimestampMs > latestInputMs) {
      latestInputMs = snap.bsSpotSourceTimestampMs;
    }
    for (const e of snap.expiries.values()) {
      if (e.forwardSourceTimestampMs > latestInputMs) {
        latestInputMs = e.forwardSourceTimestampMs;
      }
      if (e.sviSourceTimestampMs > latestInputMs) {
        latestInputMs = e.sviSourceTimestampMs;
      }
    }
    const batchTimestampMs = await clampedBatchTimestampMs(BigInt(latestInputMs));
    if (batchTimestampMs === null) { skips++; continue; }
    // Pyth rides its OWN stream clock, not the envelope above: stamping the cached Pyth
    // value with the cross-stream max would keep a stalled Pyth stream artificially fresh
    // on-chain. A stalled stream returns null here — the push proceeds without the Pyth
    // leg and the feed ages out honestly, keeping the BS-forward fallback exercisable.
    const pythTs = await clampedPythTimestampMs(snap.pythSourceTimestampMs);
    if (
      snap.bsSpotSourceTimestampMs !== 0 &&
      snap.bsSpotSourceTimestampMs === lastBsSpotTs
    ) pinnedSpot++;
    if (snap.bsSpotSourceTimestampMs === 0) missingTs++;
    lastBsSpotTs = snap.bsSpotSourceTimestampMs;
    const grid = [...snap.expiries.entries()].map(([expiry, e]) => {
      if (e.forwardSourceTimestampMs === 0 || e.sviSourceTimestampMs === 0) missingTs++;
      if (
        lastFwdTs.get(expiry) === e.forwardSourceTimestampMs &&
        e.forwardSourceTimestampMs !== 0
      ) pinnedFwd++;
      if (
        lastSviTs.get(expiry) === e.sviSourceTimestampMs &&
        e.sviSourceTimestampMs !== 0
      ) pinnedSvi++;
      lastFwdTs.set(expiry, e.forwardSourceTimestampMs);
      lastSviTs.set(expiry, e.sviSourceTimestampMs);
      return {
        expiry: BigInt(expiry),
        forward: e.forward1e9,
        forwardSourceTimestampMs: BigInt(e.forwardSourceTimestampMs),
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
        sviSourceTimestampMs: BigInt(e.sviSourceTimestampMs),
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
          {
            value1e9: snap.bsSpot1e9,
            sourceTimestampMs: BigInt(snap.bsSpotSourceTimestampMs),
          },
          grid, batchTimestampMs,
        ),
        signer,
      );
      // Publish the snapshot for the trade generator ONLY after the on-chain refresh landed —
      // otherwise traders price/guard off oracle data that never made it on-chain, producing
      // spurious guard aborts that look like harness failures.
      atomicWriteFile(
        `${INSTANCE_DIR}/snapshot.json`,
        JSON.stringify(serializableSnapshot(snap)),
      );
      pushes++;
      if (pushes <= 3 || pushes % 5 === 0)
        console.log(`[updater] push #${pushes} spot=$${(Number(snap.spot1e9) / SCALE_1E9).toFixed(2)} expiries=${grid.length} batch_timestamp_ms=${batchTimestampMs} digest=${digest.slice(0, 8)}`);
    } catch (e) {
      skips++;
      console.warn(`[updater] push skipped: ${String(e).slice(0, 120)}`);
    }
  }
  source.stop();
  console.log(`\n[updater] done: ${pushes} pushes, ${skips} skips over ${((Date.now() - start) / 1000).toFixed(0)}s`);
  console.log(
    `[updater] dual-clock: ${pinnedSpot} pinned spot + ${pinnedFwd} pinned fwd + ${pinnedSvi} pinned svi retransmissions observed` +
    (missingTs > 0 ? ` (${missingTs} entries lacked a provider source timestamp and were skipped)` : ""),
  );
  if (pushes === 0) throw new Error("no successful pushes");
  console.log("=== UPDATER OK: real-data oracle stream landed on-chain ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[updater] FAIL:", e); process.exit(1); });
