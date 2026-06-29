import { bcs } from "@mysten/sui/bcs";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { deriveObjectID } from "@mysten/sui/utils";

import {
    ACCOUNT_PACKAGE_ID,
    ACCOUNT_REGISTRY_ID,
    ADMIN_CAP_ID,
    BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
    DUSDC_CURRENCY_ID,
    DUSDC_PACKAGE_ID,
    LOCAL_PYTH_GOVERNANCE_CHAIN,
    LOCAL_PYTH_GOVERNANCE_CONTRACT,
    LOCAL_PYTH_GUARDIAN_PRIVATE_KEY,
    LOCAL_PYTH_RECEIVER_CHAIN,
    LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS,
    LOCAL_PYTH_SIGNER_PRIVATE_KEY,
    LOCAL_PYTH_SIGNER_PUBLIC_KEY,
    ORACLE_REGISTRY_ADMIN_CAP_ID,
    ORACLE_REGISTRY_ID,
    PACKAGE_ID,
    POOL_VAULT_ID,
    PROPBOOK_PACKAGE_ID,
    PROTOCOL_CONFIG_ID,
    PYTH_LAZER_PACKAGE_ID,
    PYTH_LAZER_STATE_ID,
    REGISTRY_ID,
    RPC_URL,
    TREASURY_CAP_ID,
    WORMHOLE_PACKAGE_ID,
    WORMHOLE_STATE_ID,
    getSigner,
} from "./env.js";
import {
    type LocalPythConfig,
    lazerUpdateFromConfig,
    updateTrustedSignerVaaFromConfig,
} from "./localPyth.js";
import { FAILED_TRANSACTIONS_DIR, ensureDir, ts, writeJson } from "./artifacts.js";

export interface GasUsage {
    computationCost: number;
    storageCost: number;
    storageRebate: number;
    gasTotal: number;
}

export interface ExecutionReceipt {
    digest: string;
    gas: GasUsage;
    events: any[];
    objectChanges: any[];
    effects: any;
}

const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const CLOCK_ID = "0x6";
const COIN_REGISTRY_ID = "0xc";
// Sui's singleton balance-accumulator root lives at the reserved address 0xacc
// (object::SUI_ACCUMULATOR_ROOT_OBJECT_ID). The async-LP flush delivers PLP/DUSDC
// fills to an account's accumulator; every account capital op (mint/redeem settle,
// deposit, request_supply/withdraw) ambient-settles delivered funds through this root.
const ACCUMULATOR_ROOT_ID = "0xacc";
// Pyth Lazer feed id (the propbook spot feed key) and the Propbook underlying id.
// The harness binds one market to one Pyth feed and one split BS source set for
// that underlying, so a single source id serves both.
const PYTH_FEED_ID = 1;
const BS_UNDERLYING_ID = PYTH_FEED_ID;
// Strike range encoding (range_codec / constants.move): two u30 ticks packed
// `lower | (higher << TICK_BITS)`. `raw_strike = tick * tick_size`. Tick 0 is the
// neg-inf sentinel (lower side); `POS_INF_TICK` is the pos-inf sentinel (higher
// side). The harness tick size is $1 (1e9-scaled), mirroring the registered market
// tick size for this Propbook underlying.
const TICK_BITS = 30n;
const POS_INF_TICK = (1n << TICK_BITS) - 1n;
// $0.01 in 1e9 fixed-point — matches the testnet cadence tick_size (verified
// on-chain). raw_strike = tick * tick_size, so the tick index = raw_strike / this.
const ORACLE_TICK_SIZE = 10_000_000n;
const U64_MAX = (1n << 64n) - 1n;
const ONE_DAY_MS = 24n * 60n * 60n * 1000n;
const ONE_MONTH_MS = 30n * ONE_DAY_MS;
// Genesis minimum-liquidity lock (constants::min_bootstrap_liquidity). `lock_capital`
// permanently locks this much DUSDC so `total_supply > 0` for the life of the pool,
// making the supply==0 re-bootstrap branch unreachable. request_supply/withdraw abort
// `ENotBootstrapped` until it has run, so the harness locks it before any supply.
export const MIN_BOOTSTRAP_LIQUIDITY = 10_000_000n;
const SETUP_RESPONSE_OPTIONS = {
    showEffects: true,
    showEvents: true,
    showObjectChanges: true,
} as const;
const EXECUTION_RESPONSE_OPTIONS = {
    showEffects: true,
    showEvents: true,
    showObjectChanges: true,
} as const;

export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();
export { POOL_VAULT_ID, PROTOCOL_CONFIG_ID };

const DEFAULT_GAS_BUDGET = gasBudgetFromEnv();

function gasBudgetFromEnv(): bigint {
    const raw = process.env.SIM_GAS_BUDGET?.trim();
    if (!raw) return 1_000_000_000n;
    if (!/^[1-9][0-9]*$/.test(raw)) {
        throw new Error(`SIM_GAS_BUDGET must be a positive integer MIST value, got "${raw}"`);
    }
    return BigInt(raw);
}

function isSuccessStatus(status: any): boolean {
    return status?.status === "success" || status?.success === true;
}

function formatStatusError(status: any, fallback: string): string {
    return status?.error ?? fallback;
}

function failedTransactionAlreadyLogged(error: unknown): boolean {
    return error instanceof Error && (error as any).__failedTransactionLogged === true;
}

function markFailedTransactionLogged(error: Error): Error {
    (error as any).__failedTransactionLogged = true;
    return error;
}

let failedTransactionArtifactSequence = 1;

function safeArtifactValue(value: unknown, seen = new WeakSet<object>(), depth = 0): unknown {
    if (depth > 40) return "[MaxDepth]";
    if (value === null) return null;
    if (value === undefined) return "[Undefined]";
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "number" || typeof value === "string" || typeof value === "boolean") {
        return value;
    }
    if (typeof value === "symbol") return String(value);
    if (typeof value === "function") return `[Function ${(value as Function).name || "anonymous"}]`;
    if (value instanceof Uint8Array) {
        return {
            type: "Uint8Array",
            length: value.length,
            base64: Buffer.from(value).toString("base64"),
        };
    }
    if (value instanceof Error) {
        return {
            name: value.name,
            message: value.message,
            stack: value.stack,
            cause: safeArtifactValue((value as any).cause, seen, depth + 1),
        };
    }
    if (Array.isArray(value)) {
        return value.map((item) => safeArtifactValue(item, seen, depth + 1));
    }
    if (typeof value === "object") {
        if (seen.has(value)) return "[Circular]";
        seen.add(value);
        const out: Record<string, unknown> = {};
        for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
            out[key] = safeArtifactValue(entry, seen, depth + 1);
        }
        seen.delete(value);
        return out;
    }
    return String(value);
}

function failedTransactionArtifactPath(label: string, attempt: number): string {
    const safeLabel = label.replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 96) || "transaction";
    const suffix = `${Date.now()}-${process.pid}-${failedTransactionArtifactSequence++}`;
    return `${FAILED_TRANSACTIONS_DIR}/${safeLabel}-attempt-${attempt + 1}-${suffix}.json`;
}

async function collectTransactionDebug(params: {
    tx?: Transaction | null;
    label: string;
    attempt: number;
    gasBudget: bigint;
    phase:
        | "rpc_error"
        | "retryable_rpc_error"
        | "execution_failure"
        | "post_submit_fetch_error";
    raw?: unknown;
    error?: unknown;
}): Promise<string> {
    const rawAny = params.raw as any;
    const digest =
        rawAny?.digest ??
        rawAny?.effects?.transactionDigest ??
        rawAny?.effects?.transaction_digest ??
        null;
    const artifact: Record<string, unknown> = {
        schema_version: "predict_failed_transaction_v1",
        timestamp: new Date().toISOString(),
        label: params.label,
        phase: params.phase,
        attempt: params.attempt + 1,
        sender: address,
        rpc_url: RPC_URL,
        gas_budget: params.gasBudget.toString(),
        digest,
        status: rawAny?.effects?.status ?? null,
        gas_used: rawAny?.effects?.gasUsed ?? null,
        error: safeArtifactValue(params.error),
        raw_response: safeArtifactValue(params.raw),
    };

    if (params.tx) {
        try {
            const bytes = await params.tx.build({ client });
            artifact.transaction_bytes = {
                length: bytes.length,
                base64: Buffer.from(bytes).toString("base64"),
            };
            try {
                artifact.dry_run = safeArtifactValue(
                    await client.dryRunTransactionBlock({ transactionBlock: bytes }),
                );
            } catch (dryRunError) {
                artifact.dry_run_error = safeArtifactValue(dryRunError);
            }
        } catch (buildError) {
            artifact.transaction_build_error = safeArtifactValue(buildError);
        }
    } else {
        artifact.transaction_unavailable = "transaction builder failed before producing a PTB";
    }

    if (digest !== null) {
        try {
            artifact.transaction_block = safeArtifactValue(
                await client.getTransactionBlock({
                    digest,
                    options: {
                        showInput: true,
                        showEffects: true,
                        showEvents: true,
                        showObjectChanges: true,
                        showBalanceChanges: true,
                    },
                }),
            );
        } catch (fetchError) {
            artifact.transaction_block_fetch_error = safeArtifactValue(fetchError);
        }
    }

    ensureDir(FAILED_TRANSACTIONS_DIR);
    const path = failedTransactionArtifactPath(params.label, params.attempt);
    writeJson(path, artifact);
    process.stderr.write(`[${ts()}]   Failed transaction artifact: ${path}\n`);
    return path;
}

async function tryCollectTransactionDebug(params: Parameters<typeof collectTransactionDebug>[0]) {
    try {
        return await collectTransactionDebug(params);
    } catch (error) {
        process.stderr.write(
            `[${ts()}]   Failed transaction artifact logging failed: ${String(error)}\n`,
        );
        return null;
    }
}

function failedTransactionSuffix(artifactPath: string | null): string {
    return artifactPath === null ? " failed_tx_artifact=<logging_failed>" : ` failed_tx=${artifactPath}`;
}

function gasSummaryFromEffects(effects: any): GasUsage {
    const gasUsed = effects?.gasUsed ?? {};
    const computationCost = Number(gasUsed.computationCost ?? 0);
    const storageCost = Number(gasUsed.storageCost ?? 0);
    const storageRebate = Number(gasUsed.storageRebate ?? 0);

    return {
        computationCost,
        storageCost,
        storageRebate,
        gasTotal: computationCost + storageCost - storageRebate,
    };
}

async function getTransactionBlockWithRetry(digest: string): Promise<any> {
    let lastError: unknown;

    for (let attempt = 0; attempt < 20; attempt++) {
        try {
            return await client.getTransactionBlock({
                digest,
                options: { showEvents: true, showObjectChanges: true, showEffects: true },
            });
        } catch (error) {
            lastError = error;
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
    }

    throw lastError;
}

export function target(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PACKAGE_ID}::${module}::${fn}`;
}

// The `account` package owns the deterministic account wrapper that replaced the
// predict manager. Its ids differ from the predict package id.
function accountTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${ACCOUNT_PACKAGE_ID}::${module}::${fn}`;
}

// Owner authority is a hot potato minted from the tx sender (`ctx` is implicit in a
// PTB) and consumed by the very next account-loading call (`load_account_mut` inside
// `deposit_funds` / `mint` / `redeem` / `request_supply` / `request_withdraw`). The
// harness signer owns every account it creates, so this always resolves to owner auth.
function generateAuth(tx: Transaction) {
    return tx.moveCall({ target: accountTarget("account", "generate_auth"), arguments: [] });
}

// Note: `predict_math` was renamed to `fixed_math`, but the harness no longer makes
// any direct fixed_math/i64 Move call — the old oracle path built SVI `i64`s via
// `i64::from_parts`; the propbook BS updates now take magnitude+sign primitives
// directly (`block_scholes_oracle::update::new_svi_update`). So there is no
// `fixedMathTarget` helper. The rename still matters for the localnet publish flow
// and the named-address dependency (see run.sh).

// propbook owns the extracted Pyth spot and split Block Scholes feeds.
function propbookTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PROPBOOK_PACKAGE_ID}::${module}::${fn}`;
}

// `block_scholes_oracle` is the STUB BS signed-data verifier that mints the
// verified split updates consumed by the Block Scholes Propbook feeds.
function bsOracleTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${BLOCK_SCHOLES_ORACLE_PACKAGE_ID}::${module}::${fn}`;
}

function pythLazerTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PYTH_LAZER_PACKAGE_ID}::${module}::${fn}`;
}

function wormholeTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${WORMHOLE_PACKAGE_ID}::${module}::${fn}`;
}

function localPythConfig(): LocalPythConfig {
    return {
        governanceChain: LOCAL_PYTH_GOVERNANCE_CHAIN,
        governanceContract: LOCAL_PYTH_GOVERNANCE_CONTRACT,
        receiverChain: LOCAL_PYTH_RECEIVER_CHAIN,
        guardianPrivateKey: LOCAL_PYTH_GUARDIAN_PRIVATE_KEY,
        signerPrivateKey: LOCAL_PYTH_SIGNER_PRIVATE_KEY,
        signerPublicKey: LOCAL_PYTH_SIGNER_PUBLIC_KEY,
        signerExpiresAtSeconds: LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS,
    };
}

let lastSourceTimestampMs = 0n;

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function clockTimestampMs(): Promise<bigint> {
    const object = await client.getObject({
        id: CLOCK_ID,
        options: { showContent: true },
    });
    const timestamp = (object.data?.content as any)?.fields?.timestamp_ms;
    if (timestamp === undefined) {
        throw new Error("unable to read localnet Clock timestamp");
    }
    return BigInt(timestamp);
}

async function nextSourceTimestampMs(): Promise<bigint> {
    for (let attempt = 0; attempt < 50; attempt++) {
        const latestAllowed = (await clockTimestampMs()) - 1n;
        if (latestAllowed > lastSourceTimestampMs) {
            lastSourceTimestampMs = latestAllowed;
            return latestAllowed;
        }
        await sleep(25);
    }

    throw new Error("localnet Clock did not advance enough for a fresh source timestamp");
}

export async function nextOneMonthExpiryMs(): Promise<bigint> {
    const now = await clockTimestampMs();
    return ((now / ONE_MONTH_MS) + 1n) * ONE_MONTH_MS;
}

interface BlockScholesSurfaceFeedIds {
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
}

// One oracle refresh now writes all propbook feeds: a permissionless Pyth Lazer
// spot update plus independent BS spot, forward, and SVI updates for the market's
// expiry. There is no in-package oracle and no writer cap anymore.
interface OracleRefreshParams {
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
    expiry: bigint;
    spot: bigint;
    forward: bigint;
    svi: {
        a: bigint;
        b: bigint;
        rho: bigint;
        rhoNegative: boolean;
        m: bigint;
        mNegative: boolean;
        sigma: bigint;
    };
}

interface MintParams {
    expiryMarketId: string;
    protocolConfigId: string;
    wrapperId: string;
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
    strike: bigint;
    isUp: boolean;
    quantity: bigint;
    leverage: bigint;
}

interface RedeemParams {
    expiryMarketId: string;
    protocolConfigId: string;
    wrapperId: string;
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
    orderId: string;
    closeQuantity: bigint;
}

interface LivePricerParams {
    expiryMarketId: string;
    protocolConfigId: string;
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
}

// Inputs to drive one privileged full-pool flush (the async LP drain).
export interface FlushParams {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
    lifecycleCapId: string;
}

// Convert a raw binary-range strike to the `(lower_tick, higher_tick)` pair the
// `mint` entrypoint now takes directly (there is no standalone packed range key).
// An UP order is `(strike, +inf)` -> lower_tick = strike/tick_size, higher_tick =
// POS_INF_TICK; a DOWN order is `(-inf, strike)` -> lower_tick = 0 (neg-inf),
// higher_tick = strike/tick_size.
function binaryRangeTicks(
    strike: bigint,
    isUp: boolean,
): { lowerTick: bigint; higherTick: bigint } {
    const tick = strike / ORACLE_TICK_SIZE;
    if (tick * ORACLE_TICK_SIZE !== strike) {
        throw new Error(`strike ${strike} is not a whole tick multiple of ${ORACLE_TICK_SIZE}`);
    }
    if (tick <= 0n || tick >= POS_INF_TICK) {
        throw new Error(`strike tick ${tick} outside the finite tick domain (1..POS_INF_TICK-1)`);
    }
    return {
        lowerTick: isUp ? tick : 0n,
        higherTick: isUp ? POS_INF_TICK : tick,
    };
}

async function addOracleRefresh(tx: Transaction, params: OracleRefreshParams): Promise<void> {
    const sourceTimestampMs = await nextSourceTimestampMs();
    addPythFeedUpdate(tx, params.pythFeedId, params.spot, sourceTimestampMs);
    addBlockScholesUpdates(tx, params, sourceTimestampMs);
}

// Live-data updater: clamp a provider's real publish timestamp to a valid on-chain
// source timestamp — `<= Clock - 1` and strictly monotonic — so the oracle history
// mirrors real wall-clock without ever tripping the freshness gate. Returns null
// when the timestamp is not fresh (the loop should skip this tick, not wait).
export async function clampedSourceTimestampMs(realMs: bigint): Promise<bigint | null> {
    const clockMax = (await clockTimestampMs()) - 1n;
    const ts = realMs < clockMax ? realMs : clockMax;
    if (ts <= lastSourceTimestampMs) return null;
    lastSourceTimestampMs = ts;
    return ts;
}

// Build one combined oracle refresh (re-signed Pyth spot + BS spot/forward/SVI for
// one expiry) at a caller-provided source timestamp. Same calls as addOracleRefresh
// but stamps real (clamped) provider time instead of deriving it from the Clock.
export function buildOracleRefreshTx(params: OracleRefreshParams, sourceTimestampMs: bigint): Transaction {
    const tx = new Transaction();
    addPythFeedUpdate(tx, params.pythFeedId, params.spot, sourceTimestampMs);
    addBlockScholesUpdates(tx, params, sourceTimestampMs);
    return tx;
}

// Build ONE refresh PTB covering a grid of expiries: re-signed Pyth spot + BS spot
// once, then forward/SVI for each expiry. Pre-warms the whole boundary grid in a
// single transaction at one (clamped) source timestamp.
export interface GridExpiry {
    expiry: bigint;
    forward: bigint;
    svi: OracleRefreshParams["svi"];
}

export function buildOracleRefreshGridTx(
    feeds: { pythFeedId: string; bsSpotFeedId: string; bsForwardFeedId: string; bsSviFeedId: string },
    spot: bigint,
    grid: GridExpiry[],
    sourceTimestampMs: bigint,
): Transaction {
    const tx = new Transaction();
    addPythFeedUpdate(tx, feeds.pythFeedId, spot, sourceTimestampMs);
    addBsSpotUpdate(tx, feeds.bsSpotFeedId, spot, sourceTimestampMs);
    for (const g of grid) {
        addBsExpiryUpdate(tx, feeds.bsForwardFeedId, feeds.bsSviFeedId, g.expiry, g.forward, g.svi, sourceTimestampMs);
    }
    return tx;
}

// Permissionless Pyth Lazer spot update: parse+verify the signed Lazer payload,
// then store it through the propbook PythFeed (no protocol config, no cap).
function addPythFeedUpdate(
    tx: Transaction,
    pythFeedId: string,
    spot: bigint,
    sourceTimestampMs: bigint,
): void {
    const updateBytes = lazerUpdateFromConfig(
        localPythConfig(),
        PYTH_FEED_ID,
        spot,
        sourceTimestampMs,
    );
    const update = tx.moveCall({
        target: pythLazerTarget("pyth_lazer", "parse_and_verify_le_ecdsa_update"),
        arguments: [
            tx.object(PYTH_LAZER_STATE_ID),
            tx.object(CLOCK_ID),
            tx.pure.vector("u8", Array.from(updateBytes)),
        ],
    });
    tx.moveCall({
        target: propbookTarget("pyth_feed", "update"),
        arguments: [tx.object(pythFeedId), update, tx.object(CLOCK_ID)],
    });
}

// Block Scholes updates for one expiry: build the STUB verified split updates,
// then ingest them into the independent Propbook BS spot, forward, and SVI feeds.
function addBsSpotUpdate(
    tx: Transaction,
    bsSpotFeedId: string,
    spot: bigint,
    publishedAtMs: bigint,
): void {
    const spotUpdate = tx.moveCall({
        target: bsOracleTarget("update", "new_spot_update"),
        arguments: [tx.pure.u32(BS_UNDERLYING_ID), tx.pure.u64(publishedAtMs), tx.pure.u64(spot)],
    });
    tx.moveCall({
        target: propbookTarget("block_scholes_spot_feed", "update"),
        arguments: [tx.object(bsSpotFeedId), spotUpdate, tx.object(CLOCK_ID)],
    });
}

// One expiry's forward + SVI surface (the per-expiry part of a BS refresh).
function addBsExpiryUpdate(
    tx: Transaction,
    bsForwardFeedId: string,
    bsSviFeedId: string,
    expiry: bigint,
    forward: bigint,
    svi: OracleRefreshParams["svi"],
    publishedAtMs: bigint,
): void {
    const forwardUpdate = tx.moveCall({
        target: bsOracleTarget("update", "new_forward_update"),
        arguments: [
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u64(expiry),
            tx.pure.u64(publishedAtMs),
            tx.pure.u64(forward),
        ],
    });
    tx.moveCall({
        target: propbookTarget("block_scholes_forward_feed", "update"),
        arguments: [tx.object(bsForwardFeedId), forwardUpdate, tx.object(CLOCK_ID)],
    });

    const sviUpdate = tx.moveCall({
        target: bsOracleTarget("update", "new_svi_update"),
        arguments: [
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u64(expiry),
            tx.pure.u64(publishedAtMs),
            tx.pure.u64(svi.a),
            tx.pure.u64(svi.b),
            tx.pure.u64(svi.sigma),
            tx.pure.u64(svi.rho),
            tx.pure.bool(svi.rhoNegative),
            tx.pure.u64(svi.m),
            tx.pure.bool(svi.mNegative),
        ],
    });
    tx.moveCall({
        target: propbookTarget("block_scholes_svi_feed", "update"),
        arguments: [tx.object(bsSviFeedId), sviUpdate, tx.object(CLOCK_ID)],
    });
}

function addBlockScholesUpdates(
    tx: Transaction,
    params: OracleRefreshParams,
    publishedAtMs: bigint,
): void {
    addBsSpotUpdate(tx, params.bsSpotFeedId, params.spot, publishedAtMs);
    addBsExpiryUpdate(
        tx,
        params.bsForwardFeedId,
        params.bsSviFeedId,
        params.expiry,
        params.forward,
        params.svi,
        publishedAtMs,
    );
}

function mintDusdc(tx: Transaction, amount: bigint) {
    const [coin] = tx.moveCall({
        target: "0x2::coin::mint",
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
    });
    return coin;
}

function loadLivePricer(tx: Transaction, params: LivePricerParams) {
    return tx.moveCall({
        target: target("expiry_market", "load_live_pricer"),
        arguments: [
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsSpotFeedId),
            tx.object(params.bsForwardFeedId),
            tx.object(params.bsSviFeedId),
            tx.object(CLOCK_ID),
        ],
    });
}

// Run one full-pool flush over the single active market in the same PTB: the
// privileged `start_pool_valuation` (started via a market-deployer `MarketLifecycleCap`
// proof — the sole flush authority) -> one `value_expiry` for our market ->
// `finish_flush`, which drains the supply/withdraw request queues at the frozen mark.
// The two `finish_flush` budgets are `None` (drain both queues fully). The harness has
// exactly one expiry market, so the snapshot covers one `value_expiry`. (Multi-market
// topologies must call `value_expiry` once per active market between start and finish.)
function addFlush(tx: Transaction, params: FlushParams): void {
    const proof = tx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [tx.object(REGISTRY_ID), tx.object(params.lifecycleCapId)],
    });
    const valuation = tx.moveCall({
        target: target("plp", "start_pool_valuation"),
        arguments: [tx.object(params.protocolConfigId), tx.object(params.poolVaultId), proof],
    });
    tx.moveCall({
        target: target("plp", "value_expiry"),
        arguments: [
            valuation,
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsSpotFeedId),
            tx.object(params.bsForwardFeedId),
            tx.object(params.bsSviFeedId),
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: target("plp", "finish_flush"),
        arguments: [
            valuation,
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // supply_budget: None (drain fully)
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // withdraw_budget: None (drain fully)
        ],
    });
}

function addMint(tx: Transaction, params: MintParams): void {
    const { lowerTick, higherTick } = binaryRangeTicks(params.strike, params.isUp);
    const pricer = loadLivePricer(tx, params);
    const auth = generateAuth(tx);
    tx.moveCall({
        target: target("expiry_market", "mint_exact_quantity"),
        arguments: [
            tx.object(params.expiryMarketId),
            tx.object(params.wrapperId),
            auth,
            tx.object(params.protocolConfigId),
            pricer,
            tx.pure.u64(lowerTick),
            tx.pure.u64(higherTick),
            tx.pure.u64(params.quantity),
            tx.pure.u64(params.leverage),
            tx.pure.u64(U64_MAX),
            tx.pure.u64(U64_MAX),
            // `mint_exact_quantity` loads the account and ambient-settles it
            // (`settle<DUSDC>`) before charging the premium, so it reads the
            // singleton AccumulatorRoot at 0xacc. `root` follows the slippage
            // guards.
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
}

function addRedeem(tx: Transaction, params: RedeemParams): void {
    // The sim always acts as the account owner, so it uses the owner-authorized
    // `redeem_live` (auth consumed). The benchmark harness does not drive the
    // permissionless settled redeem path.
    const pricer = loadLivePricer(tx, params);
    const auth = generateAuth(tx);
    tx.moveCall({
        target: target("expiry_market", "redeem_live"),
        arguments: [
            tx.object(params.expiryMarketId),
            tx.object(params.wrapperId),
            auth,
            tx.object(params.protocolConfigId),
            pricer,
            tx.pure.u256(BigInt(params.orderId)),
            tx.pure.u64(params.closeQuantity),
            // `min_probability` then `min_proceeds` close-side slippage floors; the
            // benchmark never sets a floor, so pass 0 to disable both (mirrors mint's
            // U64_MAX caps).
            tx.pure.u64(0),
            tx.pure.u64(0),
            // `redeem_live` loads the account and ambient-settles it (`settle<DUSDC>`)
            // before crediting the payout, so it reads the singleton AccumulatorRoot at 0xacc.
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
}

export function finalizeDusdcCurrencyRegistrationTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: "0x2::coin_registry::finalize_registration",
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(COIN_REGISTRY_ID), tx.object(DUSDC_CURRENCY_ID)],
    });
    return tx;
}

export function mintLifecycleCapTx(recipient: string): Transaction {
    const tx = new Transaction();
    // MarketLifecycleCap mint moved from `plp` to `registry` (the allowlist now
    // lives on Registry, its sole gating call site being create_expiry_market).
    const cap = tx.moveCall({
        target: target("registry", "mint_lifecycle_cap"),
        // `mint_lifecycle_cap(registry, config, admin_cap, ctx)` — the mint is version-
        // gated, so it reads the protocol config.
        arguments: [tx.object(REGISTRY_ID), tx.object(PROTOCOL_CONFIG_ID), tx.object(ADMIN_CAP_ID)],
    });
    tx.transferObjects([cap], tx.pure.address(recipient));
    return tx;
}

// Admin-approve one Propbook underlying for Predict and permissionlessly create
// the permanent Pyth spot feed plus the permanent BS spot feed. The permanent BS
// forward/SVI surface feeds are created after this transaction so their IDs can be
// captured from object changes.
export function registerUnderlyingAndCreateFeedsTx(feedId: number): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "register_underlying"),
        // `register_underlying(registry, config, admin_cap, underlying_id)`.
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(PROTOCOL_CONFIG_ID),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_pyth_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(feedId)],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_block_scholes_spot_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(BS_UNDERLYING_ID)],
    });
    return tx;
}

export function createBlockScholesSurfaceFeedsTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_block_scholes_forward_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(BS_UNDERLYING_ID)],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_block_scholes_svi_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(BS_UNDERLYING_ID)],
    });
    return tx;
}

// Enable one registry-owned market cadence. Tick size, allocation cap, and
// initial expiry cash target are snapshotted into future markets created from
// this cadence.
export function setCadenceConfigTx(params: {
    cadenceId: number;
    tickSize: bigint;
    admissionTickSize: bigint;
    maxExpiryAllocation: bigint;
    initialExpiryCash: bigint;
    windowSize: bigint;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "set_cadence_config"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(PROTOCOL_CONFIG_ID),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u8(params.cadenceId),
            tx.pure.u64(params.tickSize),
            tx.pure.u64(params.admissionTickSize),
            tx.pure.u64(params.maxExpiryAllocation),
            tx.pure.u64(params.initialExpiryCash),
            tx.pure.u64(params.windowSize),
        ],
    });
    return tx;
}

// Admin-bind the Pyth spot feed and BS spot feed to one canonical Propbook
// underlying. Must run after the feeds are shared. The permanent BS forward/SVI
// surface is bound separately before market creation.
export function bindFeedsToUnderlyingTx(params: {
    pythFeedId: string;
    bsSpotFeedId: string;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: propbookTarget("registry", "bind_pyth_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.pythFeedId),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    tx.moveCall({
        target: propbookTarget("registry", "bind_block_scholes_spot_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.bsSpotFeedId),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    return tx;
}

export function bindBlockScholesSurfaceToUnderlyingTx(
    params: Pick<BlockScholesSurfaceFeedIds, "bsForwardFeedId" | "bsSviFeedId">,
): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: propbookTarget("registry", "bind_block_scholes_surface_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.bsForwardFeedId),
            tx.object(params.bsSviFeedId),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    return tx;
}

export function setTemplateExpiryFeeConfigTx(
    protocolConfigId: string,
    expiryFeeWindowMs: bigint,
    expiryFeeMaxMultiplier: bigint,
): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("protocol_config", "set_template_expiry_fee_window_ms"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(expiryFeeWindowMs),
        ],
    });
    tx.moveCall({
        target: target("protocol_config", "set_template_expiry_fee_max_multiplier"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(expiryFeeMaxMultiplier),
        ],
    });
    return tx;
}

export function setTemplateMaxAdmissionLeverageTx(
    protocolConfigId: string,
    maxAdmissionLeverage: bigint,
): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("protocol_config", "set_template_max_admission_leverage"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(maxAdmissionLeverage),
        ],
    });
    return tx;
}

// Pin oracle read freshness to the testnet values. Testnet loosened pyth/bs price
// freshness from the contract defaults (2s/3s) to 10s so realistic push cadence does
// not stale-reject reads; the localnet must match or live pricing aborts under load.
export function setOracleFreshnessTx(
    protocolConfigId: string,
    pythSpotMs: bigint,
    blockScholesPriceMs: bigint,
    blockScholesSviMs: bigint,
): Transaction {
    const tx = new Transaction();
    const set = (fn: string, value: bigint) =>
        tx.moveCall({
            target: target("protocol_config", fn),
            arguments: [tx.object(protocolConfigId), tx.object(ADMIN_CAP_ID), tx.pure.u64(value)],
        });
    set("set_pyth_spot_freshness_ms", pythSpotMs);
    set("set_block_scholes_price_freshness_ms", blockScholesPriceMs);
    set("set_block_scholes_svi_freshness_ms", blockScholesSviMs);
    return tx;
}

export function updatePythTrustedSignerTx(): Transaction {
    const tx = new Transaction();
    const vaaBytes = updateTrustedSignerVaaFromConfig(localPythConfig());
    const vaa = tx.moveCall({
        target: wormholeTarget("vaa", "parse_and_verify"),
        arguments: [
            tx.object(WORMHOLE_STATE_ID),
            tx.pure.vector("u8", Array.from(vaaBytes)),
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: pythLazerTarget("actions", "update_trusted_signer"),
        arguments: [tx.object(PYTH_LAZER_STATE_ID), vaa],
    });
    return tx;
}

// Seed the split Block Scholes feeds (and Pyth spot) for the market's expiry. Market
// creation itself reads NO spot now (absolute ticks need no grid centering), but a
// fresh BS price/SVI source set must exist before the first mint and before any
// flush valuation can price `current_nav`. The permanent forward/SVI feeds must
// already be created and bound before market creation, but seeding the per-expiry
// feed rows happens after the market is created.
export async function seedOracleTx(params: {
    pythFeedId: string;
    bsSpotFeedId: string;
    bsForwardFeedId: string;
    bsSviFeedId: string;
    expiry: bigint;
    spot: bigint;
    forward: bigint;
    svi: OracleRefreshParams["svi"];
}): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    return tx;
}

// Create the expiry market for one Propbook underlying. No spot is read at
// creation. The registry validates, against propbook's canonical binding, that
// Pyth + Block Scholes feeds are bound to `BS_UNDERLYING_ID` (run
// `bindFeedsToUnderlyingTx` first). `create_expiry_market` returns one ID and
// registers the market with the vault as a zero-cash accounting row (not mintable
// until `rebalance_expiry_cash` funds it).
export function createExpiryMarketTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    lifecycleCapId: string;
    cadenceId: number;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "create_expiry_market"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.lifecycleCapId),
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u8(params.cadenceId),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Fund / rebalance one expiry's cash from pool idle toward target. Standalone and
// permissionless; this is what makes a freshly created market mintable. Replaces
// the old setup-only PLP sync.
export function rebalanceExpiryCashTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    pythFeedId: string;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("plp", "rebalance_expiry_cash"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Queue a supply request: `request_supply` pulls `amount` DUSDC from the account's
// custody into queue escrow, recording the account as the fill recipient. To keep
// supply a fresh external-capital injection (matching the old escrow-a-fresh-coin
// model), deposit `amount` fresh DUSDC into the account first (separate owner auth),
// then request_supply pulls exactly that. The minted PLP is delivered to the account
// (via the balance accumulator) at the next flush, NOT returned here.
export function requestSupplyTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    wrapperId: string;
    amount: bigint;
}): Transaction {
    const tx = new Transaction();
    const dusdc = mintDusdc(tx, params.amount);
    const depositAuth = generateAuth(tx);
    tx.moveCall({
        target: accountTarget("account", "deposit_funds"),
        typeArguments: [DUSDC_TYPE],
        arguments: [
            tx.object(params.wrapperId),
            depositAuth,
            dusdc,
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    const supplyAuth = generateAuth(tx);
    tx.moveCall({
        target: target("plp", "request_supply"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.wrapperId),
            supplyAuth,
            tx.object(params.protocolConfigId),
            tx.pure.u64(params.amount),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Queue a withdraw request: `request_withdraw` pulls `shares` PLP from the account's
// custody into queue escrow. The pull auto-settles any flush-delivered PLP first (the
// async flush delivers PLP fills to the account's accumulator), so no separate
// materialization step exists — there is no `withdraw_settled` entrypoint. The DUSDC
// fill is delivered to the account at the next flush, NOT returned here.
export function requestWithdrawTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    wrapperId: string;
    shares: bigint;
}): Transaction {
    const tx = new Transaction();
    const auth = generateAuth(tx);
    tx.moveCall({
        target: target("plp", "request_withdraw"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.wrapperId),
            auth,
            tx.object(params.protocolConfigId),
            tx.pure.u64(params.shares),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Refresh the oracle, then run one privileged full-pool flush that drains both LP
// request queues at the frozen mark. The drain happens inside `finish_flush`; no
// per-LP coin is returned (fills land on the manager via the accumulator).
export async function refreshOracleAndFlushTx(
    params: OracleRefreshParams & FlushParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addFlush(tx, params);
    return tx;
}

// Create the sender's canonical derived account wrapper and share it. `new` derives
// the wrapper at a deterministic address (see `deriveAccountWrapperId`); `share`
// publishes the shared object the trade flows borrow against.
export function createAccountTx(): Transaction {
    const tx = new Transaction();
    const wrapper = tx.moveCall({
        target: accountTarget("account_registry", "new"),
        arguments: [tx.object(ACCOUNT_REGISTRY_ID)],
    });
    tx.moveCall({
        target: accountTarget("account", "share"),
        arguments: [wrapper],
    });
    return tx;
}

// Deposit `amount` fresh DUSDC into the account's stored balance via the PTB-callable
// `deposit_funds` (folds owner authorize -> load -> deposit). Ambient-settles delivered
// DUSDC (reads the AccumulatorRoot) before crediting.
export function depositToAccountTx(wrapperId: string, amount: bigint): Transaction {
    const tx = new Transaction();
    const coin = mintDusdc(tx, amount);
    const auth = generateAuth(tx);
    tx.moveCall({
        target: accountTarget("account", "deposit_funds"),
        typeArguments: [DUSDC_TYPE],
        arguments: [
            tx.object(wrapperId),
            auth,
            coin,
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// === Derived object IDs ===

// `AccountWrapperKey(address)` — a one-field positional struct, so its BCS is just the
// owner's 32-byte address. The wrapper is a derived object of the account registry, so
// its id is `derive_address(ACCOUNT_REGISTRY_ID, AccountWrapperKey(owner))`.
const AccountWrapperKeyBcs = bcs.struct("AccountWrapperKey", {
    pos0: bcs.Address,
});

export function deriveAccountWrapperId(owner: string): string {
    const key = AccountWrapperKeyBcs.serialize({ pos0: owner }).toBytes();
    return deriveObjectID(
        ACCOUNT_REGISTRY_ID,
        `${ACCOUNT_PACKAGE_ID}::account_registry::AccountWrapperKey`,
        key,
    );
}

// Genesis bootstrap: permanently lock `MIN_BOOTSTRAP_LIQUIDITY` DUSDC so the pool's
// `total_supply > 0` and the supply==0 re-bootstrap branch is unreachable. Locked
// liquidity mints PLP into the book's locked balance (no shares to the caller) and
// joins the DUSDC into idle. Must run once, before any request_supply.
export function lockCapitalTx(poolVaultId: string): Transaction {
    const tx = new Transaction();
    const coin = mintDusdc(tx, MIN_BOOTSTRAP_LIQUIDITY);
    tx.moveCall({
        target: target("plp", "lock_capital"),
        // `lock_capital(vault, config, admin_cap, payment)`.
        arguments: [tx.object(poolVaultId), tx.object(PROTOCOL_CONFIG_ID), tx.object(ADMIN_CAP_ID), coin],
    });
    return tx;
}

export async function refreshOracleAndMintTx(
    params: OracleRefreshParams & MintParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addMint(tx, params);
    return tx;
}

export async function refreshOracleAndMintBatchTx(
    params: OracleRefreshParams & { mints: MintParams[] },
): Promise<Transaction> {
    if (params.mints.length === 0) {
        throw new Error("refreshOracleAndMintBatchTx requires at least one mint");
    }

    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    for (const mint of params.mints) {
        addMint(tx, mint);
    }
    return tx;
}

export async function refreshOracleAndRedeemTx(
    params: OracleRefreshParams & RedeemParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addRedeem(tx, params);
    return tx;
}

export async function executeAndWait(
    tx: Transaction,
    label = "transaction",
    gasBudget = DEFAULT_GAS_BUDGET,
): Promise<any> {
    tx.setSender(address);
    tx.setGasBudget(gasBudget);

    let execution: any;
    try {
        execution = await client.signAndExecuteTransaction({
            transaction: tx,
            signer,
            options: SETUP_RESPONSE_OPTIONS,
        });
    } catch (error) {
        const artifactPath = await tryCollectTransactionDebug({
            tx,
            label,
            attempt: 0,
            gasBudget,
            phase: "rpc_error",
            error,
        });
        throw markFailedTransactionLogged(
            new Error(`${label} rpc failure: ${String(error)}${failedTransactionSuffix(artifactPath)}`),
        );
    }

    const status = (execution as any).effects?.status;
    if (!isSuccessStatus(status)) {
        const artifactPath = await tryCollectTransactionDebug({
            tx,
            label,
            attempt: 0,
            gasBudget,
            phase: "execution_failure",
            raw: execution,
        });
        throw markFailedTransactionLogged(
            new Error(
                `${label} failed: ${formatStatusError(status, JSON.stringify(execution).slice(0, 300))}${failedTransactionSuffix(artifactPath)}`,
            ),
        );
    }

    try {
        return await getTransactionBlockWithRetry(execution.digest);
    } catch (error) {
        const artifactPath = await tryCollectTransactionDebug({
            tx,
            label,
            attempt: 0,
            gasBudget,
            phase: "post_submit_fetch_error",
            raw: execution,
            error,
        });
        throw markFailedTransactionLogged(
            new Error(
                `${label} post-submit fetch failure digest=${execution.digest}: ${String(error)}${failedTransactionSuffix(artifactPath)}`,
            ),
        );
    }
}

const EXECUTE_MAX_ATTEMPTS = 5;
const EXECUTE_RETRY_DELAY_MS = 1000;

export async function execute(
    buildTx: Transaction | (() => Transaction | Promise<Transaction>),
    label = "transaction",
    gasBudget = DEFAULT_GAS_BUDGET,
): Promise<ExecutionReceipt> {
    let lastError: unknown;
    for (let attempt = 0; attempt < EXECUTE_MAX_ATTEMPTS; attempt++) {
        let tx: Transaction | null = null;
        let raw: any = null;
        try {
            // Build a fresh transaction on each attempt so object versions are re-resolved.
            tx = typeof buildTx === "function" ? await buildTx() : buildTx;
            tx.setSender(address);
            tx.setGasBudget(gasBudget);

            raw = await client.signAndExecuteTransaction({
                transaction: tx,
                signer,
                options: EXECUTION_RESPONSE_OPTIONS,
            });

            const status = raw.effects?.status;
            if (!isSuccessStatus(status)) {
                const artifactPath = await tryCollectTransactionDebug({
                    tx,
                    label,
                    attempt,
                    gasBudget,
                    phase: "execution_failure",
                    raw,
                });
                throw markFailedTransactionLogged(
                    new Error(
                        `${label} failed: ${formatStatusError(status, JSON.stringify(raw).slice(0, 300))}${failedTransactionSuffix(artifactPath)}`,
                    ),
                );
            }

            let settled: any;
            try {
                settled = await getTransactionBlockWithRetry(raw.digest);
            } catch (error) {
                const artifactPath = await tryCollectTransactionDebug({
                    tx,
                    label,
                    attempt,
                    gasBudget,
                    phase: "post_submit_fetch_error",
                    raw,
                    error,
                });
                throw markFailedTransactionLogged(
                    new Error(
                        `${label} post-submit fetch failure digest=${raw.digest}: ${String(error)}${failedTransactionSuffix(artifactPath)}`,
                    ),
                );
            }
            return {
                digest: raw.digest,
                gas: gasSummaryFromEffects(settled.effects ?? raw.effects),
                events: settled.events ?? raw.events ?? [],
                objectChanges: settled.objectChanges ?? raw.objectChanges ?? [],
                effects: settled.effects ?? raw.effects,
            };
        } catch (error) {
            lastError = error;
            if (failedTransactionAlreadyLogged(error)) {
                throw error;
            }
            const msg = String(error);
            // Retry on transient object version / input errors.
            if (msg.includes("Object ID") || msg.includes("TransactionExecutionClientError")) {
                if (attempt < EXECUTE_MAX_ATTEMPTS - 1) {
                    const delay = EXECUTE_RETRY_DELAY_MS * (attempt + 1);
                    const artifactPath = await tryCollectTransactionDebug({
                        tx,
                        label,
                        attempt,
                        gasBudget,
                        phase: "retryable_rpc_error",
                        raw,
                        error,
                    });
                    process.stdout.write(
                        `[retry] ${label} attempt ${attempt + 1} failed, retrying in ${delay}ms...${failedTransactionSuffix(artifactPath)}\n`,
                    );
                    await new Promise((r) => setTimeout(r, delay));
                    continue;
                }
            }
            const artifactPath = await tryCollectTransactionDebug({
                tx,
                label,
                attempt,
                gasBudget,
                phase: "rpc_error",
                raw,
                error,
            });
            if (error instanceof Error) {
                error.message = `${error.message}${failedTransactionSuffix(artifactPath)}`;
            }
            throw error;
        }
    }
    throw lastError;
}
