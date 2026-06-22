import { mkdirSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

export type ScenarioActionName = "oracle_mint_ptb" | "redeem" | "supply" | "withdraw";

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

export type ScenarioRow =
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
    | {
          action: "redeem";
          lineNumber: number;
          step: number;
          oracleRefresh: OracleRefreshData;
          orderRef: string;
          closeQuantity: bigint;
          replacementOrderRef: string | null;
      }
    | {
          action: "supply";
          lineNumber: number;
          step: number;
          oracleRefresh: OracleRefreshData;
          amount: bigint;
          lpRef: string;
      }
    | {
          action: "withdraw";
          lineNumber: number;
          step: number;
          oracleRefresh: OracleRefreshData;
          lpRef: string;
      };

export type MintRow = Extract<ScenarioRow, { action: "oracle_mint_ptb" }>;

export interface LocalTraceStep {
    step: number;
    // `flush` is the runner-synthesized privileged LP drain — not a CSV row action,
    // so it widens the trace action set without touching `ScenarioActionName`.
    action: ScenarioActionName | "flush";
    digest: string;
    wallMs: number;
    gas: GasLike;
    events: LocalTraceEvent[];
}

export interface LocalTraceEvent {
    type: string;
    full_type: string;
    parsedJson: unknown;
}

export interface GasLike {
    computationCost: number;
    storageCost: number;
    storageRebate: number;
    gasTotal: number;
}

export interface LocalTraceFile {
    schema_version: typeof LOCAL_TRACE_SCHEMA_VERSION;
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
    // Expiry timestamp chosen on-chain by the registry cadence manager and emitted
    // in MarketCreated. Stored as a decimal string so state.json stays plain JSON.
    expiryMs: string;
    // propbook feeds replace the in-package oracle + Pyth source. There is no
    // writer cap anymore (BS surface updates are permissionless via the verified
    // `Update`).
    pythFeedId: string;
    bsFeedId: string;
    // The sender's canonical derived account wrapper (replaces the predict manager).
    // Owner auth is minted per-call from the tx sender, so there are no capital caps.
    accountWrapperId: string;
    // Sole flush-start authority: the market-deployer MarketLifecycleCap, used to
    // mint a per-flush lifecycle proof for `plp::start_pool_valuation`.
    lifecycleCapId: string;
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
    "amount",
    "lp_ref",
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
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
const LEVERAGE_ONE_X = 1_000_000_000n;

function resolveInstanceDir(): string {
    const dir = process.env.INSTANCE_DIR;
    if (dir) return dir;
    return fileURLToPath(new URL("..", import.meta.url));
}

function isScenarioActionName(value: string): value is ScenarioActionName {
    return (
        value === "oracle_mint_ptb" ||
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
        throw new Error(
            `Scenario line ${lineNumber}: expected ${field} to be an unsigned integer, got "${value}"`,
        );
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
        b: parseUnsignedInteger(row, "b", lineNumber),
        rho: parseUnsignedInteger(row, "rho", lineNumber),
        rhoNegative: parseBoolean(row, "rho_negative", lineNumber),
        m: parseUnsignedInteger(row, "m", lineNumber),
        mNegative: parseBoolean(row, "m_negative", lineNumber),
        sigma: parseUnsignedInteger(row, "sigma", lineNumber),
        riskFreeRate: parseUnsignedInteger(row, "risk_free_rate", lineNumber),
    };
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
        throw new Error(
            `Scenario line ${lineNumber}: mint quantity must be at least one position lot`,
        );
    }
    if (quantity % POSITION_LOT_SIZE !== 0n) {
        throw new Error(
            `Scenario line ${lineNumber}: mint quantity must be a multiple of ${POSITION_LOT_SIZE}`,
        );
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
            leverage: parseOptionalUnsignedInteger(row, "leverage", lineNumber, LEVERAGE_ONE_X),
            orderRef: parseRef(row, "order_ref", lineNumber),
        };
    }

    if (action === "redeem") {
        return {
            action,
            lineNumber,
            step,
            oracleRefresh: parseOracleRefresh(row, lineNumber),
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
            oracleRefresh: parseOracleRefresh(row, lineNumber),
            amount: parseUnsignedInteger(row, "amount", lineNumber),
            lpRef: parseRef(row, "lp_ref", lineNumber),
        };
    }

    return {
        action,
        lineNumber,
        step,
        oracleRefresh: parseOracleRefresh(row, lineNumber),
        lpRef: parseRef(row, "lp_ref", lineNumber),
    };
}

const instanceDir = resolveInstanceDir();

export const ECONOMIC_SCHEMA_VERSION = "predict_economic_v2";
export const LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v2";
export const SCENARIO_PATH = fileURLToPath(
    new URL("../data/generated/normal_scenario.csv", import.meta.url),
);
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
            throw new Error(
                `Scenario line ${parsed.lineNumber}: tx values must be strictly increasing`,
            );
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

export function writeJson(filePath: string, value: unknown): void {
    ensureDir(path.dirname(filePath));
    writeFileSync(filePath, JSON.stringify(value, null, 2));
}
