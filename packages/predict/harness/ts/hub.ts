// Shared market-data hub: ONE WS pair (Pyth + Block Scholes) feeding N parallel localnets.
// Streams a rolling grid and writes a global snapshot (HUB_SNAPSHOT) each tick; each
// localnet's updater reads it via HubSource instead of opening its own WS. Optionally
// appends every snapshot to HUB_RECORD (JSONL) for deterministic replay.
import { appendFileSync } from "node:fs";

import { atomicWriteFile } from "./io.js";
import { DirectWsSource } from "./marketSource.js";

const DURATION_MS = Number(process.env.DURATION_MS ?? 0);
const LOOP_MS = Number(process.env.LOOP_MS ?? 1000);
const HUB_SNAPSHOT = process.env.HUB_SNAPSHOT ?? "";
const HUB_RECORD = process.env.HUB_RECORD; // optional JSONL record for replay
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  if (!HUB_SNAPSHOT) throw new Error("HUB_SNAPSHOT path required");
  const gridNow = () =>
    (process.env.GRID_SPEC ?? "60000:6").split(",").flatMap((part) => {
      const [period, count] = part.split(":").map(Number);
      const base = Math.floor(Date.now() / period) * period;
      return Array.from({ length: count }, (_, i) => base + (i + 1) * period);
    });
  const source = new DirectWsSource();
  await source.start(gridNow());
  console.log(`[hub] one WS pair -> ${HUB_SNAPSHOT} (GRID_SPEC=${process.env.GRID_SPEC ?? "60000:6"}); warming up...`);

  let shutdown = false;
  process.on("SIGTERM", () => { shutdown = true; });
  process.on("SIGINT", () => { shutdown = true; });

  const start = Date.now();
  let writes = 0;
  while (!shutdown && (DURATION_MS === 0 || Date.now() - start < DURATION_MS)) {
    await sleep(LOOP_MS);
    source.ensureExpiries(gridNow());
    const snap = source.latest();
    if (!snap || snap.expiries.size === 0) continue;
    const json = JSON.stringify({
      spot1e9: snap.spot1e9.toString(),
      publishedAtMs: snap.publishedAtMs.toString(),
      expiries: Object.fromEntries([...snap.expiries.entries()]),
    });
    atomicWriteFile(HUB_SNAPSHOT, json);
    if (HUB_RECORD) appendFileSync(HUB_RECORD, `${json}\n`);
    writes++;
    if (writes <= 3 || writes % 10 === 0)
      console.log(`[hub] snapshot #${writes} spot=$${(Number(snap.spot1e9) / 1e9).toFixed(2)} expiries=${snap.expiries.size}`);
  }
  source.stop();
  console.log(`[hub] done: ${writes} snapshots over ${((Date.now() - start) / 1000).toFixed(0)}s`);
}

main().then(() => process.exit(0)).catch((e) => { console.error("[hub] FAIL:", e); process.exit(1); });
