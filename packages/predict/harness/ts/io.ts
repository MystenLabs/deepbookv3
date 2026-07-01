// Harness-level IO helpers that must NOT pull in the per-instance localnet env (env.ts
// loads deployment ids at import time, which the shared hub process doesn't have). Both
// paths resolve portably from import.meta.url, so the harness runs on any machine/CI.
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The harness API-key .env lives one level up from ts/ (packages/predict/harness/.env).
const HARNESS_ENV_FILE = fileURLToPath(new URL("../.env", import.meta.url));

// Read one KEY=value from the harness API-key .env (PYTH_PRO_API_KEY, BLOCK_SCHOLES_API_KEY).
export function harnessKey(name: string): string {
  for (const line of readFileSync(HARNESS_ENV_FILE, "utf8").split("\n")) {
    const m = line.match(new RegExp(`^${name}=(.*)$`));
    if (m) return m[1].trim().replace(/^["']|["']$/g, "");
  }
  throw new Error(`missing ${name} in ${HARNESS_ENV_FILE}`);
}

// Write a file atomically (temp + rename) so a concurrent reader in another process never
// observes a half-written file — torn reads were a whole-run-death risk on shared JSON.
export function atomicWriteFile(path: string, data: string): void {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, data);
  renameSync(tmp, path);
}
