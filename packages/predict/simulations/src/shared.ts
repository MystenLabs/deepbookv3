import { mkdirSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

export type ActionName = "update_prices" | "update_svi" | "mint";

export type ScenarioRow =
  | { action: "update_prices"; spot: bigint; forward: bigint }
  | {
      action: "update_svi";
      a: bigint;
      b: bigint;
      rho: bigint;
      rhoNegative: boolean;
      m: bigint;
      mNegative: boolean;
      sigma: bigint;
      riskFreeRate: bigint;
    }
  | { action: "mint"; strike: bigint; isUp: boolean; quantity: bigint };

export interface ExecutionResult {
  wallMs: number;
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  gasTotal: number;
}

export interface ActionSummary {
  count: number;
  gas: { avg: number; min: number; max: number };
  wallMs: { avg: number; min: number; max: number };
}

export interface ResultsFile {
  schema_version: typeof RESULTS_SCHEMA_VERSION;
  summary: {
    totalTxs: number;
    byAction: Partial<Record<ActionName, ActionSummary>>;
  };
  mints: ExecutionResult[];
}

export interface SimState {
  predictId: string;
  oracleId: string;
  oracleCapId: string;
  managerId: string;
  expiry: string;
}

type RawScenarioRow = Record<string, string>;

const SCENARIO_COLUMNS = [
  "action",
  "spot",
  "forward",
  "a",
  "b",
  "rho",
  "rho_negative",
  "m",
  "m_negative",
  "sigma",
  "risk_free_rate",
  "strike",
  "is_up",
  "quantity",
] as const;

const SCENARIO_QUANTITY_SCALE = 1000n;

function resolveInstanceDir(): string {
  const dir = process.env.INSTANCE_DIR;
  if (dir) return dir;
  return fileURLToPath(new URL("..", import.meta.url));
}

function isActionName(value: string): value is ActionName {
  return value === "update_prices" || value === "update_svi" || value === "mint";
}

function requireField(row: RawScenarioRow, field: string, lineNumber: number): string {
  const value = row[field] ?? "";
  if (value === "") {
    throw new Error(`Scenario line ${lineNumber}: missing ${field}`);
  }
  return value;
}

function parseUnsignedInteger(row: RawScenarioRow, field: string, lineNumber: number): bigint {
  const value = requireField(row, field, lineNumber);
  if (!/^\d+$/.test(value)) {
    throw new Error(`Scenario line ${lineNumber}: expected ${field} to be an unsigned integer, got "${value}"`);
  }
  return BigInt(value);
}

function parseBoolean(row: RawScenarioRow, field: string, lineNumber: number): boolean {
  const value = requireField(row, field, lineNumber);
  if (value !== "true" && value !== "false") {
    throw new Error(`Scenario line ${lineNumber}: expected ${field} to be true/false, got "${value}"`);
  }
  return value === "true";
}

function normalizeMintQuantity(rawQuantity: bigint, lineNumber: number): bigint {
  const normalized = rawQuantity / SCENARIO_QUANTITY_SCALE;
  if (normalized <= 0n) {
    throw new Error(`Scenario line ${lineNumber}: normalized mint quantity must be positive`);
  }
  return normalized;
}

function parseRow(row: RawScenarioRow, lineNumber: number): ScenarioRow {
  const action = requireField(row, "action", lineNumber);
  if (!isActionName(action)) {
    throw new Error(`Scenario line ${lineNumber}: unsupported action "${action}"`);
  }

  if (action === "update_prices") {
    return {
      action,
      spot: parseUnsignedInteger(row, "spot", lineNumber),
      forward: parseUnsignedInteger(row, "forward", lineNumber),
    };
  }

  if (action === "update_svi") {
    return {
      action,
      a: parseUnsignedInteger(row, "a", lineNumber),
      b: parseUnsignedInteger(row, "b", lineNumber),
      rho: parseUnsignedInteger(row, "rho", lineNumber),
      rhoNegative: parseBoolean(row, "rho_negative", lineNumber),
      m: parseUnsignedInteger(row, "m", lineNumber),
      mNegative: parseBoolean(row, "m_negative", lineNumber),
      sigma: parseUnsignedInteger(row, "sigma", lineNumber),
      riskFreeRate: parseUnsignedInteger(row, "risk_free_rate", lineNumber),
    };
  }

  return {
    action,
    strike: parseUnsignedInteger(row, "strike", lineNumber),
    isUp: parseBoolean(row, "is_up", lineNumber),
    quantity: normalizeMintQuantity(parseUnsignedInteger(row, "quantity", lineNumber), lineNumber),
  };
}

const instanceDir = resolveInstanceDir();

export const RESULTS_SCHEMA_VERSION = "results_v2";
export const SCENARIO_PATH = fileURLToPath(new URL("../data/scenario_mar6_1000mints.csv", import.meta.url));
export const STATE_PATH = path.join(instanceDir, "artifacts", "state.json");
export const RESULTS_PATH = path.join(instanceDir, "artifacts", "results.json");

export function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

export function ensureDir(dirPath: string): void {
  mkdirSync(dirPath, { recursive: true });
}

export function loadScenario(path = SCENARIO_PATH): ScenarioRow[] {
  const text = readFileSync(path, "utf8").replace(/\r/g, "");
  const [header, ...lines] = text.trim().split("\n");
  const columns = header.split(",").map((column) => column.trim());

  for (const expectedColumn of SCENARIO_COLUMNS) {
    if (!columns.includes(expectedColumn)) {
      throw new Error(`Scenario header is missing required column ${expectedColumn}`);
    }
  }

  return lines.map((line, index) => {
    const values = line.split(",");
    const row: RawScenarioRow = {};
    columns.forEach((column, valueIndex) => {
      row[column] = (values[valueIndex] ?? "").trim();
    });
    return parseRow(row, index + 2);
  });
}

export function readJson<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, "utf8")) as T;
}

export function writeJson(filePath: string, value: unknown): void {
  ensureDir(path.dirname(filePath));
  writeFileSync(filePath, JSON.stringify(value, null, 2));
}
