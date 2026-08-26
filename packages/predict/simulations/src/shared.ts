import { readFileSync } from "fs";
import path from "path";

import {
    FAILED_TRANSACTIONS_DIR,
    INSTANCE_DIR,
    ensureDir,
    ts,
    writeJson,
} from "../../devtools/ts/artifacts.js";
import { type GasUsage, type OracleFeedIds } from "../../devtools/ts/runtime.js";

export { FAILED_TRANSACTIONS_DIR, ensureDir, ts, writeJson };

export type ScenarioActionName =
    | "mint"
    | "redeem_live"
    | "request_supply"
    | "request_withdraw"
    | "flush"
    | "rebalance_expiry_cash"
    | "settle"
    | "redeem_settled";

export const REQUIRED_ACTIONS: ScenarioActionName[] = [
    "mint",
    "redeem_live",
    "request_supply",
    "request_withdraw",
    "flush",
    "rebalance_expiry_cash",
    "settle",
    "redeem_settled",
];

export const EXPECTED_ACTION_SEQUENCE: ScenarioActionName[] = [
    "mint",
    "mint",
    "redeem_live",
    "request_supply",
    "flush",
    "request_withdraw",
    "flush",
    "mint",
    "redeem_live",
    "rebalance_expiry_cash",
    "mint",
    "mint",
    "settle",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "flush",
    "request_supply",
    "flush",
];

export interface OracleRefreshData {
    spot: bigint;
    forward: bigint;
    a: bigint;
    aNegative: boolean;
    b: bigint;
    rho: bigint;
    rhoNegative: boolean;
    m: bigint;
    mNegative: boolean;
    sigma: bigint;
    riskFreeRate: bigint;
}

interface ScenarioRowBase {
    lineNumber: number;
    step: number;
}

export type ScenarioRow =
    | (ScenarioRowBase &
          OracleRefreshData & {
              action: "mint";
              strike: bigint;
              isUp: boolean;
              quantity: bigint;
              orderRef: string;
          })
    | (ScenarioRowBase & {
          action: "redeem_live";
          oracleRefresh: OracleRefreshData;
          orderRef: string;
          closeQuantity: bigint;
          replacementOrderRef: string | null;
      })
    | (ScenarioRowBase & {
          action: "request_supply";
          amount: bigint;
          minOutput: bigint;
          lpRef: string;
      })
    | (ScenarioRowBase & {
          action: "request_withdraw";
          shares: bigint;
          minOutput: bigint;
          lpRef: string;
      })
    | (ScenarioRowBase & {
          action: "flush";
          oracleRefresh: OracleRefreshData | null;
      })
    | (ScenarioRowBase & { action: "rebalance_expiry_cash" })
    | (ScenarioRowBase & { action: "settle"; settlementPrice: bigint })
    | (ScenarioRowBase & { action: "redeem_settled"; orderRef: string });

export type MintRow = Extract<ScenarioRow, { action: "mint" }>;
export type OracleRefreshRow = Extract<
    ScenarioRow,
    { action: "mint" | "redeem_live" | "flush" }
>;

export interface LocalTraceStep {
    step: number;
    action: ScenarioActionName;
    digest: string;
    pricingTimestampMs: number;
    wallMs: number;
    gas: GasUsage;
    events: LocalTraceEvent[];
}

export interface LocalTraceEvent {
    type: string;
    full_type: string;
    parsedJson: unknown;
}

export interface LocalTraceFile {
    schema_version: typeof LOCAL_TRACE_SCHEMA_VERSION;
    steps: LocalTraceStep[];
}

export interface EconomicDataFile {
    schema_version: typeof ECONOMIC_SCHEMA_VERSION;
    scenario: {
        quantity_scale: string;
        required_actions: ScenarioActionName[];
        observed_actions: ScenarioActionName[];
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

export interface SimState extends OracleFeedIds {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    expiryMs: string;
    accountWrapperId: string;
    lifecycleCapId: string;
    initialExpiryCash: string;
    tickSize: string;
}

type RawScenarioRow = Record<string, string>;

export const SCENARIO_COLUMNS = [
    "tx",
    "action",
    "spot",
    "forward",
    "a",
    "a_negative",
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
    "order_ref",
    "close_quantity",
    "replacement_order_ref",
    "amount",
    "shares",
    "min_output",
    "lp_ref",
    "settlement_price",
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
] as const;

const ORACLE_REFRESH_FIELDS = [
    "spot",
    "forward",
    "a",
    "a_negative",
    "b",
    "rho",
    "rho_negative",
    "m",
    "m_negative",
    "sigma",
    "risk_free_rate",
] as const;

const POSITION_LOT_SIZE = 10_000n;

function requireField(row: RawScenarioRow, field: string, lineNumber: number): string {
    const value = row[field] ?? "";
    if (value === "") throw new Error(`Scenario line ${lineNumber}: missing ${field}`);
    return value;
}

function parseUnsignedInteger(row: RawScenarioRow, field: string, lineNumber: number): bigint {
    const value = requireField(row, field, lineNumber);
    if (!/^\d+$/.test(value)) {
        throw new Error(
            `Scenario line ${lineNumber}: expected ${field} to be an unsigned integer, got "${value}"`,
        );
    }
    return BigInt(value);
}

function parseBoolean(row: RawScenarioRow, field: string, lineNumber: number): boolean {
    const value = requireField(row, field, lineNumber);
    if (value !== "true" && value !== "false") {
        throw new Error(
            `Scenario line ${lineNumber}: expected ${field} to be true/false, got "${value}"`,
        );
    }
    return value === "true";
}

function parseOptionalString(row: RawScenarioRow, field: string): string | null {
    const value = row[field] ?? "";
    return value === "" ? null : value;
}

function parseOracleRefresh(row: RawScenarioRow, lineNumber: number): OracleRefreshData {
    const present = ORACLE_REFRESH_FIELDS.filter((field) => (row[field] ?? "") !== "");
    if (present.length !== ORACLE_REFRESH_FIELDS.length) {
        throw new Error(`Scenario line ${lineNumber}: oracle refresh fields must all be present`);
    }
    return {
        spot: parseUnsignedInteger(row, "spot", lineNumber),
        forward: parseUnsignedInteger(row, "forward", lineNumber),
        a: parseUnsignedInteger(row, "a", lineNumber),
        aNegative: parseBoolean(row, "a_negative", lineNumber),
        b: parseUnsignedInteger(row, "b", lineNumber),
        rho: parseUnsignedInteger(row, "rho", lineNumber),
        rhoNegative: parseBoolean(row, "rho_negative", lineNumber),
        m: parseUnsignedInteger(row, "m", lineNumber),
        mNegative: parseBoolean(row, "m_negative", lineNumber),
        sigma: parseUnsignedInteger(row, "sigma", lineNumber),
        riskFreeRate: parseUnsignedInteger(row, "risk_free_rate", lineNumber),
    };
}

function parseOptionalOracleRefresh(
    row: RawScenarioRow,
    lineNumber: number,
): OracleRefreshData | null {
    const present = ORACLE_REFRESH_FIELDS.filter((field) => (row[field] ?? "") !== "");
    if (present.length === 0) return null;
    return parseOracleRefresh(row, lineNumber);
}

function parseRef(row: RawScenarioRow, field: string, lineNumber: number): string {
    const value = requireField(row, field, lineNumber);
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(value)) {
        throw new Error(`Scenario line ${lineNumber}: invalid ${field} "${value}"`);
    }
    return value;
}

function parseQuantity(row: RawScenarioRow, field: string, lineNumber: number): bigint {
    const quantity = parseUnsignedInteger(row, field, lineNumber);
    if (quantity < POSITION_LOT_SIZE || quantity % POSITION_LOT_SIZE !== 0n) {
        throw new Error(
            `Scenario line ${lineNumber}: ${field} must be a positive multiple of ${POSITION_LOT_SIZE}`,
        );
    }
    return quantity;
}

function parseStep(row: RawScenarioRow, lineNumber: number): number {
    const step = Number(parseUnsignedInteger(row, "tx", lineNumber));
    if (!Number.isSafeInteger(step) || step <= 0) {
        throw new Error(`Scenario line ${lineNumber}: tx must be a positive safe integer`);
    }
    return step;
}

function parseRow(row: RawScenarioRow, lineNumber: number): ScenarioRow {
    const action = requireField(row, "action", lineNumber) as ScenarioActionName;
    const step = parseStep(row, lineNumber);
    if (action === "mint") {
        return {
            action,
            lineNumber,
            step,
            ...parseOracleRefresh(row, lineNumber),
            strike: parseUnsignedInteger(row, "strike", lineNumber),
            isUp: parseBoolean(row, "is_up", lineNumber),
            quantity: parseQuantity(row, "quantity", lineNumber),
            orderRef: parseRef(row, "order_ref", lineNumber),
        };
    }
    if (action === "redeem_live") {
        return {
            action,
            lineNumber,
            step,
            oracleRefresh: parseOracleRefresh(row, lineNumber),
            orderRef: parseRef(row, "order_ref", lineNumber),
            closeQuantity: parseQuantity(row, "close_quantity", lineNumber),
            replacementOrderRef: parseOptionalString(row, "replacement_order_ref"),
        };
    }
    if (action === "request_supply") {
        return {
            action,
            lineNumber,
            step,
            amount: parseUnsignedInteger(row, "amount", lineNumber),
            minOutput: parseUnsignedInteger(row, "min_output", lineNumber),
            lpRef: parseRef(row, "lp_ref", lineNumber),
        };
    }
    if (action === "request_withdraw") {
        return {
            action,
            lineNumber,
            step,
            shares: parseUnsignedInteger(row, "shares", lineNumber),
            minOutput: parseUnsignedInteger(row, "min_output", lineNumber),
            lpRef: parseRef(row, "lp_ref", lineNumber),
        };
    }
    if (action === "flush") {
        return {
            action,
            lineNumber,
            step,
            oracleRefresh: parseOptionalOracleRefresh(row, lineNumber),
        };
    }
    if (action === "rebalance_expiry_cash") return { action, lineNumber, step };
    if (action === "settle") {
        return {
            action,
            lineNumber,
            step,
            settlementPrice: parseUnsignedInteger(row, "settlement_price", lineNumber),
        };
    }
    if (action === "redeem_settled") {
        return {
            action,
            lineNumber,
            step,
            orderRef: parseRef(row, "order_ref", lineNumber),
        };
    }
    throw new Error(`Scenario line ${lineNumber}: unsupported action "${action}"`);
}

export const ECONOMIC_SCHEMA_VERSION = "predict_economic_v4";
export const LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v5";
export const STATE_PATH = path.join(INSTANCE_DIR, "artifacts", "state.json");
export const LOCAL_TRACE_PATH = path.join(INSTANCE_DIR, "artifacts", "local_trace.json");
export const LOCAL_DATA_PATH = path.join(INSTANCE_DIR, "artifacts", "local_data.json");
export const LOCAL_TRACE_PARTIAL_PATH = path.join(
    INSTANCE_DIR,
    "artifacts",
    "local_trace.partial.json",
);
export const LOCAL_DATA_PARTIAL_PATH = path.join(
    INSTANCE_DIR,
    "artifacts",
    "local_data.partial.json",
);
export const PYTHON_DATA_PATH = path.join(INSTANCE_DIR, "artifacts", "python_data.json");

export function scenarioQuantityScale(): string {
    return "1";
}

export function parseScenarioText(text: string): ScenarioRow[] {
    const normalized = text.replace(/\r/g, "").trim();
    if (normalized === "") throw new Error("Scenario is empty");
    const [header, ...lines] = normalized.split("\n");
    const columns = header.split(",").map((column) => column.trim());
    if (
        columns.length !== SCENARIO_COLUMNS.length ||
        columns.some((column, index) => column !== SCENARIO_COLUMNS[index])
    ) {
        throw new Error(
            `Scenario header does not match schema: expected ${SCENARIO_COLUMNS.join(",")}`,
        );
    }

    let lastStep = 0;
    return lines.map((line, index) => {
        const values = line.split(",");
        if (values.length !== columns.length) {
            throw new Error(
                `Scenario line ${index + 2}: expected ${columns.length} columns, got ${values.length}`,
            );
        }
        const raw: RawScenarioRow = {};
        columns.forEach((column, valueIndex) => {
            raw[column] = values[valueIndex].trim();
        });
        const parsed = parseRow(raw, index + 2);
        if (parsed.step <= lastStep) {
            throw new Error(
                `Scenario line ${parsed.lineNumber}: tx values must be strictly increasing`,
            );
        }
        lastStep = parsed.step;
        return parsed;
    });
}

export function loadScenario(filePath: string): ScenarioRow[] {
    return parseScenarioText(readFileSync(filePath, "utf8"));
}

export function validateCompleteScenario(rows: readonly ScenarioRow[]): void {
    if (rows.length !== EXPECTED_ACTION_SEQUENCE.length) {
        throw new Error(
            `scenario must contain exactly ${EXPECTED_ACTION_SEQUENCE.length} steps, got ${rows.length}`,
        );
    }
    rows.forEach((row, index) => {
        if (row.step !== index + 1) {
            throw new Error(`scenario step ${index + 1} must use tx ${index + 1}, got ${row.step}`);
        }
        if (row.action !== EXPECTED_ACTION_SEQUENCE[index]) {
            throw new Error(
                `scenario step ${index + 1} must be ${EXPECTED_ACTION_SEQUENCE[index]}, got ${row.action}`,
            );
        }
    });
}

export function readJson<T>(filePath: string): T {
    return JSON.parse(readFileSync(filePath, "utf8")) as T;
}
