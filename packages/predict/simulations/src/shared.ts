import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname } from "path";
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

export interface DigestEntry {
  index: number;
  action: ActionName;
  digest: string;
  wallMs: number;
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

export interface DigestsFile {
  predictId: string;
  oracleId: string;
  managerId: string;
  summary: {
    totalRows: number;
    byAction: Record<ActionName, number>;
  };
  digests: DigestEntry[];
}

export interface TxMetricRow {
  index: number;
  action: ActionName;
  digest: string;
  wallMs: number;
  computationCost: number;
  computationCostSui: number;
  storageCost: number;
  storageCostSui: number;
  storageRebate: number;
  storageRebateSui: number;
  gasTotal: number;
  gasTotalSui: number;
  timestampMs: string | null;
}

export interface MintAnalysisRow extends TxMetricRow {
  mintIndex: number;
  strike: string;
  isUp: boolean;
  quantity: string;
  cost: string | null;
  askPrice: string | null;
  predictVersionBefore: string;
  predictVersionAfter: string;
  vaultBalanceBefore: string;
  vaultBalanceAfter: string;
  vaultBalanceDelta: string;
  vaultTotalMtmBefore: string;
  vaultTotalMtmAfter: string;
  vaultTotalMtmDelta: string;
}

export interface MetricSummary {
  count: number;
  gas: {
    avg: number;
    min: number;
    max: number;
    avgSui: number;
    minSui: number;
    maxSui: number;
  };
  wallMs: {
    avg: number;
    min: number;
    max: number;
  };
  computationCost: {
    avg: number;
    min: number;
    max: number;
    avgSui: number;
  };
  storageCost: {
    avg: number;
    min: number;
    max: number;
    avgSui: number;
  };
  storageRebate: {
    avg: number;
    min: number;
    max: number;
    avgSui: number;
  };
}

export interface ResultsFile {
  summary: {
    totalTxs: number;
    byAction: Record<ActionName, MetricSummary>;
    vault: {
      balance: string;
      totalMtm: string;
    };
  };
  mints: MintAnalysisRow[];
}

export const SCENARIO_PATH = fileURLToPath(new URL("../data/scenario_mar6_1000mints.csv", import.meta.url));
export const ARTIFACTS_DIR = fileURLToPath(new URL("../artifacts", import.meta.url));
export const STATE_PATH = fileURLToPath(new URL("../artifacts/state.json", import.meta.url));
export const DIGESTS_PATH = fileURLToPath(new URL("../artifacts/digests.json", import.meta.url));
export const RESULTS_PATH = fileURLToPath(new URL("../artifacts/results.json", import.meta.url));

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

export function writeJson(path: string, value: unknown): void {
  ensureDir(dirname(path));
  writeFileSync(path, JSON.stringify(value, null, 2));
}
