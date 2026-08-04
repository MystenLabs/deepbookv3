// Canonical instance artifact paths and small filesystem helpers shared by the
// harness executor and deterministic simulation.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

const configuredInstanceDir = process.env.INSTANCE_DIR;
if (!configuredInstanceDir) throw new Error("INSTANCE_DIR is required");
export const INSTANCE_DIR = configuredInstanceDir;

export const FAILED_TRANSACTIONS_DIR = path.join(INSTANCE_DIR, "artifacts", "failed_transactions");

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
