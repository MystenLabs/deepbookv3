import { bcs } from "@mysten/sui/bcs";
import { SuiGrpcClient, parseGrpcTransactionResponse } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { deriveObjectID } from "@mysten/sui/utils";

import {
    ACCOUNT_PACKAGE_ID,
    ACCOUNT_REGISTRY_ID,
    ADMIN_CAP_ID,
    BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
    BS_ADMIN_CAP_ID,
    BS_SIGNER_REGISTRY_ID,
    DUSDC_CURRENCY_ID,
    DUSDC_PACKAGE_ID,
    LOCAL_BS_SIGNER_PRIVATE_KEY,
    LOCAL_BS_SIGNER_PUBLIC_KEY,
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
    PREDICT_BLOCK_SCHOLES_BASE_ASSET,
    PREDICT_ORACLE_ID,
    forwardSid,
    spotSid,
    sviSid,
} from "./blockScholesSid.js";
import {
    signedSviBatchBytes,
    signedValueBatchBytes,
} from "./localBlockScholes.js";
import {
    type BsSviUpdate,
    type BsValueUpdate,
} from "./blockScholesWire.js";
import {
    type LocalPythConfig,
    hexToBytes,
    lazerUpdateFromConfig,
    updateTrustedSignerVaaFromConfig,
} from "./localPyth.js";
import { FAILED_TRANSACTIONS_DIR, ensureDir, ts, writeJson } from "./artifacts.js";
import { netGasCharge, selectGasPaymentRefs } from "./grpcGas.js";
import { transactionClockTimestampMs } from "./grpcClock.js";

export interface GasUsage {
    computationCost: number;
    storageCost: number;
    storageRebate: number;
    nonRefundableStorageFee: number;
    gasTotal: number;
}

export interface ExecutionReceipt {
    digest: string;
    clockTimestampMs: number | null;
    gas: GasUsage;
    events: any[];
    objectChanges: any[];
    effects: any;
}

export const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const CLOCK_ID = "0x6";
const COIN_REGISTRY_ID = "0xc";
// Sui's singleton balance-accumulator root lives at the reserved address 0xacc
// (object::SUI_ACCUMULATOR_ROOT_OBJECT_ID). The async-LP flush delivers PLP/DUSDC
// fills to an account's accumulator; every account capital op (mint/redeem settle,
// deposit, request_supply/withdraw) ambient-settles delivered funds through this root.
const ACCUMULATOR_ROOT_ID = "0xacc";
// Strike range encoding (range_codec / constants.move): two u30 ticks packed
// `lower | (higher << TICK_BITS)`. `raw_strike = tick * tick_size`. Tick 0 is the
// neg-inf sentinel (lower side); `POS_INF_TICK` is the pos-inf sentinel (higher
// side). The concrete tick size below mirrors the registered market tick size for
// this Propbook underlying.
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
const TRANSACTION_INCLUDE = {
    effects: true,
    events: true,
    objectTypes: true,
} as const;

export const client = new SuiGrpcClient({ baseUrl: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();
export { POOL_VAULT_ID, PROTOCOL_CONFIG_ID };

function gasBudgetFromEnv(): bigint {
    const raw = process.env.SIM_GAS_BUDGET?.trim();
    if (!raw) {
        throw new Error("SIM_GAS_BUDGET is required when no explicit gas budget is supplied");
    }
    if (!/^[1-9][0-9]*$/.test(raw)) {
        throw new Error(`SIM_GAS_BUDGET must be a positive integer MIST value, got "${raw}"`);
    }
    return BigInt(raw);
}

function isSuccessStatus(status: any): boolean {
    return status?.status === "success" || status?.success === true;
}

function formatStatusError(status: any, fallback: string): string {
    const error = status?.error;
    if (typeof error === "string") return error;
    if (typeof error?.message === "string") return error.message;
    if (error !== null && error !== undefined) return JSON.stringify(error);
    return fallback;
}

function unwrapTransactionResult(result: any): any {
    const transaction =
        result?.$kind === "Transaction"
            ? result.Transaction
            : result?.$kind === "FailedTransaction"
              ? result.FailedTransaction
              : result?.Transaction ?? result?.FailedTransaction;
    if (!transaction) {
        throw new Error(`Sui gRPC returned an unknown transaction result: ${JSON.stringify(result).slice(0, 300)}`);
    }
    return transaction;
}

function objectChangeType(change: any): string {
    if (change.idOperation === "Created") return "created";
    if (change.idOperation === "Deleted" || change.outputState === "DoesNotExist") return "deleted";
    if (change.outputState === "ObjectWrite" || change.outputState === "PackageWrite") return "mutated";
    return "unknown";
}

function normalizeTransactionResult(result: any): any {
    const transaction = unwrapTransactionResult(result);
    const objectTypes = transaction.objectTypes ?? {};
    return {
        ...transaction,
        events: (transaction.events ?? []).map((event: any) => ({
            ...event,
            type: event.eventType ?? event.type ?? "",
            parsedJson: event.json ?? event.parsedJson ?? {},
        })),
        objectChanges: (transaction.effects?.changedObjects ?? []).map((change: any) => ({
            ...change,
            type: objectChangeType(change),
            objectId: change.objectId,
            objectType: objectTypes[change.objectId] ?? "",
        })),
    };
}

const submittedTransactionBytes = new WeakMap<Transaction, Uint8Array>();
const gasBalanceBeforeByTransaction = new WeakMap<Transaction, bigint>();

async function signAndExecuteGrpc(
    tx: Transaction,
    txSigner: any,
    include: Record<string, boolean>,
): Promise<any> {
    const transaction = await buildGrpcTransactionBytes(tx, txSigner);
    submittedTransactionBytes.set(tx, transaction);
    return normalizeTransactionResult(
        await client.signAndExecuteTransaction({
            transaction,
            signer: txSigner,
            include,
        }),
    );
}

// The gRPC SDK resolves a Transaction by simulating the whole PTB with checks
// enabled. That is not execution-neutral on an idle localnet: Clock advances
// only when a transaction lands, so a legitimate next-checkpoint redeem can
// fail resolution against the prior mint's timestamp. Resolve only the
// TransactionKind with checks disabled, then attach explicit gas data and sign
// the fully resolved bytes. Actual execution remains the sole status authority.
async function buildGrpcTransactionBytes(
    tx: Transaction,
    txSigner: any,
): Promise<Uint8Array> {
    const original = tx.getData() as any;
    const sender = original.sender ?? txSigner.getPublicKey().toSuiAddress();
    const budget = original.gasData?.budget;
    if (budget === null || budget === undefined) {
        throw new Error("gRPC transaction requires an explicit gas budget");
    }

    const kind = await tx.build({ client, onlyTransactionKind: true });
    const resolved = Transaction.fromKind(kind);
    resolved.setSender(sender);
    resolved.setGasOwner(original.gasData?.owner ?? sender);
    resolved.setGasBudget(budget);
    const gasPrice =
        original.gasData?.price ??
        (await client.getReferenceGasPrice()).referenceGasPrice;
    resolved.setGasPrice(gasPrice);
    if (original.expiration) resolved.setExpiration(original.expiration);

    if (original.gasData?.payment?.length > 0) {
        resolved.setGasPayment(original.gasData.payment);
    } else {
        const plan = await selectGasPayment(resolved, sender, BigInt(budget));
        resolved.setGasPayment(plan.payment);
        gasBalanceBeforeByTransaction.set(tx, plan.balance);
    }
    return resolved.build();
}

function usedObjectIds(tx: Transaction): Set<string> {
    const used = new Set<string>();
    for (const input of (tx.getData() as any).inputs ?? []) {
        const object = input?.Object;
        const ref = object?.ImmOrOwnedObject ?? object?.Receiving;
        if (ref?.objectId) used.add(ref.objectId);
    }
    return used;
}

async function listGasCoins(owner: string): Promise<any[]> {
    const coins = [];
    let cursor: string | null = null;
    for (;;) {
        const page = await client.listCoins({ owner, cursor, limit: 50 });
        coins.push(...page.objects);
        if (!page.hasNextPage) return coins;
        if (!page.cursor) {
            throw new Error(`Sui gRPC returned a gas-coin page without its next cursor for ${owner}`);
        }
        cursor = page.cursor;
    }
}

async function selectGasPayment(
    tx: Transaction,
    owner: string,
    budget: bigint,
): Promise<{
    payment: Array<{ objectId: string; version: string; digest: string }>;
    balance: bigint;
}> {
    const used = usedObjectIds(tx);
    const coins = await listGasCoins(owner);
    try {
        const payment = selectGasPaymentRefs(coins, used, budget);
        const selected = new Set(payment.map((coin) => coin.objectId));
        const balance = coins
            .filter((coin) => selected.has(coin.objectId))
            .reduce((sum, coin) => sum + BigInt(coin.balance), 0n);
        return { payment, balance };
    } catch (error) {
        throw new Error(`no usable SUI gas payment for ${owner}: ${String(error)}`);
    }
}

async function extendPinnedGasPayment(params: {
    tx: Transaction;
    owner: string;
    pinned: { objectId: string; version: string; digest: string };
    pinnedBalance: bigint;
    budget: bigint;
}): Promise<{
    payment: Array<{ objectId: string; version: string; digest: string }>;
    balance: bigint;
}> {
    if (params.pinnedBalance >= params.budget) {
        return { payment: [params.pinned], balance: params.pinnedBalance };
    }
    const used = usedObjectIds(params.tx);
    used.add(params.pinned.objectId);
    const coins = await listGasCoins(params.owner);
    const additional = selectGasPaymentRefs(
        coins,
        used,
        params.budget - params.pinnedBalance,
    );
    const selected = new Set(additional.map((coin) => coin.objectId));
    const additionalBalance = coins
        .filter((coin) => selected.has(coin.objectId))
        .reduce((sum, coin) => sum + BigInt(coin.balance), 0n);
    return {
        payment: [params.pinned, ...additional],
        balance: params.pinnedBalance + additionalBalance,
    };
}

async function simulateGrpc(transaction: Transaction | Uint8Array): Promise<any> {
    const result = await client.simulateTransaction({
        transaction,
        checksEnabled: false,
        include: {
            effects: true,
            events: true,
            objectTypes: true,
            commandResults: true,
        },
    });
    return {
        ...normalizeTransactionResult(result),
        commandResults: result.commandResults ?? [],
    };
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
    transactionBytes?: Uint8Array | null;
    sender?: string;
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
        sender: params.sender ?? address,
        rpc_url: RPC_URL,
        gas_budget: params.gasBudget.toString(),
        digest,
        status: rawAny?.effects?.status ?? null,
        gas_used: rawAny?.effects?.gasUsed ?? null,
        error: safeArtifactValue(params.error),
        raw_response: safeArtifactValue(params.raw),
    };

    if (params.transactionBytes) {
        const bytes = params.transactionBytes;
        artifact.transaction_bytes = {
            length: bytes.length,
            base64: Buffer.from(bytes).toString("base64"),
        };
        try {
            artifact.dry_run = safeArtifactValue(await simulateGrpc(bytes));
        } catch (dryRunError) {
            artifact.dry_run_error = safeArtifactValue(dryRunError);
        }
    } else if (params.tx) {
        artifact.transaction_unavailable =
            "execution failed before producing complete transaction bytes";
    } else {
        artifact.transaction_unavailable = "transaction builder failed before producing a PTB";
    }

    if (digest !== null) {
        try {
            artifact.transaction = safeArtifactValue(
                normalizeTransactionResult(
                    await client.getTransaction({
                        digest,
                        include: {
                            transaction: true,
                            effects: true,
                            events: true,
                            objectTypes: true,
                            balanceChanges: true,
                        },
                    }),
                ),
            );
        } catch (fetchError) {
            artifact.transaction_fetch_error = safeArtifactValue(fetchError);
        }
    }

    ensureDir(FAILED_TRANSACTIONS_DIR);
    const path = failedTransactionArtifactPath(params.label, params.attempt);
    writeJson(path, artifact);
    process.stderr.write(`[${ts()}]   Failed transaction artifact: ${path}\n`);
    // Surface the REAL VM error, not just the artifact path. A framework-level MovePrimitiveRuntimeError
    // (e.g. 0x2::dynamic_field::borrow_child_object) names only the framework fn, hiding the true cause;
    // the dry-run's `executionErrorSource` states it in plain English (e.g. "Object runtime cached objects
    // limit (1000 entries) reached"). This line is why: the C-1 flush ceiling was debugged for days off the
    // truncated framework string while this exact message sat unsurfaced in the artifact. Always print it.
    const dr = artifact.dry_run as any;
    const vmError = dr?.executionErrorSource ?? dr?.effects?.status?.error ?? (artifact.status as any)?.error ?? null;
    if (vmError) {
        const message = typeof vmError === "string" ? vmError : vmError?.message ?? JSON.stringify(vmError);
        process.stderr.write(`[${ts()}]   VM error: ${message.slice(0, 300)}\n`);
    }
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
    const nonRefundableStorageFee = Number(gasUsed.nonRefundableStorageFee ?? 0);

    return {
        computationCost,
        storageCost,
        storageRebate,
        nonRefundableStorageFee,
        // Net MIST the sender's gas coin is charged: comp + storage - rebate. Goes
        // NEGATIVE (a refund) when a delete-heavy tx's storage rebate dominates —
        // the cleanout-incentive measurement (rebate-vs-compute) turns on this sign.
        gasTotal: computationCost + storageCost - storageRebate,
    };
}

// A refresh and the priced operation are separate receipts under the same-transaction
// oracle guard. Aggregate their gas, events, and object changes as one logical operation;
// the priced operation remains the authority for the returned digest and effects.
function aggregateGas(usages: GasUsage[]): GasUsage {
    return usages.reduce(
        (acc, gas) => ({
            computationCost: acc.computationCost + gas.computationCost,
            storageCost: acc.storageCost + gas.storageCost,
            storageRebate: acc.storageRebate + gas.storageRebate,
            nonRefundableStorageFee:
                acc.nonRefundableStorageFee + gas.nonRefundableStorageFee,
            gasTotal: acc.gasTotal + gas.gasTotal,
        }),
        {
            computationCost: 0,
            storageCost: 0,
            storageRebate: 0,
            nonRefundableStorageFee: 0,
            gasTotal: 0,
        },
    );
}

// Preserve the observable contents of the former single-PTB operation after splitting
// refresh from pricing: gas, events, and object changes cover every leg in submission
// order, while the final priced operation remains the scalar digest/effects/Clock authority.
function combineExecutionReceipts(receipts: ExecutionReceipt[]): ExecutionReceipt {
    const last = receipts[receipts.length - 1]!;
    return {
        ...last,
        gas: aggregateGas(receipts.map((receipt) => receipt.gas)),
        events: receipts.flatMap((receipt) => receipt.events),
        objectChanges: receipts.flatMap((receipt) => receipt.objectChanges),
    };
}

async function getTransactionWithRetry(digest: string): Promise<any> {
    let lastError: unknown;

    for (let attempt = 0; attempt < 20; attempt++) {
        try {
            const { response } = await client.ledgerService.getTransaction({
                digest,
                readMask: {
                    paths: [
                        "digest",
                        "effects",
                        "events",
                        "effects.changed_objects.object_type",
                        "effects.changed_objects.object_id",
                    ],
                },
            });
            if (!response.transaction) {
                throw new Error(`transaction ${digest} was not returned by Sui gRPC`);
            }
            const transaction = normalizeTransactionResult(
                parseGrpcTransactionResponse(response.transaction, {
                    include: TRANSACTION_INCLUDE,
                }),
            );
            const clockTimestampMs = await transactionClockTimestampMs(
                transaction.effects,
                async (version) => {
                    const { response: objectResponse } =
                        await client.ledgerService.getObject({
                            objectId: CLOCK_ID,
                            version,
                            readMask: {
                                paths: ["object_id", "version", "object_type", "json"],
                            },
                        });
                    return objectResponse;
                },
            );
            return { ...transaction, clockTimestampMs };
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
// any direct fixed_math/i64 Move call — the BS updates carry magnitude+sign
// primitives (`bs_oracle::verify` SVI updates). So there is no `fixedMathTarget`
// helper. The rename still matters for the localnet publish flow and the
// named-address dependency (see run.sh).

// propbook owns the extracted Pyth spot feed and the Block Scholes stores.
function propbookTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PROPBOOK_PACKAGE_ID}::${module}::${fn}`;
}

// `bs_oracle` is the real Block Scholes signature verifier, published unmodified.
// Batches are minted only by `verify_and_create_*_batch` over locally signed
// bytes (see localBlockScholes.ts) and ingested through the production
// `block_scholes_store::apply_*_batch` path.
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

export async function clockTimestampMs(): Promise<bigint> {
    const { object } = await client.getObject({
        objectId: CLOCK_ID,
        include: { json: true },
    });
    const json = object.json as any;
    const timestamp = json?.timestamp_ms ?? json?.fields?.timestamp_ms;
    if (timestamp === undefined) {
        throw new Error("unable to read localnet Clock timestamp");
    }
    return BigInt(timestamp);
}

// devInspect a read-only getter and return the first command's first raw return bytes.
// Read-only chain queries (no signing, no gas) used to reconcile keeper state from chain.
async function devInspectFirstReturn(tx: Transaction, cmdIndex = 0): Promise<number[]> {
    tx.setSenderIfNotSet(address);
    const r = await simulateGrpc(tx);
    if (!isSuccessStatus(r.effects?.status)) {
        throw new Error(`simulation failed: ${formatStatusError(r.effects?.status, JSON.stringify(r).slice(0, 300))}`);
    }
    const rv = r.commandResults?.[cmdIndex]?.returnValues?.[0]?.bcs;
    if (!rv) throw new Error(`devInspect: no return value at command ${cmdIndex}`);
    return Array.from(rv as Uint8Array);
}

function parseU64LE(bytes: number[]): bigint {
    let v = 0n;
    for (let i = 7; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i] ?? 0);
    return v;
}

function commandReturnBytes(result: any, cmdIndex: number): number[] {
    const value = result.commandResults?.[cmdIndex]?.returnValues?.[0]?.bcs;
    if (!value) throw new Error(`devInspect: no return value at command ${cmdIndex}`);
    return Array.from(value as Uint8Array);
}

// BCS vector<ID>: ULEB128 length, then N x 32-byte object ids.
function parseVectorId(bytes: number[]): string[] {
    let i = 0, len = 0, shift = 0;
    for (;;) {
        const b = bytes[i++];
        len |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7;
    }
    const ids: string[] = [];
    for (let k = 0; k < len; k++) {
        ids.push(`0x${bytes.slice(i, i + 32).map((x) => x.toString(16).padStart(2, "0")).join("")}`);
        i += 32;
    }
    return ids;
}

// On-chain active expiry-market object ids (chain truth for the keeper's flush set).
export async function readActiveMarketIds(): Promise<string[]> {
    const tx = new Transaction();
    tx.moveCall({ target: target("plp", "active_expiry_markets"), arguments: [tx.object(POOL_VAULT_ID)] });
    return parseVectorId(await devInspectFirstReturn(tx));
}

// On-chain valuation-lock flag (devInspect `protocol_config::valuation_in_progress`).
// The lock now spans transactions, so a keeper that died mid-flush leaves it engaged and
// every mutation lane stays blocked until it is cleared. Reading it is how the keeper
// notices, since a stuck lock otherwise only shows up as every other lane aborting.
export async function readValuationInProgress(): Promise<boolean> {
    const tx = new Transaction();
    tx.moveCall({
        target: target("protocol_config", "valuation_in_progress"),
        arguments: [tx.object(PROTOCOL_CONFIG_ID)],
    });
    const bytes = await devInspectFirstReturn(tx);
    return (bytes[0] ?? 0) !== 0;
}

// On-chain settlement flag for one market (devInspect `expiry_market::is_settled`). The
// cleanout measurement waits on this: `redeem_settled` and the settled sweep both
// require a settled market, and a settled market drops out of `active_expiry_markets`, so a
// settled-but-still-present read is the safe "ready to clean out" signal. BCS bool = 1 byte.
export async function readIsSettled(marketId: string): Promise<boolean> {
    const tx = new Transaction();
    tx.moveCall({ target: target("expiry_market", "is_settled"), arguments: [tx.object(marketId)] });
    const bytes = await devInspectFirstReturn(tx);
    return (bytes[0] ?? 0) !== 0;
}

// On-chain PLP total supply. NOTE: lock_capital mints the min-liquidity lock, so this is
// >0 after genesis step 2 of 4 — it is NOT a "fully bootstrapped" signal on its own.
export async function readPlpTotalSupply(): Promise<bigint> {
    const tx = new Transaction();
    tx.moveCall({ target: target("plp", "plp_total_supply"), arguments: [tx.object(POOL_VAULT_ID)] });
    return parseU64LE(await devInspectFirstReturn(tx));
}

// Queued-but-unflushed PLP supply requests (the genesis supply sits here between
// request_supply and the bare flush that mints it).
export async function readSupplyRequestsPending(): Promise<bigint> {
    const tx = new Transaction();
    tx.moveCall({ target: target("plp", "supply_requests_pending"), arguments: [tx.object(POOL_VAULT_ID)] });
    return parseU64LE(await devInspectFirstReturn(tx));
}

// Whether a shared/owned object still exists on chain (used to make genesis steps idempotent).
export async function objectExists(id: string): Promise<boolean> {
    const result = (await client.getObjects({ objectIds: [id] })).objects[0] as any;
    return result !== undefined && typeof result?.objectId === "string";
}

// A market's expiry (ms) read from chain — recovers expiries for markets the keeper did
// not create itself (orphan from a lost create response, or a keeper restart).
export async function readMarketExpiry(marketId: string): Promise<bigint> {
    const tx = new Transaction();
    tx.moveCall({ target: target("expiry_market", "expiry"), arguments: [tx.object(marketId)] });
    return parseU64LE(await devInspectFirstReturn(tx));
}

// An account's PLP share balance (custody, accumulator-accrued). Read so a strategy's
// withdraw never over-draws — an over-draw aborts in lp_book and the bug oracle would flag
// it. Chains account::load_account(wrapper) -> account::balance<PLP>(account, root, clock);
// the u64 is command 1's return.
export async function readPlpBalance(owner: string): Promise<bigint> {
    const tx = new Transaction();
    const account = tx.moveCall({ target: accountTarget("account", "load_account"), arguments: [tx.object(deriveAccountWrapperId(owner))] });
    tx.moveCall({
        target: accountTarget("account", "balance"),
        typeArguments: [`${PACKAGE_ID}::plp::PLP`],
        arguments: [account, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
    });
    return parseU64LE(await devInspectFirstReturn(tx, 1));
}

export interface PredictEconomicState {
    accountDusdcBalance: bigint;
    accountPlpBalance: bigint;
    expiryCashBalance: bigint;
    inventoryImpactReserve: bigint;
    payoutLiability: bigint;
    requiredCash: bigint;
    feeIncentiveBalance: bigint;
    vaultIdleBalance: bigint;
    vaultProtocolReserveBalance: bigint;
    vaultPendingProtocolProfit: bigint;
    profitBasisDebits: bigint;
    profitBasisCredits: bigint;
    vaultTotalPlpSupply: bigint;
    supplyRequestsPending: bigint;
    withdrawRequestsPending: bigint;
    isSettled: boolean;
    activeMarketCount: bigint;
}

// Read every material parity field from one devInspect snapshot. The simulation
// deliberately does not maintain a shadow TypeScript ledger: the chain is the live
// side's state authority, while emitted events describe each transition.
export async function readPredictEconomicState(params: {
    poolVaultId: string;
    expiryMarketId: string;
    wrapperId: string;
}): Promise<PredictEconomicState> {
    const tx = new Transaction();
    const vault = tx.object(params.poolVaultId);
    const market = tx.object(params.expiryMarketId);
    tx.moveCall({ target: target("plp", "idle_balance"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "protocol_reserve_balance"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "pending_protocol_profit"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "profit_basis_debits"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "profit_basis_credits"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "plp_total_supply"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "supply_requests_pending"), arguments: [vault] });
    tx.moveCall({ target: target("plp", "withdraw_requests_pending"), arguments: [vault] });
    tx.moveCall({ target: target("expiry_market", "cash_balance"), arguments: [market] });
    tx.moveCall({ target: target("expiry_market", "inventory_impact_reserve"), arguments: [market] });
    tx.moveCall({ target: target("expiry_market", "payout_liability"), arguments: [market] });
    tx.moveCall({ target: target("expiry_market", "required_cash"), arguments: [market] });
    tx.moveCall({ target: target("expiry_market", "fee_incentive_balance"), arguments: [market] });
    tx.moveCall({ target: target("expiry_market", "is_settled"), arguments: [market] });
    tx.moveCall({ target: target("plp", "active_expiry_markets"), arguments: [vault] });
    const account = tx.moveCall({
        target: accountTarget("account", "load_account"),
        arguments: [tx.object(params.wrapperId)],
    });
    tx.moveCall({
        target: accountTarget("account", "balance"),
        typeArguments: [DUSDC_TYPE],
        arguments: [account, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
    });
    tx.moveCall({
        target: accountTarget("account", "balance"),
        typeArguments: [`${PACKAGE_ID}::plp::PLP`],
        arguments: [account, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
    });
    tx.setSenderIfNotSet(address);
    const result = await simulateGrpc(tx);
    if (!isSuccessStatus(result.effects?.status)) {
        throw new Error(
            `economic state simulation failed: ${formatStatusError(result.effects?.status, JSON.stringify(result).slice(0, 300))}`,
        );
    }
    const u64 = (index: number) => parseU64LE(commandReturnBytes(result, index));
    return {
        vaultIdleBalance: u64(0),
        vaultProtocolReserveBalance: u64(1),
        vaultPendingProtocolProfit: u64(2),
        profitBasisDebits: u64(3),
        profitBasisCredits: u64(4),
        vaultTotalPlpSupply: u64(5),
        supplyRequestsPending: u64(6),
        withdrawRequestsPending: u64(7),
        expiryCashBalance: u64(8),
        inventoryImpactReserve: u64(9),
        payoutLiability: u64(10),
        requiredCash: u64(11),
        feeIncentiveBalance: u64(12),
        isSettled: (commandReturnBytes(result, 13)[0] ?? 0) !== 0,
        activeMarketCount: BigInt(parseVectorId(commandReturnBytes(result, 14)).length),
        accountDusdcBalance: u64(16),
        accountPlpBalance: u64(17),
    };
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

// One oracle refresh writes all Propbook slots: a permissionless Pyth Lazer spot
// update, then separate Block Scholes spot, forward, and SVI batches. The expiry
// batches carry descriptor witnesses, and the two per-underlying stores are the
// only Block Scholes objects the refresh touches.
export interface OracleFeedIds {
    pythFeedId: string;
    bsValueStoreId: string;
    bsSviStoreId: string;
}

interface OracleRefreshParams extends OracleFeedIds {
    expiry: bigint;
    spot: bigint;
    forward: bigint;
    svi: {
        a: bigint;
        aNegative: boolean;
        b: bigint;
        rho: bigint;
        rhoNegative: boolean;
        m: bigint;
        mNegative: boolean;
        sigma: bigint;
    };
}

interface MintParams extends OracleFeedIds {
    expiryMarketId: string;
    protocolConfigId: string;
    wrapperId: string;
    strike: bigint;
    isUp: boolean;
    quantity: bigint;
    tickSize?: bigint; // cadence tick size; live harness default is $0.01
    maxCost?: bigint; // all-in DUSDC withdrawal cap; U64_MAX (uncapped) if omitted
    maxProbability?: bigint; // per-contract probability cap (1e9); U64_MAX if omitted
}

interface RedeemParams extends OracleFeedIds {
    expiryMarketId: string;
    protocolConfigId: string;
    wrapperId: string;
    orderId: string;
    closeQuantity: bigint;
}

interface LivePricerParams extends OracleFeedIds {
    expiryMarketId: string;
    protocolConfigId: string;
}

// Inputs to drive one privileged full-pool flush (the async LP drain).
export interface FlushParams extends OracleFeedIds {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    lifecycleCapId: string;
}

// Convert a raw binary-range strike to the `(lower_tick, higher_tick)` pair the
// `mint` entrypoint now takes directly (there is no standalone packed range key).
// An UP order is `(strike, +inf)` -> lower_tick = strike/tick_size, higher_tick =
// POS_INF_TICK; a DOWN order is `(-inf, strike)` -> lower_tick = 0 (neg-inf),
// higher_tick = strike/tick_size.
export function binaryRangeTicks(
    strike: bigint,
    isUp: boolean,
    tickSize = ORACLE_TICK_SIZE,
): { lowerTick: bigint; higherTick: bigint } {
    const tick = strike / tickSize;
    if (tick * tickSize !== strike) {
        throw new Error(`strike ${strike} is not a whole tick multiple of ${tickSize}`);
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

// A refresh and the priced operation it feeds are always separate transactions.
// `pricing::resolve_live_pricer` aborts `EOracleWrittenInThisTransaction` when an
// observation carries the current transaction's digest. Return the refresh first so
// callers can execute both legs in order without weakening snapshot determinism.
async function refreshThen(
    params: OracleRefreshParams,
    addPricedOperation: (tx: Transaction) => void,
): Promise<Transaction[]> {
    const refreshTx = new Transaction();
    await addOracleRefresh(refreshTx, params);
    const pricedOperationTx = new Transaction();
    addPricedOperation(pricedOperationTx);
    return [refreshTx, pricedOperationTx];
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

// The same clamp for the Pyth leg, on its own monotonic cursor. The Pyth spot must be
// stamped with Pyth's OWN stream clock, never the cross-stream envelope: the envelope
// is the max over every input clock, so stamping Pyth with it lets Block Scholes
// activity keep a stalled Pyth stream artificially fresh on-chain — and the contract's
// Pyth-stale → BS-forward fallback can then never be exercised in a run. Returns null
// when Pyth has nothing newer; the caller skips the Pyth leg and the feed ages honestly.
let lastPythTimestampMs = 0n;
export async function clampedPythTimestampMs(realMs: bigint): Promise<bigint | null> {
    const clockMax = (await clockTimestampMs()) - 1n;
    const ts = realMs < clockMax ? realMs : clockMax;
    if (ts <= lastPythTimestampMs) return null;
    lastPythTimestampMs = ts;
    return ts;
}

// Build ONE refresh PTB covering a grid of expiries: re-signed Pyth spot, then
// separate BS spot, forward, and SVI batches. Pre-warms the whole boundary grid
// in a single transaction under one (clamped) envelope timestamp — the clock the
// on-chain stores age series by and the SVI roll-down anchors on — while each
// series keeps its own provider model time, the clock the stores order by.
export interface GridExpiry {
    expiry: bigint;
    forward: bigint;
    /// Provider model time of the forward ("as of"); 0 = unknown, use the envelope.
    forwardTsMs: bigint;
    svi: OracleRefreshParams["svi"];
    /// Provider model time of the SVI tuple; 0 = unknown, use the envelope.
    sviTsMs: bigint;
}

export function buildOracleRefreshGridTx(
    feeds: OracleFeedIds,
    pythSpot1e9: bigint,
    pythTsMs: bigint | null,
    bsSpot: { value1e9: bigint; tsMs: bigint },
    grid: GridExpiry[],
    sourceTimestampMs: bigint,
): Transaction {
    const tx = new Transaction();
    addOracleRefreshGrid(tx, feeds, pythSpot1e9, pythTsMs, bsSpot, grid, sourceTimestampMs);
    return tx;
}

// Add a grid refresh (spot, forward, and SVI batches) to an existing PTB. This
// must remain a refresh-only PTB: a priced operation appended after it would abort
// `EOracleWrittenInThisTransaction`. Each
// series carries its own provider model time; a series whose model time is
// unknown gets the envelope, and one that momentarily postdates the envelope
// (cross-stream clock skew) is skipped this push rather than clamped — the store
// would refuse it as malformed, and the next push lands it honestly.
// The Pyth spot is stamped with Pyth's own stream clock (`pythTsMs`), never the
// envelope: the envelope is the max over every input clock, so reusing it would let
// Block Scholes activity keep a stalled Pyth stream artificially fresh on-chain. A
// null `pythTsMs` (Pyth has nothing newer) skips the Pyth leg so the feed ages
// honestly and the Pyth-stale → BS-forward fallback stays reachable in a run.
function addOracleRefreshGrid(
    tx: Transaction,
    feeds: OracleFeedIds,
    pythSpot1e9: bigint,
    pythTsMs: bigint | null,
    bsSpot: { value1e9: bigint; tsMs: bigint },
    grid: GridExpiry[],
    sourceTimestampMs: bigint,
): void {
    const seriesTs = (tsMs: bigint): bigint | null => {
        if (tsMs <= 0n) return sourceTimestampMs;
        if (tsMs > sourceTimestampMs) return null;
        return tsMs;
    };
    if (pythTsMs !== null) addPythFeedUpdate(tx, feeds.pythFeedId, pythSpot1e9, pythTsMs);
    // The BS spot slot carries Block Scholes' own signed spot series at its own model
    // time — a separate observation from the Pyth spot above.
    let spotUpdate: BsValueUpdate | null = null;
    const spotTs = seriesTs(bsSpot.tsMs);
    if (spotTs !== null) {
        spotUpdate = {
            sid: spotSid(BLOCK_SCHOLES_ORACLE_PACKAGE_ID, PREDICT_BLOCK_SCHOLES_BASE_ASSET),
            timestampMs: spotTs,
            value: bsSpot.value1e9,
        };
    }
    const forwardUpdates: ExpiringValueUpdate[] = [];
    for (const g of grid) {
        const ts = seriesTs(g.forwardTsMs);
        if (ts !== null) {
            forwardUpdates.push({
                expiryMs: g.expiry,
                update: {
                    sid: forwardSid(
                        BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
                        PREDICT_BLOCK_SCHOLES_BASE_ASSET,
                        g.expiry,
                    ),
                    timestampMs: ts,
                    value: g.forward,
                },
            });
        }
    }
    const sviUpdates: ExpiringSviUpdate[] = [];
    for (const g of grid) {
        const ts = seriesTs(g.sviTsMs);
        if (ts !== null) {
            sviUpdates.push({
                expiryMs: g.expiry,
                update: sviBatchUpdate(g.expiry, g.svi, ts),
            });
        }
    }
    if (spotUpdate !== null || forwardUpdates.length > 0 || sviUpdates.length > 0) {
        addBsBatches(tx, feeds, sourceTimestampMs, spotUpdate, forwardUpdates, sviUpdates);
    }
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
        PREDICT_ORACLE_ID,
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

// Settlement observation: same re-signed Lazer spot update as addPythFeedUpdate, but
// stored via `insert_at` at the exact whole-second expiry timestamp for `try_settle`.
function addPythFeedInsert(tx: Transaction, pythFeedId: string, spot: bigint, expiryMs: bigint): void {
    const updateBytes = lazerUpdateFromConfig(localPythConfig(), PREDICT_ORACLE_ID, spot, expiryMs);
    const update = tx.moveCall({
        target: pythLazerTarget("pyth_lazer", "parse_and_verify_le_ecdsa_update"),
        arguments: [tx.object(PYTH_LAZER_STATE_ID), tx.object(CLOCK_ID), tx.pure.vector("u8", Array.from(updateBytes))],
    });
    tx.moveCall({
        target: propbookTarget("pyth_feed", "insert_at"),
        arguments: [tx.object(pythFeedId), update, tx.object(CLOCK_ID)],
    });
}

function addTrySettle(
    tx: Transaction,
    params: { marketId: string; protocolConfigId: string; pythFeedId: string; bsValueStoreId: string },
): void {
    tx.moveCall({
        target: target("expiry_market", "try_settle"),
        arguments: [
            tx.object(params.marketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsValueStoreId),
            tx.object(CLOCK_ID),
        ],
    });
}

// Block Scholes updates: sign real batches with the local signer key (registered
// on the localnet `SignerRegistry`), mint the hot-potato batches through the
// verifier, and ingest them through the production
// `block_scholes_store::apply_*_batch` path. Spot, forwards, and SVI each carry
// their typed descriptor witnesses, matching the production writer. Each update's
// own timestamp is the model "as of" time; the envelope is the publish time.
type ExpiringValueUpdate = { expiryMs: bigint; update: BsValueUpdate };
type ExpiringSviUpdate = { expiryMs: bigint; update: BsSviUpdate };

function addBsBatches(
    tx: Transaction,
    stores: { bsValueStoreId: string; bsSviStoreId: string },
    publishedAtMs: bigint,
    spotUpdate: BsValueUpdate | null,
    forwardUpdates: ExpiringValueUpdate[],
    sviUpdates: ExpiringSviUpdate[],
): void {
    // The verifier rejects an empty batch, so each lane is only built when it has entries.
    if (spotUpdate !== null) {
        const spotMessage = signedValueBatchBytes({
            signerPrivateKey: LOCAL_BS_SIGNER_PRIVATE_KEY,
            verifierPackageId: BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
            batchTimestampMs: publishedAtMs,
            updates: [spotUpdate],
        });
        const spotBatch = tx.moveCall({
            target: bsOracleTarget("verify", "verify_and_create_value_batch"),
            arguments: [
                tx.object(BS_SIGNER_REGISTRY_ID),
                tx.pure.vector("u8", Array.from(spotMessage)),
            ],
        });
        tx.moveCall({
            target: propbookTarget("block_scholes_store", "apply_spot_batch"),
            arguments: [tx.object(stores.bsValueStoreId), spotBatch, tx.object(CLOCK_ID)],
        });
    }

    if (forwardUpdates.length > 0) {
        const forwardMessage = signedValueBatchBytes({
            signerPrivateKey: LOCAL_BS_SIGNER_PRIVATE_KEY,
            verifierPackageId: BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
            batchTimestampMs: publishedAtMs,
            updates: forwardUpdates.map(({ update }) => update),
        });
        const forwardBatch = tx.moveCall({
            target: bsOracleTarget("verify", "verify_and_create_value_batch"),
            arguments: [
                tx.object(BS_SIGNER_REGISTRY_ID),
                tx.pure.vector("u8", Array.from(forwardMessage)),
            ],
        });
        tx.moveCall({
            target: propbookTarget("block_scholes_store", "apply_forward_batch"),
            arguments: [
                tx.object(stores.bsValueStoreId),
                forwardBatch,
                tx.pure.vector(
                    "u64",
                    forwardUpdates.map(({ expiryMs }) => expiryMs),
                ),
                tx.object(CLOCK_ID),
            ],
        });
    }

    if (sviUpdates.length === 0) return;
    const sviMessage = signedSviBatchBytes({
        signerPrivateKey: LOCAL_BS_SIGNER_PRIVATE_KEY,
        verifierPackageId: BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
        batchTimestampMs: publishedAtMs,
        updates: sviUpdates.map(({ update }) => update),
    });
    const sviBatch = tx.moveCall({
        target: bsOracleTarget("verify", "verify_and_create_svi_batch"),
        arguments: [tx.object(BS_SIGNER_REGISTRY_ID), tx.pure.vector("u8", Array.from(sviMessage))],
    });
    tx.moveCall({
        target: propbookTarget("block_scholes_store", "apply_svi_batch"),
        arguments: [
            tx.object(stores.bsSviStoreId),
            sviBatch,
            tx.pure.vector(
                "u64",
                sviUpdates.map(({ expiryMs }) => expiryMs),
            ),
            tx.object(CLOCK_ID),
        ],
    });
}

function sviBatchUpdate(
    expiry: bigint,
    svi: OracleRefreshParams["svi"],
    timestampMs: bigint,
): BsSviUpdate {
    return {
        sid: sviSid(BLOCK_SCHOLES_ORACLE_PACKAGE_ID, PREDICT_BLOCK_SCHOLES_BASE_ASSET, expiry),
        timestampMs,
        aMagnitude: svi.a,
        aNegative: svi.aNegative,
        b: svi.b,
        sigma: svi.sigma,
        rhoMagnitude: svi.rho,
        rhoNegative: svi.rhoNegative,
        mMagnitude: svi.m,
        mNegative: svi.mNegative,
    };
}

function addBlockScholesUpdates(
    tx: Transaction,
    params: OracleRefreshParams,
    publishedAtMs: bigint,
): void {
    addBsBatches(
        tx,
        params,
        publishedAtMs,
        {
            sid: spotSid(BLOCK_SCHOLES_ORACLE_PACKAGE_ID, PREDICT_BLOCK_SCHOLES_BASE_ASSET),
            timestampMs: publishedAtMs,
            value: params.spot,
        },
        [
            {
                expiryMs: params.expiry,
                update: {
                    sid: forwardSid(
                        BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
                        PREDICT_BLOCK_SCHOLES_BASE_ASSET,
                        params.expiry,
                    ),
                    timestampMs: publishedAtMs,
                    value: params.forward,
                },
            },
        ],
        [
            {
                expiryMs: params.expiry,
                update: sviBatchUpdate(params.expiry, params.svi, publishedAtMs),
            },
        ],
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
            tx.object(params.bsValueStoreId),
            tx.object(params.bsSviStoreId),
            tx.object(CLOCK_ID),
        ],
    });
}

// Add the ATOMIC snapshot stage: the privileged `start_pool_valuation` (via a
// market-deployer `MarketLifecycleCap` proof — the sole flush authority) -> one
// `snapshot_expiry_pricer` per active market -> `seal_valuation_snapshot`, which
// consumes the `SnapshotStage` potato. These commands MUST stay in one PTB and the
// potato enforces it: every market's `Pricer` is frozen at the instant this
// transaction executes, and that simultaneity is what lets valuation resume later.
// This stage reads oracles and walks no payout tree, so it fits one PTB at any book
// size. The oracle it reads must have been written in an EARLIER transaction —
// `resolve_live_pricer` refuses a same-transaction write (RP-24).
function addSnapshotStage(tx: Transaction, params: FlushParams): void {
    const proof = tx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [tx.object(REGISTRY_ID), tx.object(params.lifecycleCapId)],
    });
    const stage = tx.moveCall({
        target: target("plp", "start_pool_valuation"),
        arguments: [
            tx.object(params.protocolConfigId),
            tx.object(params.poolVaultId),
            proof,
            tx.object(CLOCK_ID),
        ],
    });
    // The devtools flow runs one expiry market; a multi-market topology snapshots each
    // one here, all inside this same transaction.
    tx.moveCall({
        target: target("plp", "snapshot_expiry_pricer"),
        arguments: [
            tx.object(params.poolVaultId),
            stage,
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsValueStoreId),
            tx.object(params.bsSviStoreId),
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: target("plp", "seal_valuation_snapshot"),
        arguments: [tx.object(params.poolVaultId), stage, tx.object(params.protocolConfigId)],
    });
}

// One RESUMABLE-stage transaction valuing ONE market. `value_expiry` reads no oracle —
// the frozen snapshot decides both the mark and the sweep-vs-value branch — but it is
// the only stage that walks payout trees, and the per-market node cap is derived
// assuming exactly one market per transaction: never batch two markets, and never
// batch a `value_expiry` with `finish_flush`.
function valueExpiryTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("plp", "value_expiry"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
        ],
    });
    return tx;
}

// The closing transaction: `finish_flush` proves every snapshotted market was valued,
// drains both LP queues at the frozen mark, and releases the valuation lock. Its two
// budgets are `None` (unbounded). Only the flush starter's address may run it.
function finishFlushTx(params: { poolVaultId: string; protocolConfigId: string }): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("plp", "finish_flush"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // supply_budget: None (unbounded)
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // withdraw_budget: None (unbounded)
        ],
    });
    return tx;
}

function addMint(tx: Transaction, params: MintParams): void {
    const { lowerTick, higherTick } = binaryRangeTicks(
        params.strike,
        params.isUp,
        params.tickSize,
    );
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
            tx.pure.u64(params.maxCost ?? U64_MAX),
            tx.pure.u64(params.maxProbability ?? U64_MAX),
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

// === Account cleanout (settled-redeem gas measurement, E1) ===
// One PTB that redeems every settled position on `wrapper` (permissionless full-close). This is
// the maximally-incentivized keeper/MEV cleanout: it deletes the N position dynamic-field
// entries, so its net gas (comp + storage - rebate) is the E1 self-incentive signal (negative =
// the cleaner is paid). Requires the market SETTLED. The permissionless entrypoint derives
// PredictApp app-auth internally, so the caller needs no Auth object and can clean out ANY
// account's wrapper — the actual on-chain keeper surface, priced as-is.
export interface CleanoutPosition {
    orderId: string;
}
export interface CleanoutParams {
    expiryMarketId: string;
    wrapperId: string;
    positions: CleanoutPosition[];
}

function addRedeemSettledPermissionless(
    tx: Transaction,
    p: { expiryMarketId: string; wrapperId: string; orderId: string; protocolConfigId?: string },
): void {
    // redeem_settled_permissionless(market, account_registry, wrapper, config, order_id,
    //   root, clock, ctx). A settled close is always full — the entrypoint takes no
    //   quantity. Settlement is a separate PTB transition; this consumer needs no
    //   oracle objects or live pricer.
    tx.moveCall({
        target: target("expiry_market", "redeem_settled_permissionless"),
        arguments: [
            tx.object(p.expiryMarketId),
            tx.object(ACCOUNT_REGISTRY_ID),
            tx.object(p.wrapperId),
            tx.object(p.protocolConfigId ?? PROTOCOL_CONFIG_ID),
            tx.pure.u256(BigInt(p.orderId)),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
}

export function redeemSettledTx(params: {
    expiryMarketId: string;
    protocolConfigId: string;
    wrapperId: string;
    orderId: string;
    permissionless: boolean;
}): Transaction {
    const tx = new Transaction();
    if (params.permissionless) {
        addRedeemSettledPermissionless(tx, params);
    } else {
        const auth = generateAuth(tx);
        tx.moveCall({
            target: target("expiry_market", "redeem_settled"),
            arguments: [
                tx.object(params.expiryMarketId),
                tx.object(params.wrapperId),
                auth,
                tx.object(params.protocolConfigId),
                tx.pure.u256(BigInt(params.orderId)),
                tx.object(ACCUMULATOR_ROOT_ID),
                tx.object(CLOCK_ID),
            ],
        });
    }
    return tx;
}

export function cleanoutAccountTx(params: CleanoutParams): Transaction {
    const tx = new Transaction();
    for (const pos of params.positions) {
        addRedeemSettledPermissionless(tx, {
            expiryMarketId: params.expiryMarketId,
            wrapperId: params.wrapperId,
            orderId: pos.orderId,
        });
    }
    return tx;
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
    // lives on Registry, its sole gating call site being create_and_share_expiry_market).
    const cap = tx.moveCall({
        target: target("registry", "mint_lifecycle_cap"),
        // `mint_lifecycle_cap(registry, config, admin_cap, ctx)` — the mint is version-
        // gated, so it reads the protocol config.
        arguments: [tx.object(REGISTRY_ID), tx.object(PROTOCOL_CONFIG_ID), tx.object(ADMIN_CAP_ID)],
    });
    tx.transferObjects([cap], tx.pure.address(recipient));
    return tx;
}

// Admin-approve one Propbook underlying for Predict, permissionlessly create the
// permanent Pyth spot feed, and admin-create the underlying's Block Scholes store
// pair. The stores are canonical at creation (their registry binding is made in
// the same call), so no separate BS bind step exists.
export function registerUnderlyingAndCreateFeedsTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "register_underlying"),
        // `register_underlying(registry, config, admin_cap, underlying_id)`.
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(PROTOCOL_CONFIG_ID),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u32(PREDICT_ORACLE_ID),
        ],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_pyth_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(PREDICT_ORACLE_ID)],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_block_scholes_stores"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.pure.u32(PREDICT_ORACLE_ID),
            tx.pure.string(PREDICT_BLOCK_SCHOLES_BASE_ASSET),
        ],
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
        target: target("registry", "set_template_cadence_config"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(PROTOCOL_CONFIG_ID),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u32(PREDICT_ORACLE_ID),
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

// Admin-bind the Pyth spot feed to one canonical Propbook underlying. Must run
// after the feed is shared. The Block Scholes stores need no bind step: their
// binding is made when the pair is created (registerUnderlyingAndCreateFeedsTx).
export function bindFeedsToUnderlyingTx(params: { pythFeedId: string }): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: propbookTarget("registry", "bind_pyth_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.pythFeedId),
            tx.pure.u32(PREDICT_ORACLE_ID),
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
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: target("protocol_config", "set_template_expiry_fee_max_multiplier"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(expiryFeeMaxMultiplier),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

export function setSimulationEconomicPolicyTx(params: {
    protocolConfigId: string;
    baseFee: bigint;
    minFee: bigint;
    minEntryProbability: bigint;
    maxEntryProbability: bigint;
    backingBufferLambda: bigint;
    inventoryImpactMaxRate: bigint;
    protocolReserveProfitShare: bigint;
    plpSupplyFeeRate: bigint;
    plpWithdrawFeeRate: bigint;
    lpRequestLimitFlushAttempts: bigint;
    maxLpPoolValue: bigint;
}): Transaction {
    const tx = new Transaction();
    const call = (fn: string, value: bigint) =>
        tx.moveCall({
            target: target("protocol_config", fn),
            arguments: [
                tx.object(params.protocolConfigId),
                tx.object(ADMIN_CAP_ID),
                tx.pure.u64(value),
            ],
        });
    const callWithClock = (fn: string, value: bigint) =>
        tx.moveCall({
            target: target("protocol_config", fn),
            arguments: [
                tx.object(params.protocolConfigId),
                tx.object(ADMIN_CAP_ID),
                tx.pure.u64(value),
                tx.object(CLOCK_ID),
            ],
        });
    callWithClock("set_template_base_fee", params.baseFee);
    callWithClock("set_template_min_fee", params.minFee);
    callWithClock("set_template_min_entry_probability", params.minEntryProbability);
    callWithClock("set_template_max_entry_probability", params.maxEntryProbability);
    callWithClock("set_template_backing_buffer_lambda", params.backingBufferLambda);
    callWithClock("set_template_inventory_impact_max_rate", params.inventoryImpactMaxRate);
    call("set_protocol_reserve_profit_share", params.protocolReserveProfitShare);
    callWithClock("set_plp_supply_fee_rate", params.plpSupplyFeeRate);
    callWithClock("set_plp_withdraw_fee_rate", params.plpWithdrawFeeRate);
    call("set_lp_request_limit_flush_attempts", params.lpRequestLimitFlushAttempts);
    call("set_max_lp_pool_value", params.maxLpPoolValue);
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

// Register the per-instance local signer key on the verifier's `SignerRegistry`
// (the harness published `bs_oracle`, so it holds the `AdminCap`). After this,
// only batches signed by localBlockScholes.ts verify — the BS analogue of
// `updatePythTrustedSignerTx`.
export function setBlockScholesSignerTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: bsOracleTarget("registry", "set_signer"),
        arguments: [
            tx.object(BS_SIGNER_REGISTRY_ID),
            tx.object(BS_ADMIN_CAP_ID),
            tx.pure.vector("u8", Array.from(hexToBytes(LOCAL_BS_SIGNER_PUBLIC_KEY))),
        ],
    });
    return tx;
}

// Seed the Block Scholes stores (and Pyth spot) for the market's expiry. Market
// creation itself reads NO spot now (absolute ticks need no grid centering), but a
// fresh BS price/SVI series set must exist before the first mint and before any
// flush valuation can price `current_nav`. The store pair exists from underlying
// registration; seeding the per-expiry series rows happens after the market is
// created (its expiry fixes their sids).
export async function seedOracleTx(params: OracleFeedIds & {
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
// the Pyth feed and the Block Scholes store pair are bound to `PREDICT_ORACLE_ID`
// (run `bindFeedsToUnderlyingTx` first; the store pair binds at creation).
// `create_and_share_expiry_market` returns one ID and
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
        target: target("registry", "create_and_share_expiry_market"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.lifecycleCapId),
            tx.pure.u32(PREDICT_ORACLE_ID),
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
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("plp", "rebalance_expiry_cash"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
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
    minPlpOut?: bigint;
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
            tx.pure.u64(params.minPlpOut ?? 0n),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Queue a supply request pulling `amount` from the account's EXISTING custody DUSDC (no fresh
// mint). For actors WITHOUT the DUSDC TreasuryCap (traders): the keeper funds the account,
// then this supplies from that balance — `request_supply` auto-settles + `account.withdraw`
// pulls the custody DUSDC. (requestSupplyTx mints fresh DUSDC and is keeper-only.)
export function requestSupplyFromCustodyTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    wrapperId: string;
    amount: bigint;
    minPlpOut?: bigint;
}): Transaction {
    const tx = new Transaction();
    const supplyAuth = generateAuth(tx);
    tx.moveCall({
        target: target("plp", "request_supply"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.wrapperId),
            supplyAuth,
            tx.object(params.protocolConfigId),
            tx.pure.u64(params.amount),
            tx.pure.u64(params.minPlpOut ?? 0n),
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
    minDusdcOut?: bigint;
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
            tx.pure.u64(params.minDusdcOut ?? 0n),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Refresh the oracle, then run one privileged full-pool flush that drains both LP
// request queues at the frozen mark. The drain happens inside `finish_flush`; no
// per-LP coin is returned (fills land on the manager via the accumulator).
// The flush is multi-transaction now: refresh, then the atomic snapshot stage, then one
// `value_expiry` per market, then `finish_flush`. The snapshot must be a LATER
// transaction than the refresh (RP-24 refuses a same-transaction oracle write) and
// inside the feeds' freshness windows; `value_expiry` and `finish_flush` each get their
// own transaction (the per-market node cap assumes it).
export async function refreshOracleAndFlushTxs(
    params: OracleRefreshParams & FlushParams,
): Promise<Transaction[]> {
    const txs = await refreshThen(params, (tx) => addSnapshotStage(tx, params));
    return [...txs, valueExpiryTx(params), finishFlushTx(params)];
}

// Genesis flush with NO active markets: proof -> start (snapshots an empty expected set)
// -> seal (trivially complete: zero frozen pricers match zero expected markets) ->
// finish, which bootstrap-mints PLP 1:1 against the queued supply. Run once before any
// market exists, so the bootstrap never races a fast cadence's first expiry. Stays a
// single PTB: with no market to value there is no payout tree to walk, so nothing here
// needs the resumable split.
export function bareFlushTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    lifecycleCapId: string;
}): Transaction {
    const tx = new Transaction();
    const proof = tx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [tx.object(REGISTRY_ID), tx.object(params.lifecycleCapId)],
    });
    const stage = tx.moveCall({
        target: target("plp", "start_pool_valuation"),
        arguments: [
            tx.object(params.protocolConfigId),
            tx.object(params.poolVaultId),
            proof,
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: target("plp", "seal_valuation_snapshot"),
        arguments: [tx.object(params.poolVaultId), stage, tx.object(params.protocolConfigId)],
    });
    tx.moveCall({
        target: target("plp", "finish_flush"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.pure(bcs.option(bcs.u64()).serialize(null)),
            tx.pure(bcs.option(bcs.u64()).serialize(null)),
        ],
    });
    return tx;
}

// The keeper's pool-flush SEQUENCE: snapshot every active market atomically, then value
// each one in its own transaction, then finish. The durable settlement lane
// (keeperSettleTx) runs first and sweeps markets past-expiry then; `settlements` here
// are only the boundary-race STRAGGLERS that expired since. Their exact-expiry
// observations are inserted and explicitly settled before the snapshot in the SAME
// transaction — `try_settle` refuses a market once `snapshot_expiry_pricer` stamps it,
// so the settle commands run earlier in this PTB than the stamping commands do.
// These commands are race-avoidance, not the durable path: a BS outage aborts the
// snapshot PTB (reverting them), but the settlement lane already settled durably, so no
// brick. Live-market valuation reads the updater-maintained fresh BS feed via the
// snapshot; a market that expires mid-flush is still valued off its frozen pricer and
// settles on the next settlement pass.
export function keeperFlushTxs(params: {
    feeds: OracleFeedIds;
    marketIds: string[];
    poolVaultId: string;
    protocolConfigId: string;
    lifecycleCapId: string;
    settlements: { marketId: string; expiryMs: bigint; price: bigint }[];
}): Transaction[] {
    // 1. Stragglers settle, then the atomic snapshot stage. Everything from
    //    `start_pool_valuation` to `seal_valuation_snapshot` is one transaction because
    //    the `SnapshotStage` potato cannot leave it.
    const snapshotTx = new Transaction();
    for (const s of params.settlements) {
        addPythFeedInsert(snapshotTx, params.feeds.pythFeedId, s.price, s.expiryMs);
        addTrySettle(snapshotTx, {
            marketId: s.marketId,
            protocolConfigId: params.protocolConfigId,
            pythFeedId: params.feeds.pythFeedId,
            bsValueStoreId: params.feeds.bsValueStoreId,
        });
    }
    const proof = snapshotTx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [snapshotTx.object(REGISTRY_ID), snapshotTx.object(params.lifecycleCapId)],
    });
    const stage = snapshotTx.moveCall({
        target: target("plp", "start_pool_valuation"),
        arguments: [
            snapshotTx.object(params.protocolConfigId),
            snapshotTx.object(params.poolVaultId),
            proof,
            snapshotTx.object(CLOCK_ID),
        ],
    });
    for (const marketId of params.marketIds) {
        snapshotTx.moveCall({
            target: target("plp", "snapshot_expiry_pricer"),
            arguments: [
                snapshotTx.object(params.poolVaultId),
                stage,
                snapshotTx.object(marketId),
                snapshotTx.object(params.protocolConfigId),
                snapshotTx.object(ORACLE_REGISTRY_ID),
                snapshotTx.object(params.feeds.pythFeedId),
                snapshotTx.object(params.feeds.bsValueStoreId),
                snapshotTx.object(params.feeds.bsSviStoreId),
                snapshotTx.object(CLOCK_ID),
            ],
        });
    }
    snapshotTx.moveCall({
        target: target("plp", "seal_valuation_snapshot"),
        arguments: [
            snapshotTx.object(params.poolVaultId),
            stage,
            snapshotTx.object(params.protocolConfigId),
        ],
    });

    // 2. One transaction per market — the split the per-market node cap assumes: only
    //    `value_expiry` walks payout trees, so each transaction carries one market's
    //    dynamic-field children instead of the pool's.
    const valuationTxs = params.marketIds.map((expiryMarketId) =>
        valueExpiryTx({
            poolVaultId: params.poolVaultId,
            protocolConfigId: params.protocolConfigId,
            expiryMarketId,
        }),
    );

    // 3. Finish and drain at the frozen mark, in its own transaction.
    const finishTx = finishFlushTx(params);

    return [snapshotTx, ...valuationTxs, finishTx];
}

// Discard an in-flight flush immediately on the lifecycle authority. The valuation lock
// is held across transactions now, so a keeper that dies between the snapshot stage and
// `finish_flush` leaves the whole mutation surface frozen; this is the operator's
// escape. (Anyone may run the permissionless `plp::abort_valuation` once the flush has
// been in flight past `max_valuation_window_ms`; the keeper holds the cap, so it never
// needs to wait.)
export function abortValuationTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    lifecycleCapId: string;
}): Transaction {
    const tx = new Transaction();
    const proof = tx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [tx.object(REGISTRY_ID), tx.object(params.lifecycleCapId)],
    });
    tx.moveCall({
        target: target("plp", "abort_valuation_privileged"),
        arguments: [tx.object(params.poolVaultId), tx.object(params.protocolConfigId), proof],
    });
    return tx;
}

// Settle ONE expired market in its own PTB (decoupled from the flush): insert its exact-expiry Pyth
// observation, call try_settle, then rebalance_expiry_cash to sweep the settled market from
// active_expiry_markets. Needs only the exact Pyth spot, NOT
// live BS pricing, so it proceeds even while the flush defers on a BS outage — no settlement backlog,
// no beyond-retention brick. Mirrors the production keeper's settlement lane (deepbook-services
// decision 0010). Per-market so one bad market's settle fails alone.
export function keeperSettleTx(params: {
    pythFeedId: string;
    bsValueStoreId: string;
    expiryMs: bigint;
    price: bigint;
    marketId: string;
    poolVaultId: string;
    protocolConfigId: string;
}): Transaction {
    const tx = new Transaction();
    addPythFeedInsert(tx, params.pythFeedId, params.price, params.expiryMs);
    addTrySettle(tx, {
        marketId: params.marketId,
        protocolConfigId: params.protocolConfigId,
        pythFeedId: params.pythFeedId,
        bsValueStoreId: params.bsValueStoreId,
    });
    tx.moveCall({
        target: target("plp", "rebalance_expiry_cash"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.marketId),
            tx.object(params.protocolConfigId),
            tx.object(CLOCK_ID),
        ],
    });
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

export async function refreshOracleAndMintTxs(
    params: OracleRefreshParams & MintParams,
): Promise<Transaction[]> {
    return refreshThen(params, (tx) => addMint(tx, params));
}

export async function refreshOracleAndRedeemTxs(
    params: OracleRefreshParams & RedeemParams,
): Promise<Transaction[]> {
    return refreshThen(params, (tx) => addRedeem(tx, params));
}

// Mint test DUSDC and transfer it to `toAddress`. The TreasuryCap is owned by the
// publisher, so this is how the keeper (publisher) funds trader addresses, which cannot
// self-mint.
export function fundAddressDusdcTx(toAddress: string, amount: bigint): Transaction {
    const tx = new Transaction();
    const coin = mintDusdc(tx, amount);
    tx.transferObjects([coin], tx.pure.address(toAddress));
    return tx;
}

// Deposit a coin the account owner already holds (e.g. one the keeper transferred) into
// the account's stored balance, rather than minting fresh DUSDC.
export function depositOwnedCoinTx(wrapperId: string, coinId: string): Transaction {
    const tx = new Transaction();
    const auth = generateAuth(tx);
    tx.moveCall({
        target: accountTarget("account", "deposit_funds"),
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(wrapperId), auth, tx.object(coinId), tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
    });
    return tx;
}

// Mint-only PTB (no oracle refresh): the trader prices against the updater-maintained
// fresh feed via load_live_pricer.
export function mintTx(params: MintParams): Transaction {
    const tx = new Transaction();
    addMint(tx, params);
    return tx;
}

// Batched mint-only PTB: N `mint_exact_quantity` calls in ONE transaction, each pricing against the
// updater-maintained fresh feed (no oracle refresh, like `mintTx`). The whole PTB reports ONE
// `computationCost` — the `#cap-mintbatch` measurement vehicle: a batched mint is amplified
// by transaction-level metering versus a standalone mint (see RP-10). Vary N to isolate the
// cause via the total cost.
export function mintBatchTx(mints: MintParams[]): Transaction {
    if (mints.length === 0) throw new Error("mintBatchTx requires at least one mint");
    const tx = new Transaction();
    for (const mint of mints) addMint(tx, mint);
    return tx;
}

// Live redeem-only PTB (no oracle refresh).
export function redeemTx(params: RedeemParams): Transaction {
    const tx = new Transaction();
    addRedeem(tx, params);
    return tx;
}

// Per-sender gas-coin threading. The gas coin's version bumps on every transaction, so the effects
// return is the version authority. Track its remaining balance from the selected payment and gas
// effects; before it falls below the next budget, merge fresh faucet coins into that exact pinned
// reference. This avoids both stale-version rebuild races and one sacrificial gas-depletion reject.
// A MoveAbort still executes and advances the pin. A submission reject drops all local pin state.
// Every actor awaits its transactions, so there is no sender-local equivocation.
const gasRefBySender = new Map<string, { objectId: string; version: string; digest: string }>();
const gasBalanceBySender = new Map<string, bigint>();

export async function signExecThreaded(tx: Transaction, txSigner: any, options: any = {}): Promise<any> {
    const sender = txSigner.getPublicKey().toSuiAddress();
    let r: any;
    try {
        const pinned = gasRefBySender.get(sender);
        const pinnedBalance = gasBalanceBySender.get(sender);
        const budget = (tx.getData() as any).gasData?.budget;
        if (pinned && pinnedBalance !== undefined && budget !== null && budget !== undefined) {
            const plan = await extendPinnedGasPayment({
                tx,
                owner: sender,
                pinned,
                pinnedBalance,
                budget: BigInt(budget),
            });
            tx.setGasPayment(plan.payment);
            gasBalanceBeforeByTransaction.set(tx, plan.balance);
        } else if (pinned) {
            gasRefBySender.delete(sender);
            gasBalanceBySender.delete(sender);
        }
        r = await signAndExecuteGrpc(tx, txSigner, { ...options, effects: true });
    } catch (error) {
        gasRefBySender.delete(sender);
        gasBalanceBySender.delete(sender);
        throw error;
    }
    const gasObject = (r as any).effects?.gasObject;
    const balanceBefore = gasBalanceBeforeByTransaction.get(tx);
    if (
        gasObject?.objectId &&
        gasObject?.outputVersion &&
        gasObject?.outputDigest &&
        balanceBefore !== undefined
    ) {
        gasRefBySender.set(sender, {
            objectId: gasObject.objectId,
            version: String(gasObject.outputVersion),
            digest: gasObject.outputDigest,
        });
        gasBalanceBySender.set(
            sender,
            balanceBefore - netGasCharge((r as any).effects?.gasUsed),
        );
    } else {
        gasRefBySender.delete(sender);
        gasBalanceBySender.delete(sender);
    }
    return r;
}

export async function executeWithSignerAndWait(
    tx: Transaction,
    txSigner: any,
    label = "transaction",
    gasBudget: number | bigint = gasBudgetFromEnv(),
    options: any = TRANSACTION_INCLUDE,
): Promise<any> {
    const sender = txSigner.getPublicKey().toSuiAddress();
    const artifactGasBudget = BigInt(gasBudget);
    tx.setSender(sender);
    tx.setGasBudget(gasBudget);

    let execution: any;
    try {
        execution = await signExecThreaded(tx, txSigner, options);
    } catch (error) {
        const artifactPath = await tryCollectTransactionDebug({
            tx,
            transactionBytes: submittedTransactionBytes.get(tx) ?? null,
            sender,
            label,
            attempt: 0,
            gasBudget: artifactGasBudget,
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
            transactionBytes: submittedTransactionBytes.get(tx) ?? null,
            sender,
            label,
            attempt: 0,
            gasBudget: artifactGasBudget,
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
        return await getTransactionWithRetry(execution.digest);
    } catch (error) {
        const artifactPath = await tryCollectTransactionDebug({
            tx,
            transactionBytes: submittedTransactionBytes.get(tx) ?? null,
            sender,
            label,
            attempt: 0,
            gasBudget: artifactGasBudget,
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

export async function executeAndWait(
    tx: Transaction,
    label = "transaction",
    gasBudget: number | bigint = gasBudgetFromEnv(),
): Promise<any> {
    return executeWithSignerAndWait(tx, signer, label, gasBudget);
}

const EXECUTE_MAX_ATTEMPTS = 5;
const EXECUTE_RETRY_DELAY_MS = 1000;

type BuiltTx = Transaction | Transaction[];
type BuildTx = BuiltTx | (() => BuiltTx | Promise<BuiltTx>);

export async function execute(
    buildTx: BuildTx,
    label = "transaction",
    gasBudget = gasBudgetFromEnv(),
): Promise<ExecutionReceipt> {
    let lastError: unknown;
    // Completed legs survive retry attempts: a stateful sequence (the staged
    // flush) must never re-run an already-committed leg — resubmitting
    // start_pool_valuation after it landed aborts EValuationInProgress and
    // masks the transient error that triggered the retry. Legs are rebuilt
    // deterministically, so resuming by index is sound.
    const receipts: ExecutionReceipt[] = [];
    for (let attempt = 0; attempt < EXECUTE_MAX_ATTEMPTS; attempt++) {
        let tx: Transaction | null = null;
        let raw: any = null;
        try {
            // Build a fresh transaction on each attempt so object versions are re-resolved.
            const built = typeof buildTx === "function" ? await buildTx() : buildTx;
            const txs = Array.isArray(built) ? built : [built];
            if (txs.length === 0) {
                throw new Error(`${label}: execute requires at least one transaction`);
            }

            for (const [index, builtTx] of txs.entries()) {
                if (index < receipts.length) continue; // committed in a prior attempt
                tx = builtTx;
                const legLabel =
                    txs.length === 1 ? label : `${label} (${index + 1}/${txs.length})`;
                tx.setSender(address);
                tx.setGasBudget(gasBudget);

                raw = await signAndExecuteGrpc(tx, signer, TRANSACTION_INCLUDE);

                const status = raw.effects?.status;
                if (!isSuccessStatus(status)) {
                    const artifactPath = await tryCollectTransactionDebug({
                        tx,
                        transactionBytes: submittedTransactionBytes.get(tx) ?? null,
                        label: legLabel,
                        attempt,
                        gasBudget,
                        phase: "execution_failure",
                        raw,
                    });
                    throw markFailedTransactionLogged(
                        new Error(
                            `${legLabel} failed: ${formatStatusError(status, JSON.stringify(raw).slice(0, 300))}${failedTransactionSuffix(artifactPath)}`,
                        ),
                    );
                }

                let settled: any;
                try {
                    settled = await getTransactionWithRetry(raw.digest);
                } catch (error) {
                    const artifactPath = await tryCollectTransactionDebug({
                        tx,
                        transactionBytes: submittedTransactionBytes.get(tx) ?? null,
                        label: legLabel,
                        attempt,
                        gasBudget,
                        phase: "post_submit_fetch_error",
                        raw,
                        error,
                    });
                    throw markFailedTransactionLogged(
                        new Error(
                            `${legLabel} post-submit fetch failure digest=${raw.digest}: ${String(error)}${failedTransactionSuffix(artifactPath)}`,
                        ),
                    );
                }
                receipts.push({
                    digest: raw.digest,
                    clockTimestampMs: settled.clockTimestampMs,
                    gas: gasSummaryFromEffects(settled.effects ?? raw.effects),
                    events: settled.events ?? raw.events ?? [],
                    objectChanges: settled.objectChanges ?? raw.objectChanges ?? [],
                    effects: settled.effects ?? raw.effects,
                });
            }

            return combineExecutionReceipts(receipts);
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
                        transactionBytes: tx ? submittedTransactionBytes.get(tx) ?? null : null,
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
                transactionBytes: tx ? submittedTransactionBytes.get(tx) ?? null : null,
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
