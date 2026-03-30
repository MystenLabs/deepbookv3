import { mkdirSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

import type { FastExecutorState } from "./runtime.js";

export type ActionName = "update_prices" | "update_svi" | "mint";

export interface ScenarioRow {
  action: ActionName;
  spot: string;
  forward: string;
  a: string;
  b: string;
  rho: string;
  rho_negative: string;
  m: string;
  m_negative: string;
  sigma: string;
  risk_free_rate: string;
  strike: string;
  is_up: string;
  quantity: string;
}

export interface TxResult {
  index: number;
  action: ActionName;
  digest: string;
  wallMs: number;
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  gasTotal: number;
  strike?: string;
  isUp?: boolean;
  quantity?: string;
}

export interface SimState {
  predictId: string;
  oracleId: string;
  oracleCapId: string;
  managerId: string;
  expiry: string;
  fastExecutor: FastExecutorState;
}

function resolveInstanceDir(): string {
  const dir = process.env.INSTANCE_DIR;
  if (dir) return dir;
  return fileURLToPath(new URL("..", import.meta.url));
}

const instanceDir = resolveInstanceDir();

export const SCENARIO_PATH = fileURLToPath(new URL("../data/scenario_mar6_1000mints.csv", import.meta.url));
export const ARTIFACTS_DIR = path.join(instanceDir, "artifacts");
export const STATE_PATH = path.join(instanceDir, "artifacts", "state.json");
export const RESULTS_PATH = path.join(instanceDir, "artifacts", "results.json");

export function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

export function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

export function loadScenario(path = SCENARIO_PATH): ScenarioRow[] {
  const text = readFileSync(path, "utf8").replace(/\r/g, "");
  const [header, ...lines] = text.trim().split("\n");
  const columns = header.split(",");

  return lines.map((line) => {
    const values = line.split(",");
    const row: Record<string, string> = {};
    columns.forEach((column, index) => {
      row[column] = values[index] ?? "";
    });
    return row as unknown as ScenarioRow;
  });
}

export function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export function writeJson(filePath: string, value: unknown): void {
  ensureDir(path.dirname(filePath));
  writeFileSync(filePath, JSON.stringify(value, null, 2));
}
