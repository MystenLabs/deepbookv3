import { mkdirSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

export type ScenarioActionName =
  | "oracle_mint_ptb"
  | "update_prices"
  | "update_svi"
  | "mint"
  | "liquidate"
  | "redeem"
  | "supply"
  | "withdraw";

export interface OracleRefreshData {
  spot: bigint;
  forward: bigint;
  a: bigint;
  b: bigint;
  rho: bigint;
  rhoNegative: boolean;
  m: bigint;
  mNegative: boolean;
  sigma: bigint;
  riskFreeRate: bigint;
}

type WithOracleRefresh<T> = T & { oracleRefresh?: OracleRefreshData };

export type ScenarioRow =
  | { action: "update_prices"; lineNumber: number; step: number; spot: bigint; forward: bigint }
  | {
      action: "update_svi";
      lineNumber: number;
      step: number;
      a: bigint;
      b: bigint;
      rho: bigint;
      rhoNegative: boolean;
      m: bigint;
      mNegative: boolean;
      sigma: bigint;
      riskFreeRate: bigint;
    }
  | {
      action: "mint";
      lineNumber: number;
      step: number;
      strike: bigint;
      isUp: boolean;
      quantity: bigint;
      leverage: bigint;
      orderRef: string;
    }
  | {
      action: "oracle_mint_ptb";
      lineNumber: number;
      step: number;
      spot: bigint;
      forward: bigint;
      a: bigint;
      b: bigint;
      rho: bigint;
      rhoNegative: boolean;
      m: bigint;
      mNegative: boolean;
      sigma: bigint;
      riskFreeRate: bigint;
      strike: bigint;
      isUp: boolean;
      quantity: bigint;
      leverage: bigint;
      orderRef: string;
    }
  | WithOracleRefresh<{
      action: "liquidate";
      lineNumber: number;
      step: number;
      budget: bigint;
    }>
  | WithOracleRefresh<{
      action: "redeem";
      lineNumber: number;
      step: number;
      orderRef: string;
      closeQuantity: bigint;
      replacementOrderRef: string | null;
    }>
  | WithOracleRefresh<{
      action: "supply";
      lineNumber: number;
      step: number;
      amount: bigint;
      lpRef: string;
    }>
  | WithOracleRefresh<{
      action: "withdraw";
      lineNumber: number;
      step: number;
      lpRef: string;
    }>;

export type PriceRow = Extract<ScenarioRow, { action: "update_prices" }>;
export type SviRow = Extract<ScenarioRow, { action: "update_svi" }>;
export type MintRow = Extract<ScenarioRow, { action: "mint" | "oracle_mint_ptb" }>;

export interface LocalTraceStep {
  step: number;
  action: ScenarioActionName;
  digest: string;
  gas: GasLike;
  events: unknown[];
}

export interface GasLike {
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  gasTotal: number;
}

export interface LocalTraceFile {
  schema_version: "predict_local_trace_v1";
  steps: LocalTraceStep[];
}

export interface EconomicDataFile {
  schema_version: typeof ECONOMIC_SCHEMA_VERSION;
  scenario: {
    quantity_scale: string;
  };
  records: EconomicRecord[];
}

export interface EconomicRecord {
  step: number;
  action: ScenarioActionName;
  input: Record<string, unknown>;
  updates: Record<string, unknown>[];
  state: Record<string, string>;
}

export interface SimState {
  poolVaultId: string;
  protocolConfigId: string;
  expiryMarketId: string;
  pythSourceId: string;
  oracleId: string;
  oracleCapId: string;
  managerId: string;
}

type RawScenarioRow = Record<string, string>;

const SCENARIO_COLUMNS = [
  "tx",
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
  "leverage",
  "order_ref",
  "close_quantity",
  "replacement_order_ref",
  "budget",
  "amount",
  "lp_ref",
] as const;

const ORACLE_REFRESH_FIELDS = [
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
] as const;

const POSITION_LOT_SIZE = 10_000n;

function resolveInstanceDir(): string {
  const dir = process.env.INSTANCE_DIR;
  if (dir) return dir;
  return fileURLToPath(new URL("..", import.meta.url));
}

function isScenarioActionName(value: string): value is ScenarioActionName {
  return (
    value === "oracle_mint_ptb" ||
    value === "update_prices" ||
    value === "update_svi" ||
    value === "mint" ||
    value === "liquidate" ||
    value === "redeem" ||
    value === "supply" ||
    value === "withdraw"
  );
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

function parseOptionalUnsignedInteger(
  row: RawScenarioRow,
  field: string,
  lineNumber: number,
  defaultValue: bigint,
): bigint {
  const value = row[field] ?? "";
  if (value === "") return defaultValue;
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

function parseOptionalString(row: RawScenarioRow, field: string): string | null {
  const value = row[field] ?? "";
  return value === "" ? null : value;
}

function parseOptionalOracleRefresh(row: RawScenarioRow, lineNumber: number): { oracleRefresh?: OracleRefreshData } {
  const present = ORACLE_REFRESH_FIELDS.filter((field) => (row[field] ?? "") !== "");
  if (present.length === 0) return {};
  if (present.length !== ORACLE_REFRESH_FIELDS.length) {
    throw new Error(`Scenario line ${lineNumber}: oracle refresh fields must be all present or all empty`);
  }
  return {
    oracleRefresh: {
      spot: parseUnsignedInteger(row, "spot", lineNumber),
      forward: parseUnsignedInteger(row, "forward", lineNumber),
      a: parseUnsignedInteger(row, "a", lineNumber),
      b: parseUnsignedInteger(row, "b", lineNumber),
      rho: parseUnsignedInteger(row, "rho", lineNumber),
      rhoNegative: parseBoolean(row, "rho_negative", lineNumber),
      m: parseUnsignedInteger(row, "m", lineNumber),
      mNegative: parseBoolean(row, "m_negative", lineNumber),
      sigma: parseUnsignedInteger(row, "sigma", lineNumber),
      riskFreeRate: parseUnsignedInteger(row, "risk_free_rate", lineNumber),
    },
  };
}

function assertNoOracleRefresh(row: RawScenarioRow, lineNumber: number, action: string): void {
  const present = ORACLE_REFRESH_FIELDS.filter((field) => (row[field] ?? "") !== "");
  if (present.length !== 0) {
    throw new Error(
      `Scenario line ${lineNumber}: ${action} cannot include oracle refresh fields; use oracle_mint_ptb`,
    );
  }
}

function parseRef(row: RawScenarioRow, field: string, lineNumber: number): string {
  const value = requireField(row, field, lineNumber);
  if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(value)) {
    throw new Error(`Scenario line ${lineNumber}: invalid ${field} "${value}"`);
  }
  return value;
}

function parseMintQuantity(row: RawScenarioRow, field: string, lineNumber: number): bigint {
  const quantity = parseUnsignedInteger(row, field, lineNumber);
  const lots = quantity / POSITION_LOT_SIZE;
  if (lots <= 0n) {
    throw new Error(`Scenario line ${lineNumber}: mint quantity must be at least one position lot`);
  }
  if (quantity % POSITION_LOT_SIZE !== 0n) {
    throw new Error(`Scenario line ${lineNumber}: mint quantity must be a multiple of ${POSITION_LOT_SIZE}`);
  }
  return quantity;
}

function parseRow(row: RawScenarioRow, lineNumber: number): ScenarioRow {
  const action = requireField(row, "action", lineNumber);
  if (!isScenarioActionName(action)) {
    throw new Error(`Scenario line ${lineNumber}: unsupported action "${action}"`);
  }

  const step = Number(parseUnsignedInteger(row, "tx", lineNumber));
  if (!Number.isSafeInteger(step) || step <= 0) {
    throw new Error(`Scenario line ${lineNumber}: tx must be a positive safe integer`);
  }

  if (action === "update_prices") {
    return {
      action,
      lineNumber,
      step,
      spot: parseUnsignedInteger(row, "spot", lineNumber),
      forward: parseUnsignedInteger(row, "forward", lineNumber),
    };
  }

  if (action === "update_svi") {
    return {
      action,
      lineNumber,
      step,
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

  if (action === "mint") {
    assertNoOracleRefresh(row, lineNumber, action);
    return {
      action,
      lineNumber,
      step,
      strike: parseUnsignedInteger(row, "strike", lineNumber),
      isUp: parseBoolean(row, "is_up", lineNumber),
      quantity: parseMintQuantity(row, "quantity", lineNumber),
      leverage: parseOptionalUnsignedInteger(row, "leverage", lineNumber, 0n),
      orderRef: parseRef(row, "order_ref", lineNumber),
    };
  }

  if (action === "oracle_mint_ptb") {
    return {
      action,
      lineNumber,
      step,
      spot: parseUnsignedInteger(row, "spot", lineNumber),
      forward: parseUnsignedInteger(row, "forward", lineNumber),
      a: parseUnsignedInteger(row, "a", lineNumber),
      b: parseUnsignedInteger(row, "b", lineNumber),
      rho: parseUnsignedInteger(row, "rho", lineNumber),
      rhoNegative: parseBoolean(row, "rho_negative", lineNumber),
      m: parseUnsignedInteger(row, "m", lineNumber),
      mNegative: parseBoolean(row, "m_negative", lineNumber),
      sigma: parseUnsignedInteger(row, "sigma", lineNumber),
      riskFreeRate: parseUnsignedInteger(row, "risk_free_rate", lineNumber),
      strike: parseUnsignedInteger(row, "strike", lineNumber),
      isUp: parseBoolean(row, "is_up", lineNumber),
      quantity: parseMintQuantity(row, "quantity", lineNumber),
      leverage: parseOptionalUnsignedInteger(row, "leverage", lineNumber, 0n),
      orderRef: parseRef(row, "order_ref", lineNumber),
    };
  }

  if (action === "liquidate") {
    return {
      action,
      lineNumber,
      step,
      ...parseOptionalOracleRefresh(row, lineNumber),
      budget: parseUnsignedInteger(row, "budget", lineNumber),
    };
  }

  if (action === "redeem") {
    return {
      action,
      lineNumber,
      step,
      ...parseOptionalOracleRefresh(row, lineNumber),
      orderRef: parseRef(row, "order_ref", lineNumber),
      closeQuantity: parseMintQuantity(row, "close_quantity", lineNumber),
      replacementOrderRef: parseOptionalString(row, "replacement_order_ref"),
    };
  }

  if (action === "supply") {
    return {
      action,
      lineNumber,
      step,
      ...parseOptionalOracleRefresh(row, lineNumber),
      amount: parseUnsignedInteger(row, "amount", lineNumber),
      lpRef: parseRef(row, "lp_ref", lineNumber),
    };
  }

  return {
    action,
    lineNumber,
    step,
    ...parseOptionalOracleRefresh(row, lineNumber),
    lpRef: parseRef(row, "lp_ref", lineNumber),
  };
}

const instanceDir = resolveInstanceDir();

export const ECONOMIC_SCHEMA_VERSION = "predict_economic_v1";
export const LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v1";
export const SCENARIO_PATH = fileURLToPath(new URL("../data/generated/normal_scenario.csv", import.meta.url));
export const STATE_PATH = path.join(instanceDir, "artifacts", "state.json");
export const LOCAL_TRACE_PATH = path.join(instanceDir, "artifacts", "local_trace.json");
export const LOCAL_DATA_PATH = path.join(instanceDir, "artifacts", "local_data.json");
export const PYTHON_DATA_PATH = path.join(instanceDir, "artifacts", "python_data.json");

export function scenarioQuantityScale(): string {
  return "1";
}

export function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

export function ensureDir(dirPath: string): void {
  mkdirSync(dirPath, { recursive: true });
}

export function parseScenarioText(text: string): ScenarioRow[] {
  text = text.replace(/\r/g, "");
  const [header, ...lines] = text.trim().split("\n");
  const columns = header.split(",").map((column) => column.trim());

  for (const expectedColumn of SCENARIO_COLUMNS) {
    if (!columns.includes(expectedColumn)) {
      throw new Error(`Scenario header is missing required column ${expectedColumn}`);
    }
  }

  let lastStep = 0;
  return lines.map((line, index) => {
    const values = line.split(",");
    const row: RawScenarioRow = {};
    columns.forEach((column, valueIndex) => {
      row[column] = (values[valueIndex] ?? "").trim();
    });
    const parsed = parseRow(row, index + 2);
    if (parsed.step <= lastStep) {
      throw new Error(`Scenario line ${parsed.lineNumber}: tx values must be strictly increasing`);
    }
    lastStep = parsed.step;
    return parsed;
  });
}

export function loadScenario(path = SCENARIO_PATH): ScenarioRow[] {
  return parseScenarioText(readFileSync(path, "utf8"));
}

export function readJson<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, "utf8")) as T;
}

export function validateSimState(value: SimState): SimState {
  const requiredFields = [
    "poolVaultId",
    "protocolConfigId",
    "expiryMarketId",
    "pythSourceId",
    "oracleId",
    "oracleCapId",
    "managerId",
  ] as const;
  for (const field of requiredFields) {
    if (typeof value[field] !== "string" || value[field].length === 0) {
      throw new Error(
        `Simulation state is missing ${field}; rerun setup after the parallel pool rearchitecture`
      );
    }
  }
  return value;
}

export function writeJson(filePath: string, value: unknown): void {
  ensureDir(path.dirname(filePath));
  writeFileSync(filePath, JSON.stringify(value, null, 2));
}
