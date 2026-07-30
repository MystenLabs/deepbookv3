// Shared market-data hub: ONE WS pair (Pyth + Block Scholes) feeding N parallel localnets.
// Streams a rolling grid and writes a global snapshot (HUB_SNAPSHOT) each tick; each
// localnet's updater reads it via HubSource instead of opening its own WS.

import { atomicWriteFile } from "./io.js";
import { DirectWsSource, serializableSnapshot } from "./marketSource.js";
import { gridExpiries, requiredEnv, requiredNonnegativeInt } from "./runnerConfig.js";

const DURATION_MS = requiredNonnegativeInt("DURATION_MS");
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const HUB_SNAPSHOT = requiredEnv("HUB_SNAPSHOT");
const HUB_METRICS = requiredEnv("HUB_METRICS");
const GRID_SPEC = requiredEnv("GRID_SPEC");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // Deduped grid: with multiple cadences periods share boundaries (e.g. the top of the hour is in
  // all three) — a duplicate expiry would mean duplicate sids in the BS batch.
  const gridNow = () => gridExpiries(GRID_SPEC);
  const source = new DirectWsSource();
  const start = Date.now();
  let writes = 0;
  const writeMetrics = () => atomicWriteFile(HUB_METRICS, JSON.stringify({
    elapsed_ms: Date.now() - start,
    snapshots: writes,
    source: source.diagnostics?.() ?? {},
  }));
  try {
    await source.start(gridNow());
    console.log(`[hub] one WS pair -> ${HUB_SNAPSHOT} (GRID_SPEC=${GRID_SPEC}); warming up...`);

    let shutdown = false;
    process.on("SIGTERM", () => { shutdown = true; });
    process.on("SIGINT", () => { shutdown = true; });

    while (!shutdown && (DURATION_MS === 0 || Date.now() - start < DURATION_MS)) {
      await sleep(LOOP_MS);
      source.ensureExpiries(gridNow());
      const snap = source.latest();
      if (!snap || snap.expiries.size === 0) continue;
      const json = JSON.stringify(serializableSnapshot(snap));
      atomicWriteFile(HUB_SNAPSHOT, json);
      writes++;
      writeMetrics();
      if (writes <= 3 || writes % 10 === 0)
        console.log(`[hub] snapshot #${writes} spot=$${(Number(snap.spot1e9) / 1e9).toFixed(2)} expiries=${snap.expiries.size}`);
    }
  } finally {
    source.stop();
    writeMetrics();
    console.log(`[hub] done: ${writes} snapshots over ${((Date.now() - start) / 1000).toFixed(0)}s`);
  }
}

main().then(() => process.exit(0)).catch((e) => { console.error("[hub] FAIL:", e); process.exit(1); });
