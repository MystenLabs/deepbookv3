import { readFileSync, existsSync } from "fs";
import path from "path";
import { LOGS_DIR } from "./config.js";

const services = [
  { name: "oracle-updater", maxStaleMs: 60_000 },
  { name: "fuzz-worker", maxStaleMs: 30_000 },
];

let healthy = true;

for (const svc of services) {
  const hbPath = path.join(LOGS_DIR, `${svc.name}.heartbeat`);
  if (!existsSync(hbPath)) {
    console.log(`[${svc.name}] NOT RUNNING (no heartbeat file)`);
    healthy = false;
    continue;
  }
  const ts = readFileSync(hbPath, "utf8").trim();
  const age = Date.now() - new Date(ts).getTime();
  if (age > svc.maxStaleMs) {
    console.log(`[${svc.name}] STALE (last heartbeat ${Math.round(age / 1000)}s ago)`);
    healthy = false;
  } else {
    console.log(`[${svc.name}] OK (last heartbeat ${Math.round(age / 1000)}s ago)`);
  }
}

process.exit(healthy ? 0 : 1);
