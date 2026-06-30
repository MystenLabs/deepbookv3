// Continuous oracle updater (substrate component of `harness up`).
//
// Streams real Pyth Pro + Block Scholes data onto the propbook feeds at high frequency,
// stamping each update with the provider's REAL publish time (clamped to <= Clock,
// monotonic). The feed ids come from the keeper (feeds.json); the data comes from a
// `MarketSource` chosen by env: a shared hub snapshot (parallel runs), a recorded replay,
// or this localnet's own provider WS pair. Each push also writes snapshot.json for the
// trade generator (the keeper settles independently via the Pyth Lazer history endpoint).
import { existsSync, readFileSync } from "node:fs";

import { getSigner, getSignerForAddress } from "./env.js";
import { atomicWriteFile } from "./io.js";
import { type MarketSource, DirectWsSource, HubSource, ReplaySource } from "./marketSource.js";
import { type Feeds } from "./predictSetup.js";
import { buildOracleRefreshGridTx, clampedSourceTimestampMs, signExecThreaded } from "./runtime.js";

const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = run until SIGTERM
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const GAS_BUDGET = 1_000_000_000;
const SCALE_1E9 = 1_000_000_000;

const to1e9 = (x: number) => BigInt(Math.round(x * SCALE_1E9));
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
  tx.setSender(signer.getPublicKey().toSuiAddress());
  tx.setGasBudget(GAS_BUDGET);
  const r = await signExecThreaded(tx, signer, { showEffects: true });
  const status = (r as any).effects?.status?.status;
  if (status !== "success") throw new Error(`status=${JSON.stringify((r as any).effects?.status)}`);
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
  console.log(`[updater] feeds from keeper: pyth=${feeds.pythFeedId.slice(0, 10)} svi=${feeds.bsSviFeedId.slice(0, 10)}`);

  // Warm a ROLLING grid of boundary expiries. GRID_SPEC = "periodMs:count,..." (the
  // launcher sets it from the keeper's cadence). gridNow() = the next `count` boundaries
  // of each period from now, re-evaluated each loop so the grid rolls forward as
  // boundaries pass and the keeper's new markets stay warm over long runs.
  const gridNow = () =>
    (process.env.GRID_SPEC ?? "60000:6").split(",").flatMap((part) => {
      const [period, count] = part.split(":").map(Number);
      const base = Math.floor(Date.now() / period) * period;
      return Array.from({ length: count }, (_, i) => base + (i + 1) * period);
    });
  const { source, mode } = makeSource();
  await source.start(gridNow());
  console.log(`[updater] source=${mode}; streaming a rolling grid (GRID_SPEC=${process.env.GRID_SPEC ?? "60000:6"})...`);

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
    source.ensureExpiries(gridNow()); // roll the warmed grid forward as boundaries pass
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
      // Publish the snapshot for the trade generator ONLY after the on-chain refresh landed —
      // otherwise traders price/guard off oracle data that never made it on-chain, producing
      // spurious guard aborts that look like harness failures.
      atomicWriteFile(`${INSTANCE_DIR}/snapshot.json`, JSON.stringify({
        spot1e9: snap.spot1e9.toString(),
        publishedAtMs: ts.toString(),
        expiries: Object.fromEntries([...snap.expiries.entries()]),
      }));
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
  if (pushes === 0 && mode !== "replay") throw new Error("no successful pushes");
  console.log("=== UPDATER OK: real-data oracle stream landed on-chain ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[updater] FAIL:", e); process.exit(1); });
