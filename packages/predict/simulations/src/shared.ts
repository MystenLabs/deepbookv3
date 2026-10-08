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
    | "redeem_open"
    | "request_supply"
    | "request_withdraw"
    | "flush"
    | "rebalance_expiry_cash"
    | "settle"
    | "settle_payout";

export const REQUIRED_ACTIONS: ScenarioActionName[] = [
    "mint",
    "redeem_open",
    "request_supply",
    "request_withdraw",
    "flush",
    "rebalance_expiry_cash",
    "settle",
    "settle_payout",
];

// Every trade is queued (delayed execution). A mint or `redeem_open` row enqueues, then commits a
// locally signed Lazer price for the order's τ and resolves. Settlement runs `try_settle` phases:
// `settle` refunds waiting orders and settles, `settle_payout` pays the Open records, and the
// following `rebalance_expiry_cash` sweeps the settled market.
export const EXPECTED_ACTION_SEQUENCE: ScenarioActionName[] = [
    "mint",
    "mint",
    "redeem_open",
    "request_supply",
    "flush",
    "request_withdraw",
    "flush",
    "mint",
    "redeem_open",
    "rebalance_expiry_cash",
    "mint",
    "mint",
    "mint",
    "mint",
    "settle",
    "settle_payout",
    "rebalance_expiry_cash",
    "flush",
    "request_supply",
    "flush",
];

// What each mint row exercises, in scenario order: a fill at τ, a refund at τ on the order's own
// `max_probability` (the order fee is kept), or an order never committed, which settlement refunds
// at its deadline (the order fee is returned).
export type MintRole = "fill" | "limit_refund" | "deadline_refund";
export const EXPECTED_MINT_ROLES: MintRole[] = [
    "fill",
    "fill",
    "fill",
    "fill",
    "fill",
    "limit_refund",
    "deadline_refund",
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
              higherStrike?: bigint;
              quantity: bigint;
              // Entry-probability cap at τ; absent means uncapped.
              maxProbability?: bigint;
              orderRef: string;
              // The spot signed for the order's τ, or null for an order left uncommitted.
              commitSpot: bigint | null;
          })
    | (ScenarioRowBase & {
          action: "redeem_open";
          oracleRefresh: OracleRefreshData;
          orderRef: string;
          closeQuantity: bigint;
          replacementOrderRef: string | null;
          commitSpot: bigint;
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
    | (ScenarioRowBase & { action: "settle_payout" });

export type MintRow = Extract<ScenarioRow, { action: "mint" }>;
export type OracleRefreshRow = Extract<
    ScenarioRow,
    { action: "mint" | "redeem_open" | "flush" }
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
    poolValuationCapId: string;
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
    "higher_strike",
    "quantity",
    "max_probability",
    "order_ref",
    "close_quantity",
    "replacement_order_ref",
    "commit_spot",
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

function parseOptionalUnsignedInteger(
    row: RawScenarioRow,
    field: string,
    lineNumber: number,
): bigint | null {
    return (row[field] ?? "") === "" ? null : parseUnsignedInteger(row, field, lineNumber);
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
            higherStrike: row.higher_strike ? parseUnsignedInteger(row, "higher_strike", lineNumber) : undefined,
            quantity: parseQuantity(row, "quantity", lineNumber),
            maxProbability: parseOptionalUnsignedInteger(row, "max_probability", lineNumber) ?? undefined,
            orderRef: parseRef(row, "order_ref", lineNumber),
            commitSpot: parseOptionalUnsignedInteger(row, "commit_spot", lineNumber),
        };
    }
    if (action === "redeem_open") {
        return {
            action,
            lineNumber,
            step,
            oracleRefresh: parseOracleRefresh(row, lineNumber),
            orderRef: parseRef(row, "order_ref", lineNumber),
            closeQuantity: parseQuantity(row, "close_quantity", lineNumber),
            replacementOrderRef: parseOptionalString(row, "replacement_order_ref"),
            commitSpot: parseUnsignedInteger(row, "commit_spot", lineNumber),
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
    if (action === "settle_payout") return { action, lineNumber, step };
    throw new Error(`Scenario line ${lineNumber}: unsupported action "${action}"`);
}

export const ECONOMIC_SCHEMA_VERSION = "predict_economic_v6";
export const LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v6";
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
    const mintRoles = rows.filter((row): row is MintRow => row.action === "mint").map(mintRole);
    if (
        mintRoles.length !== EXPECTED_MINT_ROLES.length ||
        mintRoles.some((role, index) => role !== EXPECTED_MINT_ROLES[index])
    ) {
        throw new Error(`scenario mint roles must be ${EXPECTED_MINT_ROLES.join("/")}`);
    }
}

// A mint without a committed spot waits for its deadline refund. A committed mint with a
// `max_probability` cap is the probe the generator prices to miss that cap at τ.
export function mintRole(row: MintRow): MintRole {
    if (row.commitSpot === null) return "deadline_refund";
    return row.maxProbability === undefined ? "fill" : "limit_refund";
}

export function readJson<T>(filePath: string): T {
    return JSON.parse(readFileSync(filePath, "utf8")) as T;
}
