// Failure-artifact + small filesystem helpers — the subset of the legacy
// simulations `shared.ts` that the harness executor needs (the rest of shared.ts
// was CSV-scenario parsing, intentionally left behind).
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

const instanceDir = process.env.INSTANCE_DIR ?? process.cwd();

export const FAILED_TRANSACTIONS_DIR = path.join(instanceDir, "artifacts", "failed_transactions");

export function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

export function ensureDir(dirPath: string): void {
  mkdirSync(dirPath, { recursive: true });
}

export function writeJson(filePath: string, value: unknown): void {
  ensureDir(path.dirname(filePath));
  writeFileSync(filePath, JSON.stringify(value, null, 2));
}
