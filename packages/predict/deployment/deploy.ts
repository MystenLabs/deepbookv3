// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/**
 * Publish and fully configure an independent Predict deployment on Sui Testnet.
 *
 * A run publishes fixed_math, account, propbook, predict, deepbook_core_account,
 * and sessions; authorizes their apps; creates and binds the oracle objects;
 * stores the cadence policy on-chain; bootstraps the pool; creates and funds the initial market windows;
 * and party-transfers the lifecycle capability to the keeper operator. Resumable,
 * operator-only progress is written to deployment.testnet.state.json. After a
 * successful Testnet audit, the script derives the committed
 * deployment.testnet.json integration manifest from that verified state.
 *
 * The default invocation is non-broadcasting:
 *   SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts
 *
 * Broadcast only from a committed deployment branch:
 *   SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --execute
 *
 * Package publication keeps Sui dependency verification enabled. Preflight
 * compiles with warnings denied and proves that every resolved dependency ID is
 * the expected Testnet package.
 */
import { execFileSync } from "node:child_process";
import {
    chmodSync,
    closeSync,
    copyFileSync,
    cpSync,
    existsSync,
    mkdtempSync,
    openSync,
    readdirSync,
    readFileSync,
    realpathSync,
    renameSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomUUID } from "node:crypto";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import {
    coinWithBalance,
    Transaction,
    TransactionDataBuilder,
    type TransactionArgument,
    type TransactionResult,
} from "@mysten/sui/transactions";
import { fromBase58, fromBase64, toHex } from "@mysten/sui/utils";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..", "..");
export const STATE_RELATIVE = "packages/predict/deployment/deployment.testnet.state.json";
export const MANIFEST_RELATIVE = "packages/predict/deployment/deployment.testnet.json";
const STATE = resolve(REPO_ROOT, STATE_RELATIVE);
const STATE_TEMP = `${STATE}.tmp`;
const MANIFEST = resolve(REPO_ROOT, MANIFEST_RELATIVE);
const MANIFEST_TEMP = `${MANIFEST}.tmp`;
const SUI = process.env.SUI_BINARY ?? "sui";
const PACKAGE_GAS_BUDGET = process.env.PACKAGE_GAS_BUDGET ?? "5000000000";
const TRANSACTION_GAS_BUDGET = BigInt(process.env.TRANSACTION_GAS_BUDGET ?? "1000000000");
const NETWORK = "testnet";
const CHAIN_ID = "4c78adac";
const DEPLOYMENT = "predict-testnet-8-21";
const DEPLOYER = "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef";
const LIFECYCLE_CAP_RECIPIENT =
    "0xff241a369609060d3f34828b97a47a2d330644615ff57dfdd49f4f0dd299207f";
const SUI_VERSION = "sui 1.77.1-4e476c5c8184";
const OBJECT_ID = /^0x[0-9a-f]{64}$/;
const CLOCK_ID = "0x0000000000000000000000000000000000000000000000000000000000000006";
const ACCUMULATOR_ROOT_ID = "0x0000000000000000000000000000000000000000000000000000000000000acc";
const DEEPBOOK_REGISTRY = "0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1";
const DEEPBOOK_ADMIN_CAP = "0x29a62a5385c549dd8e9565312265d2bda0b8700c1560b3e34941671325daae77";
const DEEPBOOK_ADMIN_OWNER = "0xb3d277c50f7b846a5f609a8d13428ae482b5826bb98437997373f3a0d60d280e";
const DEEPBOOK_ORIGINAL = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const MARKET_ROLLOVER_RESERVE_PER_CADENCE = 2;

const PACKAGES = [
    "fixed_math",
    "account",
    "propbook",
    "predict",
    "deepbook_core_account",
    "sessions",
] as const;
type PackageName = (typeof PACKAGES)[number];

export interface DeploymentMode {
    execute: boolean;
    sessions: false;
    smoke: false;
}

const LINKED = {
    deepbook: "0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24",
    dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
    deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
    pyth_lazer: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
    wormhole: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
    bs_oracle: "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
    bs_sid: "0x6a54299d593fca24edf6b17bf8c3aff0b7ba8bc8f4276e9c1065689c50223bba",
} as const;

const LINKED_OBJECTS = {
    clock: CLOCK_ID,
    accumulatorRoot: ACCUMULATOR_ROOT_ID,
    pythLazerState: "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
    wormholeState: "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
    blockScholesSignerRegistry:
        "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
    deepbookRegistry: DEEPBOOK_REGISTRY,
} as const;

const EXPECTED_SHARED: Record<PackageName, readonly string[]> = {
    fixed_math: [],
    account: ["account_registry::AccountRegistry"],
    propbook: ["registry::OracleRegistry"],
    predict: ["plp::PoolVault", "protocol_config::ProtocolConfig", "registry::Registry"],
    deepbook_core_account: [],
    sessions: ["session_config::SessionsConfig"],
};

const DUSDC_SCALING = 1_000_000n;
const LOCK_CAPITAL_AMOUNT = 10n * DUSDC_SCALING;
const BOOTSTRAP_SUPPLY_AMOUNT = 1_500_000n * DUSDC_SCALING;
const ASSET = {
    name: "BTC_USD",
    propbookUnderlyingId: 1,
    pythLazerFeedId: 1,
    blockScholesSourceId: 1,
    blockScholesBaseAsset: "BTC",
} as const;

interface CadenceSpec {
    id: number;
    name: string;
    periodMs: number;
    tickSize: bigint;
    admissionTickSize: bigint;
    maxExpiryAllocation: bigint;
    initialExpiryCash: bigint;
    windowSize: bigint;
    marketsToCreate: number;
}

export const CADENCES: readonly CadenceSpec[] = [
    {
        id: 0,
        name: "1m",
        periodMs: 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 50_000n * DUSDC_SCALING,
        initialExpiryCash: 10_000n * DUSDC_SCALING,
        windowSize: 2n,
        marketsToCreate: 2,
    },
    {
        id: 1,
        name: "5m",
        periodMs: 5 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 50_000n * DUSDC_SCALING,
        initialExpiryCash: 10_000n * DUSDC_SCALING,
        windowSize: 2n,
        marketsToCreate: 2,
    },
    {
        id: 2,
        name: "1h",
        periodMs: 60 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 250_000n * DUSDC_SCALING,
        initialExpiryCash: 50_000n * DUSDC_SCALING,
        windowSize: 2n,
        marketsToCreate: 2,
    },
    {
        id: 3,
        name: "1d",
        periodMs: 24 * 60 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 100_000_000_000n,
        maxExpiryAllocation: 250_000n * DUSDC_SCALING,
        initialExpiryCash: 50_000n * DUSDC_SCALING,
        windowSize: 2n,
        marketsToCreate: 2,
    },
    {
        id: 4,
        name: "1w",
        periodMs: 7 * 24 * 60 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 100_000_000_000n,
        maxExpiryAllocation: 250_000n * DUSDC_SCALING,
        initialExpiryCash: 50_000n * DUSDC_SCALING,
        windowSize: 2n,
        marketsToCreate: 2,
    },
    {
        id: 5,
        name: "1mo",
        periodMs: 30 * 24 * 60 * 60_000,
        tickSize: 0n,
        admissionTickSize: 0n,
        maxExpiryAllocation: 0n,
        initialExpiryCash: 0n,
        windowSize: 0n,
        marketsToCreate: 0,
    },
] as const;

export const EXPECTED_PROTOCOL_CONFIG: ProtocolConfigRecord = {
    usePythSpotForForward: true,
    pythSpotFreshnessMs: "10000",
    blockScholesPriceFreshnessMs: "10000",
    blockScholesSviFreshnessMs: "60000",
    ewmaAlpha: "10000000",
    ewmaZScoreThreshold: "3000000000",
    ewmaPenaltyRate: "1000000",
    ewmaEnabled: false,
    protocolReserveProfitShare: "100000000",
    referralFeeRate: "100000000",
    plpSupplyFeeRate: "0",
    plpWithdrawFeeRate: "2000000",
    lpRequestLimitFlushAttempts: "1",
    maxLpPoolValue: "18446744073709551615",
    backingBufferLambda: "310000000",
    inventoryImpactMaxRate: "0",
    baseFee: "100000000",
    minFee: "22000000",
    minEntryProbability: "10000000",
    maxEntryProbability: "990000000",
    expiryFeeWindowMs: "86400000",
    expiryFeeMaxMultiplier: "1000000000",
    versionWatermark: "1",
    tradingPaused: false,
    frozen: false,
    valuationInProgress: false,
};

interface ObjectChange {
    type?: string;
    packageId?: string;
    objectId?: string;
    objectType?: string;
    owner?: unknown;
}

interface EventRecord {
    type?: string;
    parsedJson?: unknown;
}

export interface Receipt {
    digest?: string;
    effects?: unknown;
    objectChanges?: ObjectChange[] | null;
    events?: EventRecord[] | null;
}

export interface InFlight {
    kind: "publish" | "transaction";
    label: string;
    package: PackageName | null;
    startedAt: string;
    digest: string | null;
}

interface ObjectEvidence {
    objectId: string;
    type: string;
    owner: string;
    version: string;
    digest: string;
    previousTransaction: string | null;
}

export interface PublishedPackageMetadata {
    packageVersion: string;
    modules: Record<string, string>;
    linkage: Array<{
        originalId: string;
        upgradedId: string;
        upgradedVersion: string;
    }>;
    typeOrigins: Array<{
        module: string;
        datatype: string;
        packageId: string;
    }>;
}

export interface CompiledPackageMetadata {
    modules: string[];
    dependencies: string[];
    typeOrigins: Array<{
        module: string;
        datatype: string;
    }>;
}

interface CadenceRecord {
    id: number;
    name: string;
    tickSize: string;
    admissionTickSize: string;
    maxExpiryAllocation: string;
    initialExpiryCash: string;
    windowSize: string;
    setTx: string | null;
}

interface MarketRecord {
    id: string;
    cadenceId: number;
    cadence: string;
    expiryMs: string;
    tickSize: string;
    admissionTickSize: string;
    maxExpiryAllocation: string;
    initialExpiryCash: string;
    createTx: string | null;
    rebalanceTx: string | null;
    cashBalance: string | null;
}

interface WiringState {
    version: number;
    network: string;
    operator: string;
    updatedAt: string | null;
    account: {
        predictAppAuthorized: boolean;
        authorizeTx: string | null;
        deepbookCoreAppAuthorized: boolean;
        deepbookCoreAuthorizeTx: string | null;
        sessionsAppAuthorized: boolean;
        sessionsAuthorizeTx: string | null;
        accountWrapperId: string | null;
        createAccountTx: string | null;
    };
    deepbook: {
        coreAppAuthorized: boolean;
        verifiedAt: string | null;
    };
    lifecycleCap: {
        id: string | null;
        recipient: string;
        owner: "deployer" | "recipient" | null;
        mintTx: string | null;
        transferTx: string | null;
    };
    asset: {
        name: string;
        propbookUnderlyingId: number;
        pythLazerFeedId: number;
        blockScholesSourceId: number;
        pythFeedId: string | null;
        blockScholesValueStoreId: string | null;
        blockScholesSviStoreId: string | null;
        pythFeedCreateTx: string | null;
        pythBindTx: string | null;
        blockScholesStoresCreateTx: string | null;
        predictUnderlyingRegistered: boolean;
        predictUnderlyingRegisteredTx: string | null;
    };
    cadences: CadenceRecord[];
    bootstrap: {
        lockCapitalAmount: string;
        supplyAmount: string;
        accountId: string | null;
        requestIndex: string | null;
        sharesMinted: string | null;
        accountPlpBalance: string | null;
        lockCapitalTx: string | null;
        supplyRequestTx: string | null;
        flushTx: string | null;
    };
    markets: MarketRecord[];
    marketWindowChecks: Array<{
        cadenceId: number;
        cadence: string;
        target: number;
        recorded: number;
        windowFull: boolean;
        checkedAtChainMs: string;
        checkedAt: string;
    }>;
}

interface ProtocolConfigRecord {
    usePythSpotForForward: boolean;
    pythSpotFreshnessMs: string;
    blockScholesPriceFreshnessMs: string;
    blockScholesSviFreshnessMs: string;
    ewmaAlpha: string;
    ewmaZScoreThreshold: string;
    ewmaPenaltyRate: string;
    ewmaEnabled: boolean;
    protocolReserveProfitShare: string;
    referralFeeRate: string;
    plpSupplyFeeRate: string;
    plpWithdrawFeeRate: string;
    lpRequestLimitFlushAttempts: string;
    maxLpPoolValue: string;
    backingBufferLambda: string;
    inventoryImpactMaxRate: string;
    baseFee: string;
    minFee: string;
    minEntryProbability: string;
    maxEntryProbability: string;
    expiryFeeWindowMs: string;
    expiryFeeMaxMultiplier: string;
    versionWatermark: string;
    tradingPaused: boolean;
    frozen: boolean;
    valuationInProgress: boolean;
}

interface Verification {
    verifiedAt: string;
    chainId: string;
    indexingStartCheckpoint: string;
    verifiedAfterCheckpoint: string | null;
    packages: Record<string, ObjectEvidence>;
    linkedPackages: Record<string, ObjectEvidence>;
    linkedObjects: Record<string, ObjectEvidence>;
    sharedObjects: Record<string, Record<string, ObjectEvidence>>;
    ownedCaps: Record<string, Record<string, ObjectEvidence>>;
    oracleObjects: Record<string, ObjectEvidence>;
    account: {
        predictAppAuthorized: boolean;
        deepbookCoreAppAuthorized: boolean;
        sessionsAppAuthorized: boolean;
        deepbookCoreAuthorized: boolean;
        accountWrapper: ObjectEvidence;
    };
    lifecycleCap: ObjectEvidence;
    cadences: CadenceRecord[];
    protocolConfig: ProtocolConfigRecord;
    pool: {
        totalSupply: string;
        idleBalance: string;
        supplyRequestsPending: string;
        withdrawRequestsPending: string;
        activeMarketIds: string[];
        activeMarketCash: string;
        deployerAccountPlpBalance: string;
    };
    markets: MarketRecord[];
}

export interface DeploymentResult {
    schemaVersion: number;
    status:
        | "pending"
        | "publishing"
        | "wiring"
        | "verifying"
        | "handoff"
        | "partial"
        | "failed"
        | "ambiguous"
        | "complete";
    network: string;
    chainId: string;
    buildEnvironment: string;
    suiVersion: string | null;
    suiBinaryPath: string | null;
    suiBinaryDigest: string | null;
    rpcUrl: string | null;
    clientConfigDigest: string | null;
    sourceCommit: string | null;
    deployer: string;
    packageGasBudget: string | null;
    transactionGasBudget: string | null;
    startedAt: string | null;
    completedAt: string | null;
    lastError: string | null;
    inFlight: InFlight | null;
    packages: Partial<Record<PackageName, string>>;
    linked: Record<string, string>;
    linkedObjects: Record<string, string>;
    sharedObjects: Partial<Record<PackageName, Record<string, string>>>;
    ownedCaps: Partial<Record<PackageName, Record<string, string>>>;
    publishTx: Partial<Record<PackageName, string>>;
    transactions: Record<string, string>;
    failedTransactions: Record<string, { digest: string; error: string; recordedAt: string }>;
    wiring: WiringState;
    verification: Verification | null;
}

const FIXED_TRANSACTION_STEPS = [
    "authorize_predict_app",
    "authorize_deepbook_core_app",
    "authorize_sessions_app",
    "mint_lifecycle_cap",
    "create_pyth_feed",
    "create_block_scholes_stores",
    "bind_pyth_to_underlying",
    "register_predict_underlying",
    "set_cadence_configs",
    "create_deployer_account",
    "bootstrap_pool",
    "transfer_lifecycle_cap_to_keeper",
] as const;

export function plannedTransactionSteps(): string[] {
    const marketSteps = CADENCES.flatMap((cadence) =>
        Array.from({ length: cadence.marketsToCreate }, (_, index) => [
            `create_market_${cadence.name}_${index}`,
            `rebalance_market_${cadence.name}_${index}`,
        ]).flat(),
    );
    return [
        ...FIXED_TRANSACTION_STEPS.slice(0, -1),
        ...marketSteps,
        FIXED_TRANSACTION_STEPS.at(-1)!,
    ];
}

export function plannedTransactionCount(): number {
    return plannedTransactionSteps().length;
}

export function maximumTransactionCountPerRun(): number {
    const marketTransactions = CADENCES.reduce(
        (total, cadence) =>
            total +
            (cadence.marketsToCreate === 0
                ? 0
                : (cadence.marketsToCreate + MARKET_ROLLOVER_RESERVE_PER_CADENCE) * 2),
        0,
    );
    return FIXED_TRANSACTION_STEPS.length + marketTransactions;
}

export function irreversibleDeploymentSteps(): string[] {
    return [...PACKAGES.map((pkg) => `publish_${pkg}`), ...plannedTransactionSteps()];
}

export interface IntegrationManifest {
    schemaVersion: 6;
    deployment: string;
    network: string;
    chainId: string;
    sourceCommit: string;
    packages: {
        fixedMath: string;
        account: string;
        propbook: string;
        predict: string;
        deepbookCoreAccount: string;
        sessions: string;
    };
    coinTypes: {
        dusdc: string;
        deep: string;
        plp: string;
    };
    objects: {
        accountRegistry: string;
        oracleRegistry: string;
        protocolConfig: string;
        poolVault: string;
        registry: string;
        sessionsConfig: string;
        deepbookRegistry: string;
        accumulatorRoot: string;
        clock: string;
    };
    underlyings: {
        BTC: {
            symbol: "BTC";
            name: string;
            propbookUnderlyingId: number;
            pythLazerFeedId: number;
            blockScholesSourceId: number;
            pythFeed: string;
            blockScholesValueStore: string;
            blockScholesSviStore: string;
        };
    };
    writers: {
        keeper: {
            lifecycleCap: string;
        };
        priceUpdater: {
            pythLazerPackage: string;
            pythLazerState: string;
            blockScholesOraclePackage: string;
            blockScholesSignerRegistry: string;
        };
    };
    externalAuthorizations: {
        deepbookCoreAccount: {
            authorized: boolean;
            appType: string;
            registry: string;
        };
    };
    indexing: {
        startCheckpoint: string;
    };
    initialConfiguration: {
        verifiedAfterCheckpoint: string;
        stateAnchors: {
            protocolConfig: {
                objectVersion: string;
                digest: string;
            };
            registry: {
                objectVersion: string;
                digest: string;
            };
            oracleRegistry: {
                objectVersion: string;
                digest: string;
            };
            sessionsConfig: {
                objectVersion: string;
                digest: string;
            };
            deepbookRegistry: {
                objectVersion: string;
                digest: string;
            };
        };
        units: {
            fixedPointScale: string;
            quoteCoinDecimals: number;
            plpCoinDecimals: number;
            deepCoinDecimals: number;
            positionQuantityDecimals: number;
            positionLotSize: string;
            timestampUnit: "milliseconds";
        };
        liveProtocol: {
            pricing: {
                usePythSpotForForward: boolean;
                pythSpotFreshnessMs: string;
                blockScholesPriceFreshnessMs: string;
                blockScholesSviFreshnessMs: string;
            };
            ewmaPenalty: {
                alpha: string;
                zScoreThreshold: string;
                penaltyRate: string;
                enabled: boolean;
            };
            protocolReserveProfitShare: string;
            referralFeeRate: string;
            plpSupplyFeeRate: string;
            plpWithdrawFeeRate: string;
            lpRequestLimitFlushAttempts: string;
            maxLpPoolValue: string;
        };
        futureMarketTemplate: {
            backingBufferLambda: string;
            inventoryImpactMaxRate: string;
            baseFee: string;
            minFee: string;
            minEntryProbability: string;
            maxEntryProbability: string;
            expiryFeeWindowMs: string;
            expiryFeeMaxMultiplier: string;
        };
        cadences: {
            BTC: Array<{
                id: number;
                name: string;
                periodMs: string;
                enabled: boolean;
                tickSize: string;
                admissionTickSize: string;
                maxExpiryAllocation: string;
                initialExpiryCash: string;
                windowSize: string;
            }>;
        };
    };
}

interface ClientSnapshot {
    directory: string;
    configPath: string;
    rpcUrl: string;
    keystorePath: string;
    configDigest: string;
}

interface Runtime {
    result: DeploymentResult;
    snapshot: ClientSnapshot;
    client: SuiGrpcClient;
    signer: Ed25519Keypair;
    sourceCommit: string;
    packageMetadataCache: Map<string, PublishedPackageMetadata>;
    marketCreationsThisRun: Record<number, number>;
}

interface LockHandle {
    path: string;
    token: string;
}

class DryRunFailure extends Error {
    constructor(
        label: string,
        readonly detail: string,
    ) {
        super(`${label} dry run failed: ${detail}`);
    }
}

function asRecord(value: unknown): Record<string, unknown> {
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function requiredString(value: unknown, label: string): string {
    if (typeof value !== "string" || value.length === 0) {
        throw new Error(`${label} is missing`);
    }
    return value;
}

function requiredObjectId(value: unknown, label: string): string {
    const raw = requiredString(value, label);
    const id = normalizeId(raw);
    if (!OBJECT_ID.test(raw) || raw !== id) {
        throw new Error(`${label} is not a normalized Sui object ID`);
    }
    return id;
}

function exactKeys(
    value: Record<string, unknown>,
    expected: readonly string[],
    label: string,
): void {
    const actual = Object.keys(value).sort();
    const wanted = [...expected].sort();
    if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
        throw new Error(`${label} keys are ${actual.join(", ")}, expected ${wanted.join(", ")}`);
    }
}

function decimalString(value: unknown, label: string): string {
    const raw = requiredString(value, label);
    if (!/^(0|[1-9][0-9]*)$/.test(raw)) throw new Error(`${label} is not an unsigned integer`);
    return raw;
}

export function buildIntegrationManifest(result: DeploymentResult): IntegrationManifest {
    if (
        result.status !== "complete" ||
        result.inFlight !== null ||
        !result.completedAt ||
        !result.sourceCommit ||
        !result.verification
    ) {
        throw new Error("integration manifest requires a complete, verified deployment state");
    }
    const verification = result.verification;
    if (verification.chainId !== CHAIN_ID) {
        throw new Error(`verified chain ${verification.chainId} is not ${CHAIN_ID}`);
    }
    const verifiedPackage = (name: PackageName): string =>
        requiredObjectId(verification.packages[name]?.objectId, `verified ${name} package`);
    const verifiedSharedEvidence = (pkg: PackageName, type: string): ObjectEvidence => {
        const evidence = verification.sharedObjects[pkg]?.[type];
        if (!evidence) throw new Error(`verified ${pkg} ${type} is missing`);
        requiredObjectId(evidence.objectId, `verified ${pkg} ${type}`);
        decimalString(evidence.version, `verified ${pkg} ${type} version`);
        requiredString(evidence.digest, `verified ${pkg} ${type} digest`);
        return evidence;
    };
    const verifiedShared = (pkg: PackageName, type: string): string =>
        verifiedSharedEvidence(pkg, type).objectId;
    const verifiedLinkedPackage = (name: keyof typeof LINKED): string =>
        requiredObjectId(verification.linkedPackages[name]?.objectId, `verified ${name} package`);
    const verifiedLinkedObject = (name: keyof typeof LINKED_OBJECTS): string =>
        requiredObjectId(verification.linkedObjects[name]?.objectId, `verified ${name} object`);
    const fixedMath = verifiedPackage("fixed_math");
    const account = verifiedPackage("account");
    const propbook = verifiedPackage("propbook");
    const predict = verifiedPackage("predict");
    const deepbookCoreAccount = verifiedPackage("deepbook_core_account");
    const sessions = verifiedPackage("sessions");
    const protocolConfigEvidence = verifiedSharedEvidence(
        "predict",
        "protocol_config::ProtocolConfig",
    );
    const registryEvidence = verifiedSharedEvidence("predict", "registry::Registry");
    const oracleRegistryEvidence = verifiedSharedEvidence("propbook", "registry::OracleRegistry");
    const sessionsConfigEvidence = verifiedSharedEvidence(
        "sessions",
        "session_config::SessionsConfig",
    );
    const deepbookRegistryEvidence = verification.linkedObjects.deepbookRegistry;
    if (!deepbookRegistryEvidence) throw new Error("verified DeepBook registry is missing");
    const protocol = verification.protocolConfig;
    if (JSON.stringify(protocol) !== JSON.stringify(EXPECTED_PROTOCOL_CONFIG)) {
        throw new Error("verified ProtocolConfig does not match the deployment policy");
    }
    const cadences = verification.cadences.map((record) => {
        const spec = CADENCES.find((candidate) => candidate.id === record.id);
        if (!spec || !cadenceMatches(record, spec)) {
            throw new Error(`verified cadence ${record.id} does not match deployment policy`);
        }
        return {
            id: record.id,
            name: record.name,
            periodMs: spec.periodMs.toString(),
            enabled: BigInt(record.windowSize) > 0n,
            tickSize: record.tickSize,
            admissionTickSize: record.admissionTickSize,
            maxExpiryAllocation: record.maxExpiryAllocation,
            initialExpiryCash: record.initialExpiryCash,
            windowSize: record.windowSize,
        };
    });
    const manifest: IntegrationManifest = {
        schemaVersion: 6,
        deployment: DEPLOYMENT,
        network: NETWORK,
        chainId: CHAIN_ID,
        sourceCommit: result.sourceCommit,
        packages: {
            fixedMath,
            account,
            propbook,
            predict,
            deepbookCoreAccount,
            sessions,
        },
        coinTypes: {
            dusdc: `${verifiedLinkedPackage("dusdc")}::dusdc::DUSDC`,
            deep: `${verifiedLinkedPackage("deep")}::deep::DEEP`,
            plp: `${predict}::plp::PLP`,
        },
        objects: {
            accountRegistry: verifiedShared("account", "account_registry::AccountRegistry"),
            oracleRegistry: verifiedShared("propbook", "registry::OracleRegistry"),
            protocolConfig: verifiedShared("predict", "protocol_config::ProtocolConfig"),
            poolVault: verifiedShared("predict", "plp::PoolVault"),
            registry: verifiedShared("predict", "registry::Registry"),
            sessionsConfig: verifiedShared("sessions", "session_config::SessionsConfig"),
            deepbookRegistry: verifiedLinkedObject("deepbookRegistry"),
            accumulatorRoot: verifiedLinkedObject("accumulatorRoot"),
            clock: verifiedLinkedObject("clock"),
        },
        underlyings: {
            BTC: {
                symbol: "BTC",
                name: ASSET.name,
                propbookUnderlyingId: ASSET.propbookUnderlyingId,
                pythLazerFeedId: ASSET.pythLazerFeedId,
                blockScholesSourceId: ASSET.blockScholesSourceId,
                pythFeed: requiredObjectId(
                    verification.oracleObjects.pythFeed?.objectId,
                    "verified Pyth feed",
                ),
                blockScholesValueStore: requiredObjectId(
                    verification.oracleObjects.blockScholesValueStore?.objectId,
                    "verified Block Scholes value store",
                ),
                blockScholesSviStore: requiredObjectId(
                    verification.oracleObjects.blockScholesSviStore?.objectId,
                    "verified Block Scholes SVI store",
                ),
            },
        },
        writers: {
            keeper: {
                lifecycleCap: requiredObjectId(
                    verification.lifecycleCap.objectId,
                    "verified lifecycle cap",
                ),
            },
            priceUpdater: {
                pythLazerPackage: verifiedLinkedPackage("pyth_lazer"),
                pythLazerState: verifiedLinkedObject("pythLazerState"),
                blockScholesOraclePackage: verifiedLinkedPackage("bs_oracle"),
                blockScholesSignerRegistry: verifiedLinkedObject("blockScholesSignerRegistry"),
            },
        },
        externalAuthorizations: {
            deepbookCoreAccount: {
                authorized: verification.account.deepbookCoreAuthorized,
                appType: `${deepbookCoreAccount}::account_data::DeepbookCoreAccountApp`,
                registry: verifiedLinkedObject("deepbookRegistry"),
            },
        },
        indexing: {
            startCheckpoint: verification.indexingStartCheckpoint,
        },
        initialConfiguration: {
            verifiedAfterCheckpoint: requiredString(
                verification.verifiedAfterCheckpoint,
                "verification checkpoint",
            ),
            stateAnchors: {
                protocolConfig: {
                    objectVersion: protocolConfigEvidence.version,
                    digest: protocolConfigEvidence.digest,
                },
                registry: {
                    objectVersion: registryEvidence.version,
                    digest: registryEvidence.digest,
                },
                oracleRegistry: {
                    objectVersion: oracleRegistryEvidence.version,
                    digest: oracleRegistryEvidence.digest,
                },
                sessionsConfig: {
                    objectVersion: sessionsConfigEvidence.version,
                    digest: sessionsConfigEvidence.digest,
                },
                deepbookRegistry: {
                    objectVersion: deepbookRegistryEvidence.version,
                    digest: deepbookRegistryEvidence.digest,
                },
            },
            units: {
                fixedPointScale: "1000000000",
                quoteCoinDecimals: 6,
                plpCoinDecimals: 6,
                deepCoinDecimals: 6,
                positionQuantityDecimals: 6,
                positionLotSize: "10000",
                timestampUnit: "milliseconds",
            },
            liveProtocol: {
                pricing: {
                    usePythSpotForForward: protocol.usePythSpotForForward,
                    pythSpotFreshnessMs: protocol.pythSpotFreshnessMs,
                    blockScholesPriceFreshnessMs: protocol.blockScholesPriceFreshnessMs,
                    blockScholesSviFreshnessMs: protocol.blockScholesSviFreshnessMs,
                },
                ewmaPenalty: {
                    alpha: protocol.ewmaAlpha,
                    zScoreThreshold: protocol.ewmaZScoreThreshold,
                    penaltyRate: protocol.ewmaPenaltyRate,
                    enabled: protocol.ewmaEnabled,
                },
                protocolReserveProfitShare: protocol.protocolReserveProfitShare,
                referralFeeRate: protocol.referralFeeRate,
                plpSupplyFeeRate: protocol.plpSupplyFeeRate,
                plpWithdrawFeeRate: protocol.plpWithdrawFeeRate,
                lpRequestLimitFlushAttempts: protocol.lpRequestLimitFlushAttempts,
                maxLpPoolValue: protocol.maxLpPoolValue,
            },
            futureMarketTemplate: {
                backingBufferLambda: protocol.backingBufferLambda,
                inventoryImpactMaxRate: protocol.inventoryImpactMaxRate,
                baseFee: protocol.baseFee,
                minFee: protocol.minFee,
                minEntryProbability: protocol.minEntryProbability,
                maxEntryProbability: protocol.maxEntryProbability,
                expiryFeeWindowMs: protocol.expiryFeeWindowMs,
                expiryFeeMaxMultiplier: protocol.expiryFeeMaxMultiplier,
            },
            cadences: { BTC: cadences },
        },
    };
    assertIntegrationManifest(manifest);
    return manifest;
}

export function assertIntegrationManifest(value: unknown): asserts value is IntegrationManifest {
    const manifest = asRecord(value);
    exactKeys(
        manifest,
        [
            "schemaVersion",
            "deployment",
            "network",
            "chainId",
            "sourceCommit",
            "packages",
            "coinTypes",
            "objects",
            "underlyings",
            "writers",
            "externalAuthorizations",
            "indexing",
            "initialConfiguration",
        ],
        "integration manifest",
    );
    if (
        manifest.schemaVersion !== 6 ||
        manifest.deployment !== DEPLOYMENT ||
        manifest.network !== NETWORK ||
        manifest.chainId !== CHAIN_ID ||
        typeof manifest.sourceCommit !== "string" ||
        !/^[0-9a-f]{40}$/.test(manifest.sourceCommit)
    ) {
        throw new Error(`${MANIFEST_RELATIVE} has invalid deployment identity`);
    }
    const packages = asRecord(manifest.packages);
    exactKeys(
        packages,
        ["fixedMath", "account", "propbook", "predict", "deepbookCoreAccount", "sessions"],
        "packages",
    );
    for (const [name, id] of Object.entries(packages)) requiredObjectId(id, `packages.${name}`);

    const coinTypes = asRecord(manifest.coinTypes);
    exactKeys(coinTypes, ["dusdc", "deep", "plp"], "coinTypes");
    if (
        coinTypes.dusdc !== `${LINKED.dusdc}::dusdc::DUSDC` ||
        coinTypes.deep !== `${LINKED.deep}::deep::DEEP` ||
        coinTypes.plp !== `${packages.predict}::plp::PLP`
    ) {
        throw new Error("coinTypes do not match the verified package identities");
    }

    const objects = asRecord(manifest.objects);
    exactKeys(
        objects,
        [
            "accountRegistry",
            "oracleRegistry",
            "protocolConfig",
            "poolVault",
            "registry",
            "sessionsConfig",
            "deepbookRegistry",
            "accumulatorRoot",
            "clock",
        ],
        "objects",
    );
    for (const [name, id] of Object.entries(objects)) requiredObjectId(id, `objects.${name}`);

    const underlyings = asRecord(manifest.underlyings);
    exactKeys(underlyings, ["BTC"], "underlyings");
    const btc = asRecord(underlyings.BTC);
    exactKeys(
        btc,
        [
            "symbol",
            "name",
            "propbookUnderlyingId",
            "pythLazerFeedId",
            "blockScholesSourceId",
            "pythFeed",
            "blockScholesValueStore",
            "blockScholesSviStore",
        ],
        "underlyings.BTC",
    );
    if (
        btc.symbol !== "BTC" ||
        btc.name !== ASSET.name ||
        btc.propbookUnderlyingId !== ASSET.propbookUnderlyingId ||
        btc.pythLazerFeedId !== ASSET.pythLazerFeedId ||
        btc.blockScholesSourceId !== ASSET.blockScholesSourceId
    ) {
        throw new Error("underlyings.BTC identity does not match the deployment policy");
    }
    for (const name of ["pythFeed", "blockScholesValueStore", "blockScholesSviStore"]) {
        requiredObjectId(btc[name], `underlyings.BTC.${name}`);
    }

    const writers = asRecord(manifest.writers);
    exactKeys(writers, ["keeper", "priceUpdater"], "writers");
    const keeper = asRecord(writers.keeper);
    exactKeys(keeper, ["lifecycleCap"], "writers.keeper");
    requiredObjectId(keeper.lifecycleCap, "writers.keeper.lifecycleCap");
    const priceUpdater = asRecord(writers.priceUpdater);
    exactKeys(
        priceUpdater,
        [
            "pythLazerPackage",
            "pythLazerState",
            "blockScholesOraclePackage",
            "blockScholesSignerRegistry",
        ],
        "writers.priceUpdater",
    );
    if (
        priceUpdater.pythLazerPackage !== LINKED.pyth_lazer ||
        priceUpdater.pythLazerState !== LINKED_OBJECTS.pythLazerState ||
        priceUpdater.blockScholesOraclePackage !== LINKED.bs_oracle ||
        priceUpdater.blockScholesSignerRegistry !== LINKED_OBJECTS.blockScholesSignerRegistry
    ) {
        throw new Error("writers.priceUpdater does not match the verified dependencies");
    }

    const externalAuthorizations = asRecord(manifest.externalAuthorizations);
    exactKeys(externalAuthorizations, ["deepbookCoreAccount"], "externalAuthorizations");
    const deepbookCoreAccount = asRecord(externalAuthorizations.deepbookCoreAccount);
    exactKeys(
        deepbookCoreAccount,
        ["authorized", "appType", "registry"],
        "externalAuthorizations.deepbookCoreAccount",
    );
    if (
        typeof deepbookCoreAccount.authorized !== "boolean" ||
        deepbookCoreAccount.appType !==
            `${packages.deepbookCoreAccount}::account_data::DeepbookCoreAccountApp` ||
        deepbookCoreAccount.registry !== objects.deepbookRegistry
    ) {
        throw new Error("externalAuthorizations.deepbookCoreAccount is invalid");
    }

    const indexing = asRecord(manifest.indexing);
    exactKeys(indexing, ["startCheckpoint"], "indexing");
    const startCheckpoint = BigInt(
        decimalString(indexing.startCheckpoint, "indexing.startCheckpoint"),
    );
    const initial = asRecord(manifest.initialConfiguration);
    exactKeys(
        initial,
        [
            "verifiedAfterCheckpoint",
            "stateAnchors",
            "units",
            "liveProtocol",
            "futureMarketTemplate",
            "cadences",
        ],
        "initialConfiguration",
    );
    const verifiedAfterCheckpoint = BigInt(
        decimalString(
            initial.verifiedAfterCheckpoint,
            "initialConfiguration.verifiedAfterCheckpoint",
        ),
    );
    if (startCheckpoint > verifiedAfterCheckpoint) {
        throw new Error("indexing.startCheckpoint is after the configuration verification fence");
    }
    const stateAnchors = asRecord(initial.stateAnchors);
    exactKeys(
        stateAnchors,
        ["protocolConfig", "registry", "oracleRegistry", "sessionsConfig", "deepbookRegistry"],
        "initialConfiguration.stateAnchors",
    );
    for (const name of [
        "protocolConfig",
        "registry",
        "oracleRegistry",
        "sessionsConfig",
        "deepbookRegistry",
    ]) {
        const anchor = asRecord(stateAnchors[name]);
        exactKeys(anchor, ["objectVersion", "digest"], `initialConfiguration.stateAnchors.${name}`);
        if (
            BigInt(
                decimalString(
                    anchor.objectVersion,
                    `initialConfiguration.stateAnchors.${name}.objectVersion`,
                ),
            ) === 0n
        ) {
            throw new Error(`initialConfiguration.stateAnchors.${name}.objectVersion is zero`);
        }
        requiredString(anchor.digest, `initialConfiguration.stateAnchors.${name}.digest`);
    }

    const units = asRecord(initial.units);
    exactKeys(
        units,
        [
            "fixedPointScale",
            "quoteCoinDecimals",
            "plpCoinDecimals",
            "deepCoinDecimals",
            "positionQuantityDecimals",
            "positionLotSize",
            "timestampUnit",
        ],
        "initialConfiguration.units",
    );
    if (
        units.fixedPointScale !== "1000000000" ||
        units.quoteCoinDecimals !== 6 ||
        units.plpCoinDecimals !== 6 ||
        units.deepCoinDecimals !== 6 ||
        units.positionQuantityDecimals !== 6 ||
        units.positionLotSize !== "10000" ||
        units.timestampUnit !== "milliseconds"
    ) {
        throw new Error("initialConfiguration.units does not match Predict units");
    }

    const live = asRecord(initial.liveProtocol);
    exactKeys(
        live,
        [
            "pricing",
            "ewmaPenalty",
            "protocolReserveProfitShare",
            "referralFeeRate",
            "plpSupplyFeeRate",
            "plpWithdrawFeeRate",
            "lpRequestLimitFlushAttempts",
            "maxLpPoolValue",
        ],
        "initialConfiguration.liveProtocol",
    );
    const pricing = asRecord(live.pricing);
    exactKeys(
        pricing,
        [
            "usePythSpotForForward",
            "pythSpotFreshnessMs",
            "blockScholesPriceFreshnessMs",
            "blockScholesSviFreshnessMs",
        ],
        "initialConfiguration.liveProtocol.pricing",
    );
    const ewma = asRecord(live.ewmaPenalty);
    exactKeys(
        ewma,
        ["alpha", "zScoreThreshold", "penaltyRate", "enabled"],
        "initialConfiguration.liveProtocol.ewmaPenalty",
    );
    const template = asRecord(initial.futureMarketTemplate);
    exactKeys(
        template,
        [
            "backingBufferLambda",
            "inventoryImpactMaxRate",
            "baseFee",
            "minFee",
            "minEntryProbability",
            "maxEntryProbability",
            "expiryFeeWindowMs",
            "expiryFeeMaxMultiplier",
        ],
        "initialConfiguration.futureMarketTemplate",
    );
    const numericConfig = [
        [pricing.pythSpotFreshnessMs, "pricing.pythSpotFreshnessMs"],
        [pricing.blockScholesPriceFreshnessMs, "pricing.blockScholesPriceFreshnessMs"],
        [pricing.blockScholesSviFreshnessMs, "pricing.blockScholesSviFreshnessMs"],
        [ewma.alpha, "ewmaPenalty.alpha"],
        [ewma.zScoreThreshold, "ewmaPenalty.zScoreThreshold"],
        [ewma.penaltyRate, "ewmaPenalty.penaltyRate"],
        [live.protocolReserveProfitShare, "liveProtocol.protocolReserveProfitShare"],
        [live.referralFeeRate, "liveProtocol.referralFeeRate"],
        [live.plpSupplyFeeRate, "liveProtocol.plpSupplyFeeRate"],
        [live.plpWithdrawFeeRate, "liveProtocol.plpWithdrawFeeRate"],
        [live.lpRequestLimitFlushAttempts, "liveProtocol.lpRequestLimitFlushAttempts"],
        [live.maxLpPoolValue, "liveProtocol.maxLpPoolValue"],
        ...Object.entries(template).map(([name, item]) => [item, `futureMarketTemplate.${name}`]),
    ] as Array<[unknown, string]>;
    for (const [item, label] of numericConfig) decimalString(item, label);
    if (typeof pricing.usePythSpotForForward !== "boolean" || typeof ewma.enabled !== "boolean") {
        throw new Error("initialConfiguration boolean values are invalid");
    }

    const cadenceGroups = asRecord(initial.cadences);
    exactKeys(cadenceGroups, ["BTC"], "initialConfiguration.cadences");
    if (!Array.isArray(cadenceGroups.BTC) || cadenceGroups.BTC.length !== CADENCES.length) {
        throw new Error("initialConfiguration.cadences.BTC must contain every cadence");
    }
    for (const [index, valueAtIndex] of cadenceGroups.BTC.entries()) {
        const valueRecord = asRecord(valueAtIndex);
        exactKeys(
            valueRecord,
            [
                "id",
                "name",
                "periodMs",
                "enabled",
                "tickSize",
                "admissionTickSize",
                "maxExpiryAllocation",
                "initialExpiryCash",
                "windowSize",
            ],
            `initialConfiguration.cadences.BTC[${index}]`,
        );
        const spec = CADENCES[index];
        if (
            valueRecord.id !== spec.id ||
            valueRecord.name !== spec.name ||
            valueRecord.periodMs !== spec.periodMs.toString() ||
            valueRecord.enabled !== spec.windowSize > 0n ||
            valueRecord.tickSize !== spec.tickSize.toString() ||
            valueRecord.admissionTickSize !== spec.admissionTickSize.toString() ||
            valueRecord.maxExpiryAllocation !== spec.maxExpiryAllocation.toString() ||
            valueRecord.initialExpiryCash !== spec.initialExpiryCash.toString() ||
            valueRecord.windowSize !== spec.windowSize.toString()
        ) {
            throw new Error(`initialConfiguration.cadences.BTC[${index}] is invalid`);
        }
    }
}

function command(executable: string, args: string[]): string {
    return execFileSync(executable, args, {
        cwd: REPO_ROOT,
        encoding: "utf8",
        maxBuffer: 256 * 1024 * 1024,
    }).trim();
}

function sha256(value: string | Buffer): string {
    return createHash("sha256").update(value).digest("hex");
}

function suiBinaryIdentity(): { path: string; digest: string } {
    const path = realpathSync(isAbsolute(SUI) ? SUI : command("which", [SUI]));
    return { path, digest: sha256(readFileSync(path)) };
}

function git(args: string[]): string {
    return command("git", args);
}

function sui(args: string[]): string {
    return command(SUI, args);
}

function suiClient(snapshot: ClientSnapshot, args: string[]): string {
    return sui([
        "client",
        "--client.config",
        snapshot.configPath,
        "--client.env",
        NETWORK,
        ...args,
    ]);
}

function transactionCheckpoint(snapshot: ClientSnapshot, digest: string): string {
    const response = JSON.parse(suiClient(snapshot, ["tx-block", digest, "--json"])) as Record<
        string,
        unknown
    >;
    return decimalString(response.checkpoint, `transaction ${digest} checkpoint`);
}

export function createDeploymentState(): DeploymentResult {
    return {
        schemaVersion: 3,
        status: "pending",
        network: NETWORK,
        chainId: CHAIN_ID,
        buildEnvironment: NETWORK,
        suiVersion: null,
        suiBinaryPath: null,
        suiBinaryDigest: null,
        rpcUrl: null,
        clientConfigDigest: null,
        sourceCommit: null,
        deployer: DEPLOYER,
        packageGasBudget: null,
        transactionGasBudget: null,
        startedAt: null,
        completedAt: null,
        lastError: null,
        inFlight: null,
        packages: {},
        linked: { ...LINKED },
        linkedObjects: { ...LINKED_OBJECTS },
        sharedObjects: {},
        ownedCaps: {},
        publishTx: {},
        transactions: {},
        failedTransactions: {},
        wiring: {
            version: 2,
            network: NETWORK,
            operator: DEPLOYER,
            updatedAt: null,
            account: {
                predictAppAuthorized: false,
                authorizeTx: null,
                deepbookCoreAppAuthorized: false,
                deepbookCoreAuthorizeTx: null,
                sessionsAppAuthorized: false,
                sessionsAuthorizeTx: null,
                accountWrapperId: null,
                createAccountTx: null,
            },
            deepbook: {
                coreAppAuthorized: false,
                verifiedAt: null,
            },
            lifecycleCap: {
                id: null,
                recipient: LIFECYCLE_CAP_RECIPIENT,
                owner: null,
                mintTx: null,
                transferTx: null,
            },
            asset: {
                name: ASSET.name,
                propbookUnderlyingId: ASSET.propbookUnderlyingId,
                pythLazerFeedId: ASSET.pythLazerFeedId,
                blockScholesSourceId: ASSET.blockScholesSourceId,
                pythFeedId: null,
                blockScholesValueStoreId: null,
                blockScholesSviStoreId: null,
                pythFeedCreateTx: null,
                pythBindTx: null,
                blockScholesStoresCreateTx: null,
                predictUnderlyingRegistered: false,
                predictUnderlyingRegisteredTx: null,
            },
            cadences: CADENCES.map((spec) => ({
                id: spec.id,
                name: spec.name,
                tickSize: spec.tickSize.toString(),
                admissionTickSize: spec.admissionTickSize.toString(),
                maxExpiryAllocation: spec.maxExpiryAllocation.toString(),
                initialExpiryCash: spec.initialExpiryCash.toString(),
                windowSize: spec.windowSize.toString(),
                setTx: null,
            })),
            bootstrap: {
                lockCapitalAmount: LOCK_CAPITAL_AMOUNT.toString(),
                supplyAmount: BOOTSTRAP_SUPPLY_AMOUNT.toString(),
                accountId: null,
                requestIndex: null,
                sharesMinted: null,
                accountPlpBalance: null,
                lockCapitalTx: null,
                supplyRequestTx: null,
                flushTx: null,
            },
            markets: [],
            marketWindowChecks: [],
        },
        verification: null,
    };
}

function loadState(): DeploymentResult {
    if (!existsSync(STATE)) return createDeploymentState();
    return JSON.parse(readFileSync(STATE, "utf8")) as DeploymentResult;
}

function writeState(result: DeploymentResult): void {
    result.wiring.updatedAt = new Date().toISOString();
    writeFileSync(STATE_TEMP, `${JSON.stringify(result, null, 4)}\n`, { mode: 0o600 });
    renameSync(STATE_TEMP, STATE);
}

function writeIntegrationManifest(manifest: IntegrationManifest): void {
    assertIntegrationManifest(manifest);
    writeFileSync(MANIFEST_TEMP, `${JSON.stringify(manifest, null, 4)}\n`, { mode: 0o644 });
    chmodSync(MANIFEST_TEMP, 0o644);
    renameSync(MANIFEST_TEMP, MANIFEST);
}

export function publishedMetadataText(packageId: string, upgradeCapability: string): string {
    const normalizedPackage = normalizeId(packageId);
    const normalizedUpgradeCapability = normalizeId(upgradeCapability);
    return `# Generated by Move
# This file contains metadata about published versions of this package in different environments
# This file SHOULD be committed to source control

[published.testnet]
chain-id = "${CHAIN_ID}"
published-at = "${normalizedPackage}"
original-id = "${normalizedPackage}"
version = 1
toolchain-version = "1.77.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${normalizedUpgradeCapability}"
`;
}

function normalizeId(id: string): string {
    const hex = id.toLowerCase().replace(/^0x/, "");
    return `0x${hex.padStart(64, "0")}`;
}

function normalizeOptionalId(value: unknown): string | null {
    return typeof value === "string" ? normalizeId(value) : null;
}

function shortType(type: string): string {
    const parts = type.split("::");
    return parts.length >= 3 ? parts.slice(1).join("::") : type;
}

function isShared(owner: unknown): boolean {
    return "Shared" in asRecord(owner);
}

function addressOwner(owner: unknown): string | null {
    return normalizeOptionalId(asRecord(owner).AddressOwner);
}

function consensusAddressOwner(owner: unknown): string | null {
    return normalizeOptionalId(asRecord(asRecord(owner).ConsensusAddressOwner).owner);
}

function partyOwnerLabel(owner: string): string {
    return `party:${normalizeId(owner)}`;
}

function ownerLabel(owner: unknown): string {
    if (isShared(owner)) return "shared";
    const partyOwner = consensusAddressOwner(owner);
    if (partyOwner) return partyOwnerLabel(partyOwner);
    const address = addressOwner(owner);
    if (address) return address;
    const ownerRecord = asRecord(owner);
    if (owner === "Immutable" || "Immutable" in ownerRecord) return "immutable";
    const objectOwner = normalizeOptionalId(ownerRecord.ObjectOwner);
    return objectOwner ? `object:${objectOwner}` : JSON.stringify(owner);
}

function expectedCaps(pkg: PackageName, packageId: string): string[] {
    switch (pkg) {
        case "fixed_math":
            return ["package::UpgradeCap"];
        case "account":
            return ["account_registry::AccountAdminCap", "package::UpgradeCap"];
        case "propbook":
            return ["package::UpgradeCap", "registry::RegistryAdminCap"];
        case "predict":
            return [
                "admin::AdminCap",
                `coin_registry::MetadataCap<${packageId}::plp::PLP>`,
                "package::UpgradeCap",
            ];
        case "deepbook_core_account":
            return ["package::UpgradeCap"];
        case "sessions":
            return ["package::UpgradeCap", "session_config::SessionsAdminCap"];
    }
}

function publishedPath(pkg: PackageName): string {
    return resolve(REPO_ROOT, "packages", pkg, "Published.toml");
}

function reconstructPublishedMetadata(result: DeploymentResult, pkg: PackageName): void {
    const packageId = requiredObjectId(result.packages[pkg], `${pkg} package ID`);
    const upgradeCapability = requiredObjectId(
        result.ownedCaps[pkg]?.["package::UpgradeCap"],
        `${pkg} upgrade capability`,
    );
    const path = publishedPath(pkg);
    const temporaryPath = `${path}.recovery.tmp`;
    try {
        writeFileSync(temporaryPath, publishedMetadataText(packageId, upgradeCapability), {
            mode: 0o644,
        });
        renameSync(temporaryPath, path);
    } finally {
        rmSync(temporaryPath, { force: true });
    }
    assertPublishedIdentity(path, packageId, pkg);
}

function publishedField(section: string, field: string, label: string): string {
    const match = section.match(new RegExp(`^${field}\\s*=\\s*"?([^"\\n]+)"?\\s*$`, "m"));
    if (!match) throw new Error(`${label} is missing '${field}'`);
    return match[1].trim();
}

function assertPublishedIdentity(
    path: string,
    expectedId: string,
    label: string,
    expectedOriginalId = expectedId,
): void {
    if (!existsSync(path)) throw new Error(`${label} is missing ${path}`);
    const text = readFileSync(path, "utf8");
    const section = text.match(/\[published\.testnet\]([\s\S]*?)(?=\n\[|$)/)?.[1];
    if (!section) throw new Error(`${label} is missing [published.testnet]`);
    const chainId = publishedField(section, "chain-id", label);
    const publishedAt = normalizeId(publishedField(section, "published-at", label));
    const originalId = normalizeId(publishedField(section, "original-id", label));
    if (chainId !== CHAIN_ID || publishedAt !== expectedId || originalId !== expectedOriginalId) {
        throw new Error(
            `${label} metadata is ${chainId}/${publishedAt}/${originalId}, expected ${CHAIN_ID}/${expectedId}/${expectedOriginalId}`,
        );
    }
}

function assertRequiredKeys(
    values: Record<string, string> | undefined,
    keys: readonly string[],
    label: string,
): void {
    for (const key of keys) {
        const id = values?.[key];
        if (!id || !OBJECT_ID.test(id)) throw new Error(`${label} is missing valid '${key}'`);
    }
}

function assertCompletedPackage(result: DeploymentResult, pkg: PackageName): void {
    const packageId = result.packages[pkg];
    const digest = result.publishTx[pkg];
    if (!packageId || !OBJECT_ID.test(packageId) || !digest) {
        throw new Error(`${pkg} checkpoint is missing its package ID or publish digest`);
    }
    assertPublishedIdentity(publishedPath(pkg), packageId, pkg);
    assertRequiredKeys(result.sharedObjects[pkg], EXPECTED_SHARED[pkg], `${pkg} shared objects`);
    assertRequiredKeys(result.ownedCaps[pkg], expectedCaps(pkg, packageId), `${pkg} owned caps`);
}

function assertPackageCheckpoints(result: DeploymentResult): void {
    for (const pkg of PACKAGES) {
        if (result.packages[pkg]) {
            assertCompletedPackage(result, pkg);
        }
    }
}

function withFreshPackageStage<T>(pkg: PackageName, operation: (directory: string) => T): T {
    const directory = mkdtempSync(join(tmpdir(), `${DEPLOYMENT}-${pkg}-`));
    const stagedPackages = resolve(directory, "packages");
    try {
        cpSync(resolve(REPO_ROOT, "packages"), stagedPackages, {
            recursive: true,
            filter: (source) => !["build", "node_modules"].includes(basename(source)),
        });
        const stagedPackage = resolve(stagedPackages, pkg);
        rmSync(resolve(stagedPackage, "Published.toml"), { force: true });
        return operation(stagedPackage);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
}

function changedPaths(): string[] {
    const output = execFileSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], {
        cwd: REPO_ROOT,
        encoding: "utf8",
    }).trimEnd();
    if (!output) return [];
    return output.split("\n").map((line) => {
        const path = line.slice(3);
        const rename = path.lastIndexOf(" -> ");
        return rename >= 0 ? path.slice(rename + 4) : path;
    });
}

export function unexpectedDeploymentPaths(
    paths: readonly string[],
    generatedPackages: readonly string[],
    allowManifest = false,
): string[] {
    const allowed = new Set<string>([
        STATE_RELATIVE,
        ...generatedPackages.map((pkg) => `packages/${pkg}/Published.toml`),
    ]);
    if (allowManifest) allowed.add(MANIFEST_RELATIVE);
    return paths.filter((path) => !allowed.has(path));
}

export function removeRecoveryTemporaries(paths: readonly string[]): void {
    for (const path of paths) rmSync(path, { force: true });
}

function assertExpectedWorktree(result: DeploymentResult): void {
    const generatedPackages = PACKAGES.filter(
        (pkg) => result.packages[pkg] || result.inFlight?.package === pkg,
    );
    removeRecoveryTemporaries(
        generatedPackages.map((pkg) => `${publishedPath(pkg)}.recovery.tmp`),
    );
    const unexpected = unexpectedDeploymentPaths(
        changedPaths(),
        generatedPackages,
        result.status === "complete" ||
            (result.wiring.lifecycleCap.owner === "recipient" && result.verification !== null),
    );
    if (unexpected.length > 0) {
        throw new Error(
            `deployment source is dirty outside generated artifacts: ${unexpected.join(", ")}`,
        );
    }
}

export function assertSourceBinding(expectedCommit: string, actualCommit: string): void {
    if (actualCommit !== expectedCommit) {
        throw new Error(
            `deployment source commit changed from ${expectedCommit} to ${actualCommit}`,
        );
    }
}

function assertSourceCommit(expectedCommit: string): void {
    assertSourceBinding(expectedCommit, git(["rev-parse", "HEAD"]));
}

function expectedCadenceRecord(spec: CadenceSpec, setTx: string | null): CadenceRecord {
    return {
        id: spec.id,
        name: spec.name,
        tickSize: spec.tickSize.toString(),
        admissionTickSize: spec.admissionTickSize.toString(),
        maxExpiryAllocation: spec.maxExpiryAllocation.toString(),
        initialExpiryCash: spec.initialExpiryCash.toString(),
        windowSize: spec.windowSize.toString(),
        setTx,
    };
}

function cadenceMatches(actual: CadenceRecord, expected: CadenceSpec): boolean {
    return (
        actual.id === expected.id &&
        actual.tickSize === expected.tickSize.toString() &&
        actual.admissionTickSize === expected.admissionTickSize.toString() &&
        actual.maxExpiryAllocation === expected.maxExpiryAllocation.toString() &&
        actual.initialExpiryCash === expected.initialExpiryCash.toString() &&
        actual.windowSize === expected.windowSize.toString()
    );
}

function assertStateFile(result: DeploymentResult): void {
    if (
        result.schemaVersion !== 3 ||
        result.network !== NETWORK ||
        result.chainId !== CHAIN_ID ||
        result.buildEnvironment !== NETWORK ||
        normalizeId(result.deployer) !== DEPLOYER
    ) {
        throw new Error(`${STATE_RELATIVE} is not the expected schema-3 Testnet deployment`);
    }
    if (JSON.stringify(result.linked) !== JSON.stringify(LINKED)) {
        throw new Error(`linked package IDs in ${STATE_RELATIVE} do not match deploy.ts`);
    }
    if (JSON.stringify(result.linkedObjects) !== JSON.stringify(LINKED_OBJECTS)) {
        throw new Error(`linked object IDs in ${STATE_RELATIVE} do not match deploy.ts`);
    }
    if (
        result.wiring.lifecycleCap.recipient !== LIFECYCLE_CAP_RECIPIENT ||
        result.wiring.bootstrap.lockCapitalAmount !== LOCK_CAPITAL_AMOUNT.toString() ||
        result.wiring.bootstrap.supplyAmount !== BOOTSTRAP_SUPPLY_AMOUNT.toString()
    ) {
        throw new Error("deployment wiring authority or bootstrap amounts do not match deploy.ts");
    }
    if (
        result.wiring.cadences.length !== CADENCES.length ||
        !result.wiring.cadences.every((record, index) => cadenceMatches(record, CADENCES[index]))
    ) {
        throw new Error("deployment cadence policy does not match deploy.ts");
    }
}

function acquireLock(): LockHandle {
    const commonDirRaw = git(["rev-parse", "--git-common-dir"]);
    const commonDir = isAbsolute(commonDirRaw) ? commonDirRaw : resolve(REPO_ROOT, commonDirRaw);
    const path = resolve(commonDir, "predict-testnet-deployment.lock");
    const token = randomUUID();
    const payload = {
        token,
        pid: process.pid,
        startedAt: new Date().toISOString(),
        worktree: REPO_ROOT,
        branch: git(["branch", "--show-current"]),
        head: git(["rev-parse", "HEAD"]),
    };
    let fd: number;
    try {
        fd = openSync(path, "wx", 0o600);
    } catch (error) {
        if (existsSync(path)) {
            const detail = readFileSync(path, "utf8").trim();
            throw new Error(
                `deployment lock already exists at ${path}. Fail closed: inspect ${STATE_RELATIVE} and Testnet before removing it. lock=${detail}`,
            );
        }
        throw new Error(`unable to acquire deployment lock at ${path}: ${String(error)}`);
    }
    writeFileSync(fd, `${JSON.stringify(payload, null, 2)}\n`);
    closeSync(fd);
    return { path, token };
}

function releaseLock(lock: LockHandle): void {
    if (!existsSync(lock.path)) return;
    const current = JSON.parse(readFileSync(lock.path, "utf8")) as { token?: string };
    if (current.token !== lock.token) {
        throw new Error(`deployment lock token changed at ${lock.path}; refusing to remove it`);
    }
    rmSync(lock.path);
}

function stripYamlScalar(value: string): string {
    const trimmed = value.trim();
    if (
        (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))
    ) {
        return trimmed.slice(1, -1);
    }
    return trimmed;
}

function snapshotClientConfig(): ClientSnapshot {
    const source =
        process.env.SUI_CLIENT_CONFIG ?? resolve(homedir(), ".sui", "sui_config", "client.yaml");
    if (!existsSync(source)) throw new Error(`Sui client config does not exist: ${source}`);
    const yaml = readFileSync(source, "utf8");
    const activeEnv = yaml.match(/^active_env:\s*(.+)$/m)?.[1];
    const activeAddress = yaml.match(/^active_address:\s*(.+)$/m)?.[1];
    if (
        !activeEnv ||
        stripYamlScalar(activeEnv) !== NETWORK ||
        !activeAddress ||
        normalizeId(stripYamlScalar(activeAddress)) !== DEPLOYER
    ) {
        throw new Error(`Sui client config must be active on ${NETWORK} as ${DEPLOYER}`);
    }

    const environmentBlock = yaml.match(
        new RegExp(
            `^\\s*- alias:\\s*${NETWORK}\\s*$([\\s\\S]*?)(?=^\\s*- alias:|^active_env:)`,
            "m",
        ),
    )?.[1];
    const rpc = environmentBlock?.match(/^\s*rpc:\s*(.+)$/m)?.[1];
    const configuredChain = environmentBlock?.match(/^\s*chain_id:\s*(.+)$/m)?.[1];
    if (!rpc || !configuredChain || stripYamlScalar(configuredChain) !== CHAIN_ID) {
        throw new Error(
            `Sui client config is missing the pinned ${NETWORK}/${CHAIN_ID} environment`,
        );
    }

    assertNoKeystoreOverride(process.env.SUI_KEYSTORE_PATH);
    const configuredKeystore = yaml.match(/keystore:\s*\n\s*File:\s*(.+)$/m)?.[1];
    const keystorePath = configuredKeystore
        ? stripYamlScalar(configuredKeystore)
        : resolve(homedir(), ".sui", "sui_config", "sui.keystore");
    if (!existsSync(keystorePath)) throw new Error(`Sui keystore does not exist: ${keystorePath}`);

    const directory = mkdtempSync(join(tmpdir(), "predict-testnet-deploy-"));
    const configPath = resolve(directory, "client.yaml");
    copyFileSync(source, configPath);
    chmodSync(configPath, 0o600);
    return {
        directory,
        configPath,
        rpcUrl: stripYamlScalar(rpc),
        keystorePath,
        configDigest: sha256(yaml),
    };
}

export function assertNoKeystoreOverride(value: string | undefined): void {
    if (value) {
        throw new Error(
            "SUI_KEYSTORE_PATH is unsupported for this deployment; the CLI and SDK must use the keystore pinned by client.yaml",
        );
    }
}

function getSigner(keystorePath: string): Ed25519Keypair {
    const entries = JSON.parse(readFileSync(keystorePath, "utf8")) as unknown;
    if (!Array.isArray(entries)) throw new Error(`invalid Sui keystore: ${keystorePath}`);
    for (const entry of entries) {
        if (typeof entry !== "string") continue;
        const raw = fromBase64(entry);
        if (raw.length !== 33 || raw[0] !== 0) continue;
        const signer = Ed25519Keypair.fromSecretKey(raw.slice(1));
        if (normalizeId(signer.getPublicKey().toSuiAddress()) === DEPLOYER) return signer;
    }
    throw new Error(`Ed25519 keypair for ${DEPLOYER} was not found in the configured keystore`);
}

function debugPackageId(path: string): string {
    const debug = JSON.parse(readFileSync(path, "utf8")) as { module_name?: unknown[] };
    const id = debug.module_name?.[0];
    if (typeof id !== "string") throw new Error(`missing module package ID in ${path}`);
    return normalizeId(id);
}

function bytecodeBase64(value: unknown, label: string): string {
    if (
        !Array.isArray(value) ||
        value.some((byte) => !Number.isInteger(byte) || Number(byte) < 0 || Number(byte) > 255)
    ) {
        throw new Error(`${label} is not bytecode`);
    }
    return Buffer.from(value as number[]).toString("base64");
}

export function parsePackageMetadata(raw: unknown): PublishedPackageMetadata {
    const root = asRecord(raw);
    const data = asRecord(root.data ?? root);
    const contentRoot = asRecord(data.content ?? data);
    const content = asRecord(contentRoot.Package ?? contentRoot.package ?? contentRoot);
    const moduleMap = asRecord(content.moduleMap ?? content.module_map);
    if (Object.keys(moduleMap).length === 0) throw new Error("package module_map is empty");
    const modules = Object.fromEntries(
        Object.entries(moduleMap)
            .sort(([left], [right]) => left.localeCompare(right))
            .map(([name, bytecode]) => [name, bytecodeBase64(bytecode, `module_map.${name}`)]),
    );
    const linkage = asRecord(content.linkageTable ?? content.linkage_table);
    const linkageRecords = Object.entries(linkage)
        .map(([originalId, value]) => {
            const record = asRecord(value);
            return {
                originalId: normalizeId(originalId),
                upgradedId: normalizeId(
                    requiredString(
                        record.upgradedId ?? record.upgraded_id,
                        `${originalId}.upgraded_id`,
                    ),
                ),
                upgradedVersion: decimalString(
                    String(record.upgradedVersion ?? record.upgraded_version),
                    `${originalId}.upgraded_version`,
                ),
            };
        })
        .sort((left, right) => left.originalId.localeCompare(right.originalId));
    const rawOrigins = content.typeOriginTable ?? content.type_origin_table;
    if (!Array.isArray(rawOrigins)) throw new Error("package type_origin_table is missing");
    const typeOrigins = rawOrigins
        .map((value, index) => {
            const record = asRecord(value);
            return {
                module: requiredString(
                    record.moduleName ?? record.module_name,
                    `type_origin_table[${index}].module_name`,
                ),
                datatype: requiredString(
                    record.datatypeName ?? record.datatype_name,
                    `type_origin_table[${index}].datatype_name`,
                ),
                packageId: normalizeId(
                    requiredString(record.package, `type_origin_table[${index}].package`),
                ),
            };
        })
        .sort((left, right) =>
            `${left.module}::${left.datatype}`.localeCompare(`${right.module}::${right.datatype}`),
        );
    return {
        packageVersion: decimalString(String(content.version), "package version"),
        modules,
        linkage: linkageRecords,
        typeOrigins,
    };
}

function packageMetadata(runtime: Runtime, id: string): ReturnType<typeof parsePackageMetadata> {
    const packageId = normalizeId(id);
    const cached = runtime.packageMetadataCache.get(packageId);
    if (cached) return cached;
    const metadata = parsePackageMetadata(
        JSON.parse(suiClient(runtime.snapshot, ["object", id, "--json"])) as unknown,
    );
    runtime.packageMetadataCache.set(packageId, metadata);
    return metadata;
}

function moveSourceTypeOrigins(directory: string): CompiledPackageMetadata["typeOrigins"] {
    const origins: CompiledPackageMetadata["typeOrigins"] = [];
    const visit = (path: string): void => {
        for (const entry of readdirSync(path, { withFileTypes: true })) {
            const child = resolve(path, entry.name);
            if (entry.isDirectory()) visit(child);
            else if (entry.isFile() && entry.name.endsWith(".move")) {
                const source = readFileSync(child, "utf8");
                const module = source.match(/\bmodule\s+[A-Za-z0-9_]+::([A-Za-z0-9_]+)\s*;/)?.[1];
                if (!module) throw new Error(`${child} has no Move module declaration`);
                for (const match of source.matchAll(
                    /^\s*(?:public(?:\([^)]*\))?\s+)?(?:struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/gm,
                )) {
                    origins.push({ module, datatype: match[1] });
                }
            }
        }
    };
    visit(resolve(directory, "sources"));
    return origins.sort((left, right) =>
        `${left.module}::${left.datatype}`.localeCompare(`${right.module}::${right.datatype}`),
    );
}

function compiledPackageMetadata(pkg: PackageName): CompiledPackageMetadata {
    return withFreshPackageStage(pkg, (directory) => {
        const raw = JSON.parse(
            sui([
                "move",
                "build",
                "--path",
                directory,
                "--build-env",
                NETWORK,
                "--warnings-are-errors",
                "--force",
                "--dump-bytecode-as-base64",
            ]),
        ) as Record<string, unknown>;
        if (
            !Array.isArray(raw.modules) ||
            !raw.modules.every((value) => typeof value === "string") ||
            !Array.isArray(raw.dependencies) ||
            !raw.dependencies.every((value) => typeof value === "string")
        ) {
            throw new Error(`${pkg} build did not return exact bytecode metadata`);
        }
        return {
            modules: [...raw.modules].sort(),
            dependencies: raw.dependencies.map(normalizeId).sort(),
            typeOrigins: moveSourceTypeOrigins(directory),
        };
    });
}

function expectedDependency(
    runtime: Runtime,
    upgradedId: string,
): { originalId: string; upgradedVersion: string } | null {
    const upgraded = normalizeId(upgradedId);
    let originalId: string | null = null;
    if (upgraded === normalizeId("0x1") || upgraded === normalizeId("0x2")) {
        originalId = upgraded;
    } else if (Object.values(runtime.result.packages).includes(upgraded)) {
        originalId = upgraded;
    } else if (upgraded === LINKED.deepbook) {
        originalId = DEEPBOOK_ORIGINAL;
    } else if ((Object.values(LINKED) as string[]).includes(upgraded)) {
        originalId = upgraded;
    }
    return originalId
        ? {
              originalId,
              upgradedVersion: packageMetadata(runtime, upgraded).packageVersion,
          }
        : null;
}

export function assertExactPackageGraph(
    label: string,
    packageId: string,
    compiled: CompiledPackageMetadata,
    published: PublishedPackageMetadata,
    expectedDependencyFor: (
        upgradedId: string,
    ) => { originalId: string; upgradedVersion: string } | null,
): void {
    const id = normalizeId(packageId);
    if (published.packageVersion !== "1") {
        throw new Error(`${label} package version is ${published.packageVersion}, expected 1`);
    }
    const compiledModules = [...compiled.modules].sort();
    const publishedModules = Object.values(published.modules).sort();
    if (JSON.stringify(publishedModules) !== JSON.stringify(compiledModules)) {
        throw new Error(`${label} on-chain module bytecode does not match the reviewed build`);
    }
    const compiledDependencies = [...compiled.dependencies].map(normalizeId).sort();
    const publishedDependencies = published.linkage.map((entry) => entry.upgradedId).sort();
    if (JSON.stringify(publishedDependencies) !== JSON.stringify(compiledDependencies)) {
        throw new Error(`${label} on-chain linkage does not match the reviewed build`);
    }
    if (new Set(publishedDependencies).size !== publishedDependencies.length) {
        throw new Error(`${label} on-chain linkage contains duplicate upgraded packages`);
    }
    for (const link of published.linkage) {
        const expected = expectedDependencyFor(link.upgradedId);
        if (
            !expected ||
            link.originalId !== normalizeId(expected.originalId) ||
            link.upgradedVersion !== expected.upgradedVersion
        ) {
            throw new Error(
                `${label} dependency ${link.upgradedId} has original/version ${link.originalId}/${link.upgradedVersion}, expected ${expected ? `${expected.originalId}/${expected.upgradedVersion}` : "no dependency"}`,
            );
        }
    }
    const expectedOrigins = compiled.typeOrigins.map((origin) => ({ ...origin, packageId: id }));
    if (JSON.stringify(published.typeOrigins) !== JSON.stringify(expectedOrigins)) {
        throw new Error(`${label} on-chain type origins do not match the reviewed source`);
    }
}

function assertPublishedPackageGraph(runtime: Runtime, pkg: PackageName, id: string): void {
    assertExactPackageGraph(
        pkg,
        id,
        compiledPackageMetadata(pkg),
        packageMetadata(runtime, id),
        (upgradedId) => expectedDependency(runtime, upgradedId),
    );
}

async function verifyPublishedPackageCheckpoint(runtime: Runtime, pkg: PackageName): Promise<void> {
    assertCompletedPackage(runtime.result, pkg);
    const id = packageId(runtime.result, pkg);
    const packageEvidence = await objectEvidence(runtime, id, "package", null);
    if (packageEvidence.previousTransaction !== runtime.result.publishTx[pkg]) {
        throw new Error(`${pkg} package was not created by ${runtime.result.publishTx[pkg]}`);
    }
    assertPublishedPackageGraph(runtime, pkg, id);
    const shared = runtime.result.sharedObjects[pkg] ?? {};
    exactKeys(asRecord(shared), EXPECTED_SHARED[pkg], `${pkg} shared objects`);
    for (const [type, objectId] of Object.entries(shared)) {
        await objectEvidence(runtime, objectId, `${id}::${type}`, "shared");
    }
    const caps = runtime.result.ownedCaps[pkg] ?? {};
    exactKeys(asRecord(caps), expectedCaps(pkg, id), `${pkg} owned capabilities`);
    for (const [type, objectId] of Object.entries(caps)) {
        await objectEvidence(runtime, objectId, type, DEPLOYER);
    }
}

export function assertPackagePlan(plan: readonly PackageName[] = PACKAGES): void {
    if (new Set(plan).size !== PACKAGES.length || plan.some((pkg) => !PACKAGES.includes(pkg))) {
        throw new Error("package plan must contain every fresh package exactly once");
    }
    const position = new Map(plan.map((pkg, index) => [pkg, index]));
    for (const pkg of plan) {
        const manifest = readFileSync(resolve(REPO_ROOT, "packages", pkg, "Move.toml"), "utf8");
        const dependencies = [...manifest.matchAll(/local\s*=\s*"\.\.\/([^"]+)"/g)].map(
            (match) => match[1] as PackageName,
        );
        for (const dependency of dependencies) {
            if (!position.has(dependency)) continue;
            if (position.get(dependency)! >= position.get(pkg)!) {
                throw new Error(`${pkg} is planned before local dependency ${dependency}`);
            }
        }
    }
}

function assertResolvedLinkedPackages(): void {
    assertPackagePlan();
    for (const pkg of PACKAGES) {
        command(SUI, [
            "move",
            "build",
            "--path",
            resolve(REPO_ROOT, "packages", pkg),
            "--build-env",
            NETWORK,
            "--warnings-are-errors",
            "--force",
        ]);
    }
    const debug = resolve(
        REPO_ROOT,
        "packages",
        "sessions",
        "build",
        "deepbook_sessions",
        "debug_info",
        "dependencies",
    );
    const resolved: Record<keyof typeof LINKED, string> = {
        deepbook: debugPackageId(resolve(debug, "deepbook", "registry.json")),
        dusdc: debugPackageId(resolve(debug, "dusdc", "dusdc.json")),
        deep: debugPackageId(resolve(debug, "token", "deep.json")),
        pyth_lazer: debugPackageId(resolve(debug, "pyth_lazer", "channel.json")),
        wormhole: debugPackageId(resolve(debug, "wormhole", "external_address.json")),
        bs_oracle: debugPackageId(resolve(debug, "bs_oracle", "verify.json")),
        bs_sid: debugPackageId(resolve(debug, "bs_sid", "sid.json")),
    };
    for (const [name, expectedId] of Object.entries(LINKED)) {
        if (resolved[name as keyof typeof LINKED] !== expectedId) {
            throw new Error(
                `${name} resolves to ${resolved[name as keyof typeof LINKED]}, expected ${expectedId}`,
            );
        }
    }
    assertPublishedIdentity(
        resolve(REPO_ROOT, "packages", "dusdc", "Published.toml"),
        LINKED.dusdc,
        "DUSDC",
    );
    assertPublishedIdentity(
        resolve(REPO_ROOT, "packages", "token", "Published.toml"),
        LINKED.deep,
        "DEEP",
    );
    assertPublishedIdentity(
        resolve(REPO_ROOT, "packages", "deepbook", "Published.toml"),
        LINKED.deepbook,
        "DeepBook",
        "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982",
    );
}

async function assertSdkTarget(runtime: Runtime): Promise<void> {
    assertSourceCommit(runtime.sourceCommit);
    assertExpectedWorktree(runtime.result);
    const chainId = await shortChainId(runtime.client);
    if (chainId !== CHAIN_ID) {
        throw new Error(`RPC ${runtime.snapshot.rpcUrl} is chain ${chainId}, expected ${CHAIN_ID}`);
    }
    if (normalizeId(runtime.signer.getPublicKey().toSuiAddress()) !== DEPLOYER) {
        throw new Error("deployment signer changed during the run");
    }
}

export function assertDeploymentTarget(
    environment: string,
    chainId: string,
    address: string,
): void {
    const normalizedAddress = normalizeId(address);
    if (environment !== NETWORK || chainId !== CHAIN_ID || normalizedAddress !== DEPLOYER) {
        throw new Error(
            `deployment target is ${environment}/${chainId}/${normalizedAddress}, expected ${NETWORK}/${CHAIN_ID}/${DEPLOYER}`,
        );
    }
}

export function assertSuiCliVersion(version: string): void {
    if (version !== SUI_VERSION) {
        throw new Error(`Sui CLI must be '${SUI_VERSION}', got '${version}'`);
    }
}

interface ExecutionBindings {
    suiVersion: string;
    suiBinaryPath: string;
    suiBinaryDigest: string;
    rpcUrl: string;
    clientConfigDigest: string;
    packageGasBudget: string;
    transactionGasBudget: string;
}

export function assertExecutionBindings(
    result: DeploymentResult,
    bindings: ExecutionBindings,
): void {
    const recorded: ExecutionBindings = {
        suiVersion: requiredString(result.suiVersion, "recorded Sui version"),
        suiBinaryPath: requiredString(result.suiBinaryPath, "recorded Sui binary path"),
        suiBinaryDigest: requiredString(result.suiBinaryDigest, "recorded Sui binary digest"),
        rpcUrl: requiredString(result.rpcUrl, "recorded RPC URL"),
        clientConfigDigest: requiredString(
            result.clientConfigDigest,
            "recorded client config digest",
        ),
        packageGasBudget: requiredString(result.packageGasBudget, "recorded package gas budget"),
        transactionGasBudget: requiredString(
            result.transactionGasBudget,
            "recorded transaction gas budget",
        ),
    };
    if (JSON.stringify(recorded) !== JSON.stringify(bindings)) {
        throw new Error(
            `deployment execution bindings changed: recorded=${JSON.stringify(recorded)} actual=${JSON.stringify(bindings)}`,
        );
    }
}

function assertCliTarget(snapshot: ClientSnapshot): void {
    const environment = suiClient(snapshot, ["active-env"]);
    const chainId = suiClient(snapshot, ["chain-identifier"]);
    const address = suiClient(snapshot, ["active-address"]);
    assertDeploymentTarget(environment, chainId, address);
}

function effectsError(effects: unknown): string | null {
    const status = asRecord(asRecord(effects).status);
    const state = status.status;
    if (state === "success" || status.success === true) return null;
    return typeof status.error === "string" ? status.error : JSON.stringify(status);
}

async function shortChainId(client: SuiGrpcClient): Promise<string> {
    const { chainIdentifier } = await client.core.getChainIdentifier();
    return toHex(fromBase58(chainIdentifier).slice(0, 4));
}

function coreReceipt(response: unknown): Receipt {
    const envelope = asRecord(response);
    const transaction = asRecord(envelope.Transaction ?? envelope.FailedTransaction);
    const effects = asRecord(transaction.effects);
    const objectTypes = asRecord(transaction.objectTypes);
    const changedObjects = effects.changedObjects;
    const objectChanges: ObjectChange[] = [];
    if (Array.isArray(changedObjects)) {
        for (const value of changedObjects) {
            const change = asRecord(value);
            if (change.idOperation !== "Created" || typeof change.objectId !== "string") continue;
            if (change.outputState === "PackageWrite") {
                objectChanges.push({
                    type: "published",
                    packageId: normalizeId(change.objectId),
                });
            } else if (change.outputState === "ObjectWrite") {
                const objectType = objectTypes[change.objectId];
                objectChanges.push({
                    type: "created",
                    objectId: normalizeId(change.objectId),
                    objectType: typeof objectType === "string" ? objectType : undefined,
                    owner: change.outputOwner,
                });
            }
        }
    }
    const rawEvents = transaction.events;
    const events: EventRecord[] = Array.isArray(rawEvents)
        ? rawEvents.map((value) => {
              const event = asRecord(value);
              return {
                  type: typeof event.eventType === "string" ? event.eventType : undefined,
                  parsedJson: event.json,
              };
          })
        : [];
    return {
        digest: typeof transaction.digest === "string" ? transaction.digest : undefined,
        effects: transaction.effects,
        objectChanges,
        events,
    };
}

async function settledReceipt(
    client: SuiGrpcClient,
    digest: string,
    attempts = 24,
): Promise<Receipt> {
    let lastError: unknown;
    for (let attempt = 0; attempt < attempts; attempt++) {
        try {
            return coreReceipt(
                await client.getTransaction({
                    digest,
                    include: {
                        effects: true,
                        events: true,
                        objectTypes: true,
                    },
                }),
            );
        } catch (error) {
            lastError = error;
            await new Promise((done) => setTimeout(done, 250));
        }
    }
    throw lastError;
}

function createdObjectId(receipt: Receipt, typeSuffix: string): string {
    const change = (receipt.objectChanges ?? []).find(
        (candidate) =>
            candidate.type === "created" &&
            typeof candidate.objectType === "string" &&
            candidate.objectType.endsWith(typeSuffix),
    );
    if (!change?.objectId) {
        throw new Error(`transaction ${receipt.digest} did not create ${typeSuffix}`);
    }
    return normalizeId(change.objectId);
}

function eventNamed(receipt: Receipt, name: string): EventRecord | null {
    return (
        (receipt.events ?? []).find(
            (event) => typeof event.type === "string" && event.type.endsWith(`::${name}`),
        ) ?? null
    );
}

function call(
    tx: Transaction,
    target: string,
    args: TransactionArgument[],
    typeArguments: string[] = [],
): TransactionResult {
    return tx.moveCall({
        target: target as `${string}::${string}::${string}`,
        typeArguments,
        arguments: args,
    });
}

async function dryRun(runtime: Runtime, label: string, bytes: Uint8Array): Promise<void> {
    const response = await runtime.client.simulateTransaction({
        transaction: bytes,
        checksEnabled: true,
        include: { effects: true },
    });
    const error = effectsError(coreReceipt(response).effects);
    if (error) throw new DryRunFailure(label, error);
}

async function executeTransaction(
    runtime: Runtime,
    label: string,
    tx: Transaction,
): Promise<Receipt> {
    const completedDigest = irreversibleStepDigest(runtime.result, "transaction", label, null);
    if (completedDigest) {
        const receipt = await settledReceipt(runtime.client, completedDigest);
        const failure = effectsError(receipt.effects);
        if (failure) {
            throw new Error(`${label}/${completedDigest} was checkpointed but failed: ${failure}`);
        }
        return receipt;
    }
    if (runtime.result.inFlight) {
        throw new Error(`cannot start ${label}; ${runtime.result.inFlight.label} is in flight`);
    }
    await assertSdkTarget(runtime);
    tx.setSender(DEPLOYER);
    tx.setGasBudget(TRANSACTION_GAS_BUDGET);
    const bytes = await tx.build({ client: runtime.client });
    await dryRun(runtime, label, bytes);
    const digest = TransactionDataBuilder.getDigestFromBytes(bytes);
    runtime.result.inFlight = {
        kind: "transaction",
        label,
        package: null,
        startedAt: new Date().toISOString(),
        digest,
    };
    writeState(runtime.result);

    let receipt: Receipt;
    try {
        const { signature } = await runtime.signer.signTransaction(bytes);
        receipt = coreReceipt(
            await runtime.client.executeTransaction({
                transaction: bytes,
                signatures: [signature],
                include: {
                    effects: true,
                    events: true,
                    objectTypes: true,
                },
            }),
        );
    } catch (submitError) {
        try {
            receipt = await settledReceipt(runtime.client, digest, 8);
        } catch {
            throw new Error(
                `${label} submission is ambiguous at ${digest}: ${String(submitError)}`,
            );
        }
    }
    if (receipt.digest !== digest) {
        throw new Error(`${label} returned digest ${receipt.digest}, expected ${digest}`);
    }
    const failure = effectsError(receipt.effects);
    if (failure) {
        recordVerifiedTransactionFailure(runtime.result, runtime.result.inFlight!, failure);
        writeState(runtime.result);
        throw new Error(`${label} failed at ${digest}: ${failure}; failure checkpoint cleared`);
    }
    receipt = await settledReceipt(runtime.client, digest);
    runtime.result.transactions[label] = digest;
    runtime.result.inFlight = null;
    runtime.result.status = "wiring";
    writeState(runtime.result);
    await assertSdkTarget(runtime);
    console.log(`[deploy] ${label}: ${digest}`);
    return receipt;
}

function recordPublish(result: DeploymentResult, pkg: PackageName, receipt: Receipt): void {
    const changes = receipt.objectChanges ?? [];
    const packageId = normalizeOptionalId(
        changes.find((change) => change.type === "published")?.packageId,
    );
    if (!packageId || !receipt.digest) throw new Error(`publish ${pkg} receipt is incomplete`);
    result.packages[pkg] = packageId;
    result.publishTx[pkg] = receipt.digest;

    const shared: Record<string, string> = {};
    const caps: Record<string, string> = {};
    for (const change of changes) {
        if (change.type !== "created" || !change.objectType || !change.objectId) continue;
        const key = shortType(change.objectType);
        if (isShared(change.owner)) shared[key] = normalizeId(change.objectId);
        else if (change.objectType.includes("Cap") && addressOwner(change.owner) === DEPLOYER) {
            caps[key] = normalizeId(change.objectId);
        }
    }
    if (Object.keys(shared).length > 0) result.sharedObjects[pkg] = shared;
    result.ownedCaps[pkg] = caps;
}

async function publishPackage(runtime: Runtime, pkg: PackageName): Promise<void> {
    if (runtime.result.inFlight) throw new Error(`${runtime.result.inFlight.label} is in flight`);
    assertExpectedWorktree(runtime.result);
    assertSourceCommit(runtime.sourceCommit);
    assertCliTarget(runtime.snapshot);
    runtime.result.inFlight = {
        kind: "publish",
        label: `publish_${pkg}`,
        package: pkg,
        startedAt: new Date().toISOString(),
        digest: null,
    };
    writeState(runtime.result);

    const receipt = withFreshPackageStage(pkg, (directory) => {
        const output = suiClient(runtime.snapshot, [
            "publish",
            directory,
            "--warnings-are-errors",
            "--force",
            "--sender",
            DEPLOYER,
            "--gas-budget",
            PACKAGE_GAS_BUDGET,
            "--json",
        ]);
        const receipt = JSON.parse(output) as Receipt;
        const failure = effectsError(receipt.effects);
        if (!receipt.digest) throw new Error(`publish ${pkg} returned no digest: ${failure}`);
        runtime.result.inFlight!.digest = receipt.digest;
        writeState(runtime.result);
        if (failure) return receipt;
        const publishedId = normalizeId(
            (receipt.objectChanges ?? []).find((change) => change.type === "published")
                ?.packageId ?? "",
        );
        const stagedPublished = resolve(directory, "Published.toml");
        assertPublishedIdentity(stagedPublished, publishedId, pkg);
        copyFileSync(stagedPublished, publishedPath(pkg));
        return receipt;
    });
    runtime.result.inFlight!.digest = requiredString(receipt.digest, `${pkg} publish digest`);
    const publishFailure = effectsError(receipt.effects);
    if (publishFailure) {
        recordVerifiedTransactionFailure(runtime.result, runtime.result.inFlight, publishFailure);
        writeState(runtime.result);
        throw new Error(
            `publish ${pkg} failed at ${receipt.digest}: ${publishFailure}; failure checkpoint cleared`,
        );
    }
    assertCliTarget(runtime.snapshot);
    assertPublishedIdentity(
        publishedPath(pkg),
        normalizeId(
            (receipt.objectChanges ?? []).find((change) => change.type === "published")
                ?.packageId ?? "",
        ),
        pkg,
    );
    recordPublish(runtime.result, pkg, receipt);
    assertCompletedPackage(runtime.result, pkg);
    await verifyPublishedPackageCheckpoint(runtime, pkg);
    runtime.result.inFlight = null;
    writeState(runtime.result);
    console.log(`[deploy] ${pkg}: ${runtime.result.packages[pkg]} (${receipt.digest})`);
}

export function assertRecoverableInFlight(inFlight: InFlight, digestVisible: boolean): void {
    if (!inFlight.digest) {
        throw new Error(`${inFlight.label} has no known digest; fail closed`);
    }
    if (!digestVisible) {
        throw new Error(`${inFlight.label}/${inFlight.digest} is not visible; fail closed`);
    }
}

export function checkpointRecoveredTransaction(result: DeploymentResult): void {
    const inFlight = result.inFlight;
    if (!inFlight) return;
    if (inFlight.kind !== "transaction" || !inFlight.digest) {
        throw new Error("only a transaction with a known digest can be checkpointed generically");
    }
    result.transactions[inFlight.label] = inFlight.digest;
    result.inFlight = null;
}

export function recordVerifiedTransactionFailure(
    result: DeploymentResult,
    inFlight: InFlight,
    error: string,
): void {
    if (!inFlight.digest) throw new Error("verified failure is missing its transaction digest");
    result.failedTransactions[inFlight.label] = {
        digest: inFlight.digest,
        error,
        recordedAt: new Date().toISOString(),
    };
    result.inFlight = null;
}

export function irreversibleStepDigest(
    result: DeploymentResult,
    kind: InFlight["kind"],
    label: string,
    pkg: PackageName | null,
): string | null {
    if (kind === "publish") {
        if (!pkg) throw new Error(`${label} publish step is missing its package`);
        return result.packages[pkg] && result.publishTx[pkg] ? result.publishTx[pkg]! : null;
    }
    return result.transactions[label] ?? null;
}

interface ReconcileJournaledInFlightActions {
    loadReceipt: (digest: string) => Promise<Receipt>;
    recoverPublish: (pkg: PackageName, receipt: Receipt) => Promise<void>;
    persist: () => void;
}

export async function reconcileJournaledInFlight(
    result: DeploymentResult,
    actions: ReconcileJournaledInFlightActions,
): Promise<InFlight | null> {
    const inFlight = result.inFlight;
    if (!inFlight) return null;
    assertRecoverableInFlight(inFlight, true);
    let receipt: Receipt;
    try {
        receipt = await actions.loadReceipt(inFlight.digest!);
    } catch {
        assertRecoverableInFlight(inFlight, false);
        throw new Error(
            `${inFlight.label}/${inFlight.digest} is not visible on Testnet. Fail closed; do not retry with new transaction bytes`,
        );
    }
    if (receipt.digest !== inFlight.digest) {
        throw new Error(
            `${inFlight.label} recovery returned digest ${receipt.digest}, expected ${inFlight.digest}`,
        );
    }
    const failure = effectsError(receipt.effects);
    if (failure) {
        recordVerifiedTransactionFailure(result, inFlight, failure);
        actions.persist();
        throw new Error(
            `${inFlight.label}/${inFlight.digest} failed: ${failure}; failure checkpoint cleared`,
        );
    }
    if (inFlight.kind === "publish") {
        if (!inFlight.package) throw new Error("in-flight publish is missing its package");
        await actions.recoverPublish(inFlight.package, receipt);
        result.inFlight = null;
    } else {
        checkpointRecoveredTransaction(result);
    }
    actions.persist();
    return inFlight;
}

async function reconcileInFlight(runtime: Runtime): Promise<void> {
    const recovered = await reconcileJournaledInFlight(runtime.result, {
        loadReceipt: (digest) => settledReceipt(runtime.client, digest, 4),
        recoverPublish: async (pkg, receipt) => {
            recordPublish(runtime.result, pkg, receipt);
            reconstructPublishedMetadata(runtime.result, pkg);
            assertCompletedPackage(runtime.result, pkg);
            await verifyPublishedPackageCheckpoint(runtime, pkg);
        },
        persist: () => writeState(runtime.result),
    });
    if (recovered) console.log(`[deploy] reconciled ${recovered.label}: ${recovered.digest}`);
}

function packageId(result: DeploymentResult, pkg: PackageName): string {
    const id = result.packages[pkg];
    if (!id) throw new Error(`${pkg} has not been published`);
    return id;
}

function sharedId(result: DeploymentResult, pkg: PackageName, type: string): string {
    const id = result.sharedObjects[pkg]?.[type];
    if (!id) throw new Error(`${pkg} shared object ${type} is missing`);
    return id;
}

function capId(result: DeploymentResult, pkg: PackageName, type: string): string {
    const id = result.ownedCaps[pkg]?.[type];
    if (!id) throw new Error(`${pkg} capability ${type} is missing`);
    return id;
}

function target(result: DeploymentResult, pkg: PackageName, module: string, fn: string): string {
    return `${packageId(result, pkg)}::${module}::${fn}`;
}

function dusdcType(): string {
    return `${LINKED.dusdc}::dusdc::DUSDC`;
}

function plpType(result: DeploymentResult): string {
    return `${packageId(result, "predict")}::plp::PLP`;
}

async function devInspect(runtime: Runtime, label: string, tx: Transaction): Promise<unknown> {
    tx.setSender(DEPLOYER);
    const response = await runtime.client.simulateTransaction({
        transaction: tx,
        checksEnabled: false,
        include: {
            commandResults: true,
            effects: true,
        },
    });
    const error = effectsError(coreReceipt(response).effects);
    if (error) throw new Error(`${label} simulation failed: ${error}`);
    return response;
}

function returnBytes(response: unknown, resultIndex = 0, returnIndex = 0): number[] {
    const results = asRecord(response).commandResults;
    if (!Array.isArray(results)) throw new Error("simulation response has no command results");
    const result = asRecord(results[resultIndex]);
    const returnValues = result.returnValues;
    if (!Array.isArray(returnValues)) {
        throw new Error(`simulation result ${resultIndex} has no return ${returnIndex}`);
    }
    const bytes = asRecord(returnValues[returnIndex]).bcs;
    if (bytes instanceof Uint8Array) return Array.from(bytes);
    if (Array.isArray(bytes) && bytes.every((value) => Number.isInteger(value))) {
        return bytes as number[];
    }
    throw new Error("simulation return is not byte-encoded");
}

function parseBool(bytes: number[]): boolean {
    return bytes[0] === 1;
}

function parseU64(bytes: number[]): bigint {
    if (bytes.length < 8) throw new Error(`invalid u64 return (${bytes.length} bytes)`);
    let value = 0n;
    for (let index = 7; index >= 0; index--) value = (value << 8n) + BigInt(bytes[index]);
    return value;
}

function parseU32(bytes: number[]): number {
    if (bytes.length < 4) throw new Error(`invalid u32 return (${bytes.length} bytes)`);
    return bytes[0] + bytes[1] * 2 ** 8 + bytes[2] * 2 ** 16 + bytes[3] * 2 ** 24;
}

function parseAddress(bytes: number[]): string {
    if (bytes.length < 32) throw new Error(`invalid address return (${bytes.length} bytes)`);
    return normalizeId(
        `0x${bytes
            .slice(0, 32)
            .map((byte) => byte.toString(16).padStart(2, "0"))
            .join("")}`,
    );
}

function parseOptionId(bytes: number[]): string | null {
    if (bytes.length === 1 && bytes[0] === 0) return null;
    if (bytes[0] !== 1 || bytes.length !== 33) {
        throw new Error(`invalid Option<ID> return (${bytes.length} bytes)`);
    }
    return parseAddress(bytes.slice(1));
}

interface BlockScholesStorePair {
    valueStoreId: string;
    sviStoreId: string;
    baseAsset: string;
}

export function parseOptionBlockScholesStorePair(bytes: number[]): BlockScholesStorePair | null {
    if (bytes.length === 1 && bytes[0] === 0) return null;
    if (bytes[0] !== 1 || bytes.length <= 65) {
        throw new Error(`invalid Option<BlockScholesStorePair> return (${bytes.length} bytes)`);
    }
    return {
        valueStoreId: parseAddress(bytes.slice(1, 33)),
        sviStoreId: parseAddress(bytes.slice(33, 65)),
        baseAsset: parseString(bytes.slice(65)),
    };
}

function readUleb(bytes: number[], start: number): { value: number; next: number } {
    let value = 0;
    let shift = 0;
    let index = start;
    while (index < bytes.length) {
        const byte = bytes[index++];
        value |= (byte & 0x7f) << shift;
        if ((byte & 0x80) === 0) return { value, next: index };
        shift += 7;
    }
    throw new Error("truncated ULEB128");
}

function parseIdVector(bytes: number[]): string[] {
    const length = readUleb(bytes, 0);
    const ids: string[] = [];
    let offset = length.next;
    for (let index = 0; index < length.value; index++) {
        ids.push(parseAddress(bytes.slice(offset, offset + 32)));
        offset += 32;
    }
    if (offset !== bytes.length) throw new Error("unexpected bytes after vector<ID>");
    return ids;
}

function parseString(bytes: number[]): string {
    const length = readUleb(bytes, 0);
    const end = length.next + length.value;
    if (end !== bytes.length) throw new Error("invalid Move String return");
    return new TextDecoder("utf-8", { fatal: true }).decode(
        Uint8Array.from(bytes.slice(length.next, end)),
    );
}

async function inspectOptionId(
    runtime: Runtime,
    label: string,
    moveTarget: string,
    args: (tx: Transaction) => TransactionArgument[],
): Promise<string | null> {
    const tx = new Transaction();
    call(tx, moveTarget, args(tx));
    return parseOptionId(returnBytes(await devInspect(runtime, label, tx)));
}

async function inspectBlockScholesStorePair(
    runtime: Runtime,
    label: string,
    oracleRegistry: string,
): Promise<BlockScholesStorePair | null> {
    const tx = new Transaction();
    call(
        tx,
        target(
            runtime.result,
            "propbook",
            "registry",
            "propbook_block_scholes_store_pair_for_underlying",
        ),
        [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    return parseOptionBlockScholesStorePair(returnBytes(await devInspect(runtime, label, tx)));
}

async function inspectString(
    runtime: Runtime,
    label: string,
    moveTarget: string,
    args: (tx: Transaction) => TransactionArgument[],
): Promise<string> {
    const tx = new Transaction();
    call(tx, moveTarget, args(tx));
    return parseString(returnBytes(await devInspect(runtime, label, tx)));
}

async function assertBlockScholesStoreBaseAssets(
    runtime: Runtime,
    pair: BlockScholesStorePair,
): Promise<void> {
    const valueStoreBaseAsset = await inspectString(
        runtime,
        "block_scholes_value_store_base_asset",
        target(runtime.result, "propbook", "block_scholes_store", "value_store_base_asset"),
        (tx) => [tx.object(pair.valueStoreId)],
    );
    const sviStoreBaseAsset = await inspectString(
        runtime,
        "block_scholes_svi_store_base_asset",
        target(runtime.result, "propbook", "block_scholes_store", "svi_store_base_asset"),
        (tx) => [tx.object(pair.sviStoreId)],
    );
    if (
        pair.baseAsset !== ASSET.blockScholesBaseAsset ||
        valueStoreBaseAsset !== ASSET.blockScholesBaseAsset ||
        sviStoreBaseAsset !== ASSET.blockScholesBaseAsset
    ) {
        throw new Error(
            `Block Scholes binding/store base assets are ${pair.baseAsset}/${valueStoreBaseAsset}/${sviStoreBaseAsset}, expected ${ASSET.blockScholesBaseAsset}`,
        );
    }
}

async function inspectBool(
    runtime: Runtime,
    label: string,
    moveTarget: string,
    args: (tx: Transaction) => TransactionArgument[],
    typeArguments: string[] = [],
): Promise<boolean> {
    const tx = new Transaction();
    call(tx, moveTarget, args(tx), typeArguments);
    return parseBool(returnBytes(await devInspect(runtime, label, tx)));
}

async function inspectU64(
    runtime: Runtime,
    label: string,
    moveTarget: string,
    args: (tx: Transaction) => TransactionArgument[],
): Promise<bigint> {
    const tx = new Transaction();
    call(tx, moveTarget, args(tx));
    return parseU64(returnBytes(await devInspect(runtime, label, tx)));
}

async function objectEvidence(
    runtime: Runtime,
    id: string,
    expectedType: string | "package",
    expectedOwner: "shared" | string | null,
): Promise<ObjectEvidence> {
    const objectId = normalizeId(id);
    const { object } = await runtime.client.getObject({
        objectId,
        include: {
            previousTransaction: true,
        },
    });
    const actualType = object.type;
    if (
        expectedType === "package" ? actualType !== "package" : !actualType.endsWith(expectedType)
    ) {
        throw new Error(`${objectId} has type ${actualType}, expected ${expectedType}`);
    }
    const actualOwner = ownerLabel(object.owner);
    const normalizedExpectedOwner =
        expectedOwner === "shared" || expectedOwner === null
            ? expectedOwner
            : expectedOwner.startsWith("party:")
              ? partyOwnerLabel(expectedOwner.slice("party:".length))
              : normalizeId(expectedOwner);
    if (
        normalizedExpectedOwner &&
        (normalizedExpectedOwner === "shared"
            ? actualOwner !== "shared"
            : actualOwner !== normalizedExpectedOwner)
    ) {
        throw new Error(
            `${objectId} is owned by ${actualOwner}, expected ${normalizedExpectedOwner}`,
        );
    }
    return {
        objectId,
        type: actualType,
        owner: actualOwner,
        version: String(object.version),
        digest: object.digest,
        previousTransaction: object.previousTransaction ?? null,
    };
}

export function sameObjectReference(left: ObjectEvidence, right: ObjectEvidence): boolean {
    return (
        left.objectId === right.objectId &&
        left.version === right.version &&
        left.digest === right.digest
    );
}

async function stableObjectSnapshot<T>(
    runtime: Runtime,
    id: string,
    expectedType: string,
    read: () => Promise<T>,
    attempts = 3,
): Promise<{ evidence: ObjectEvidence; value: T }> {
    for (let attempt = 0; attempt < attempts; attempt++) {
        const before = await objectEvidence(runtime, id, expectedType, "shared");
        const value = await read();
        const after = await objectEvidence(runtime, id, expectedType, "shared");
        if (sameObjectReference(before, after)) return { evidence: after, value };
    }
    throw new Error(`${normalizeId(id)} changed while its configuration snapshot was read`);
}

async function moveObjectFields(runtime: Runtime, id: string): Promise<Record<string, unknown>> {
    const { object } = await runtime.client.getObject({
        objectId: normalizeId(id),
        include: { json: true },
    });
    if (object.type === "package" || !object.json) throw new Error(`${id} is not a Move object`);
    return object.json;
}

async function verifyExternalDependencies(runtime: Runtime): Promise<{
    packages: Record<string, ObjectEvidence>;
    objects: Record<string, ObjectEvidence>;
}> {
    const packages: Record<string, ObjectEvidence> = {};
    for (const [name, id] of Object.entries(LINKED)) {
        packages[name] = await objectEvidence(runtime, id, "package", null);
    }
    const objects: Record<string, ObjectEvidence> = {
        clock: await objectEvidence(runtime, CLOCK_ID, "clock::Clock", "shared"),
        accumulatorRoot: await objectEvidence(
            runtime,
            ACCUMULATOR_ROOT_ID,
            "accumulator::AccumulatorRoot",
            "shared",
        ),
        pythLazerState: await objectEvidence(
            runtime,
            LINKED_OBJECTS.pythLazerState,
            `${LINKED.pyth_lazer}::state::State`,
            "shared",
        ),
        wormholeState: await objectEvidence(
            runtime,
            LINKED_OBJECTS.wormholeState,
            `${LINKED.wormhole}::state::State`,
            "shared",
        ),
        blockScholesSignerRegistry: await objectEvidence(
            runtime,
            LINKED_OBJECTS.blockScholesSignerRegistry,
            `${LINKED.bs_oracle}::registry::SignerRegistry`,
            "shared",
        ),
        deepbookRegistry: await objectEvidence(
            runtime,
            DEEPBOOK_REGISTRY,
            `${LINKED.deepbook}::registry::Registry`,
            "shared",
        ),
    };
    await objectEvidence(
        runtime,
        DEEPBOOK_ADMIN_CAP,
        `${LINKED.deepbook}::registry::DeepbookAdminCap`,
        partyOwnerLabel(DEEPBOOK_ADMIN_OWNER),
    );
    const signerRegistry = await moveObjectFields(
        runtime,
        LINKED_OBJECTS.blockScholesSignerRegistry,
    );
    const signerPubkey = signerRegistry.signer_pubkey;
    if (
        signerRegistry.paused !== false ||
        typeof signerPubkey !== "string" ||
        fromBase64(signerPubkey).length !== 33
    ) {
        throw new Error("Block Scholes signer registry is paused or has no valid signer");
    }
    const pythState = await moveObjectFields(runtime, LINKED_OBJECTS.pythLazerState);
    const trustedSigners = pythState.trusted_signers;
    const now = (await currentClockMs(runtime)) / 1_000n;
    if (
        !Array.isArray(trustedSigners) ||
        !trustedSigners.some((value) => {
            const expiresAt = asRecord(value).expires_at;
            return (
                (typeof expiresAt === "string" || typeof expiresAt === "number") &&
                /^[0-9]+$/.test(String(expiresAt)) &&
                BigInt(String(expiresAt)) > now
            );
        })
    ) {
        throw new Error("Pyth Lazer state has no unexpired trusted signer");
    }
    return { packages, objects };
}

async function accountAppAuthorized(
    runtime: Runtime,
    label: string,
    appType: string,
): Promise<boolean> {
    const result = runtime.result;
    const registry = sharedId(result, "account", "account_registry::AccountRegistry");
    return inspectBool(
        runtime,
        `is_${label}_authorized`,
        target(result, "account", "account_registry", "is_app_authorized"),
        (tx) => [tx.object(registry)],
        [appType],
    );
}

async function ensureAccountAppAuthorized(
    runtime: Runtime,
    label: string,
    appType: string,
): Promise<string | null> {
    const result = runtime.result;
    const registry = sharedId(result, "account", "account_registry::AccountRegistry");
    const transactionLabel = `authorize_${label}`;
    const authorized = await accountAppAuthorized(runtime, label, appType);
    if (!authorized) {
        const tx = new Transaction();
        call(
            tx,
            target(result, "account", "account_registry", "authorize_app"),
            [
                tx.object(registry),
                tx.object(capId(result, "account", "account_registry::AccountAdminCap")),
            ],
            [appType],
        );
        const receipt = await executeTransaction(runtime, transactionLabel, tx);
        if (!(await accountAppAuthorized(runtime, label, appType))) {
            throw new Error(`${appType} authorization did not read back true`);
        }
        return receipt.digest ?? null;
    }
    return result.transactions[transactionLabel] ?? null;
}

async function ensureAccountAppsAuthorized(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    result.wiring.account.authorizeTx = await ensureAccountAppAuthorized(
        runtime,
        "predict_app",
        `${packageId(result, "predict")}::predict_account::PredictApp`,
    );
    result.wiring.account.predictAppAuthorized = true;
    result.wiring.account.deepbookCoreAuthorizeTx = await ensureAccountAppAuthorized(
        runtime,
        "deepbook_core_app",
        `${packageId(result, "deepbook_core_account")}::account_data::DeepbookCoreAccountApp`,
    );
    result.wiring.account.deepbookCoreAppAuthorized = true;
    result.wiring.account.sessionsAuthorizeTx = await ensureAccountAppAuthorized(
        runtime,
        "sessions_app",
        `${packageId(result, "sessions")}::sessions::SessionsApp`,
    );
    result.wiring.account.sessionsAppAuthorized = true;
    writeState(result);
}

async function deepbookCoreAppAuthorized(runtime: Runtime): Promise<boolean> {
    const tx = new Transaction();
    call(
        tx,
        `${LINKED.deepbook}::registry::assert_app_is_authorized`,
        [tx.object(DEEPBOOK_REGISTRY)],
        [
            `${packageId(runtime.result, "deepbook_core_account")}::account_data::DeepbookCoreAccountApp`,
        ],
    );
    try {
        await devInspect(runtime, "is_deepbook_core_app_authorized", tx);
        return true;
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (message.includes("MoveAbort") && message.includes("registry")) return false;
        throw error;
    }
}

async function ensureDeepbookCoreAppAuthorized(runtime: Runtime): Promise<void> {
    const authorized = await deepbookCoreAppAuthorized(runtime);
    runtime.result.wiring.deepbook = {
        coreAppAuthorized: authorized,
        verifiedAt: new Date().toISOString(),
    };
    writeState(runtime.result);
    if (!authorized) {
        console.log(
            "[deploy] DeepBook core wrapper authorization is pending external admin-cap execution",
        );
    }
}

async function ensureLifecycleCap(runtime: Runtime): Promise<string> {
    const result = runtime.result;
    if (!result.wiring.lifecycleCap.id && result.transactions.mint_lifecycle_cap) {
        const receipt = await settledReceipt(
            runtime.client,
            result.transactions.mint_lifecycle_cap,
        );
        result.wiring.lifecycleCap.id = createdObjectId(
            receipt,
            "::market_lifecycle_cap::MarketLifecycleCap",
        );
        result.wiring.lifecycleCap.mintTx = receipt.digest ?? null;
        writeState(result);
    }
    const recorded = result.wiring.lifecycleCap.id;
    if (recorded) {
        const evidence = await objectEvidence(
            runtime,
            recorded,
            `${packageId(result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`,
            null,
        );
        if (evidence.owner === DEPLOYER) result.wiring.lifecycleCap.owner = "deployer";
        else if (evidence.owner === partyOwnerLabel(LIFECYCLE_CAP_RECIPIENT)) {
            result.wiring.lifecycleCap.owner = "recipient";
        } else {
            throw new Error(`lifecycle cap ${recorded} has unexpected owner ${evidence.owner}`);
        }
        result.wiring.lifecycleCap.mintTx ??= result.transactions.mint_lifecycle_cap ?? null;
        result.wiring.lifecycleCap.transferTx ??=
            result.transactions.transfer_lifecycle_cap_to_keeper ?? null;
        writeState(result);
        return recorded;
    }

    const tx = new Transaction();
    const cap = call(tx, target(result, "predict", "registry", "mint_lifecycle_cap"), [
        tx.object(sharedId(result, "predict", "registry::Registry")),
        tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
        tx.object(capId(result, "predict", "admin::AdminCap")),
    ]);
    tx.transferObjects([cap], tx.pure.address(DEPLOYER));
    const receipt = await executeTransaction(runtime, "mint_lifecycle_cap", tx);
    const id = createdObjectId(receipt, "::market_lifecycle_cap::MarketLifecycleCap");
    result.wiring.lifecycleCap.id = id;
    result.wiring.lifecycleCap.owner = "deployer";
    result.wiring.lifecycleCap.mintTx = receipt.digest ?? null;
    writeState(result);
    return id;
}

async function ensureOracleObjects(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    const oracleRegistry = sharedId(result, "propbook", "registry::OracleRegistry");
    const registryAdmin = capId(result, "propbook", "registry::RegistryAdminCap");

    let pythFeedId = await inspectOptionId(
        runtime,
        "propbook_pyth_id_for_source",
        target(result, "propbook", "registry", "propbook_pyth_id_for_source"),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.pythLazerFeedId)],
    );
    if (!pythFeedId) {
        const tx = new Transaction();
        call(tx, target(result, "propbook", "registry", "create_and_share_pyth_feed"), [
            tx.object(oracleRegistry),
            tx.pure.u32(ASSET.pythLazerFeedId),
        ]);
        const receipt = await executeTransaction(runtime, "create_pyth_feed", tx);
        pythFeedId = createdObjectId(receipt, "::pyth_feed::PythFeed");
        result.wiring.asset.pythFeedCreateTx = receipt.digest ?? null;
    }
    result.wiring.asset.pythFeedId = pythFeedId;
    result.wiring.asset.pythFeedCreateTx ??= result.transactions.create_pyth_feed ?? null;

    let storePair = await inspectBlockScholesStorePair(
        runtime,
        "block_scholes_store_pair_for_underlying",
        oracleRegistry,
    );
    if (!storePair) {
        const tx = new Transaction();
        call(tx, target(result, "propbook", "registry", "create_and_share_block_scholes_stores"), [
            tx.object(oracleRegistry),
            tx.object(registryAdmin),
            tx.pure.u32(ASSET.propbookUnderlyingId),
            tx.pure.string(ASSET.blockScholesBaseAsset),
        ]);
        const receipt = await executeTransaction(runtime, "create_block_scholes_stores", tx);
        const createdPair = {
            valueStoreId: createdObjectId(receipt, "::block_scholes_store::BlockScholesValueStore"),
            sviStoreId: createdObjectId(receipt, "::block_scholes_store::BlockScholesSVIStore"),
        };
        storePair = await inspectBlockScholesStorePair(
            runtime,
            "created_block_scholes_store_pair",
            oracleRegistry,
        );
        if (
            !storePair ||
            storePair.valueStoreId !== createdPair.valueStoreId ||
            storePair.sviStoreId !== createdPair.sviStoreId
        ) {
            throw new Error("created Block Scholes stores do not match the canonical pair");
        }
        result.wiring.asset.blockScholesStoresCreateTx = receipt.digest ?? null;
    }
    await assertBlockScholesStoreBaseAssets(runtime, storePair);
    result.wiring.asset.blockScholesValueStoreId = storePair.valueStoreId;
    result.wiring.asset.blockScholesSviStoreId = storePair.sviStoreId;
    result.wiring.asset.blockScholesStoresCreateTx ??=
        result.transactions.create_block_scholes_stores ?? null;

    const boundPyth = await inspectOptionId(
        runtime,
        "propbook_pyth_id_for_underlying",
        target(result, "propbook", "registry", "propbook_pyth_id_for_underlying"),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    if (!boundPyth) {
        const tx = new Transaction();
        call(tx, target(result, "propbook", "registry", "bind_pyth_to_underlying"), [
            tx.object(oracleRegistry),
            tx.object(registryAdmin),
            tx.object(pythFeedId),
            tx.pure.u32(ASSET.propbookUnderlyingId),
        ]);
        const receipt = await executeTransaction(runtime, "bind_pyth_to_underlying", tx);
        result.wiring.asset.pythBindTx = receipt.digest ?? null;
    } else if (boundPyth !== pythFeedId) {
        throw new Error(`underlying ${ASSET.propbookUnderlyingId} is bound to Pyth ${boundPyth}`);
    }
    result.wiring.asset.pythBindTx ??= result.transactions.bind_pyth_to_underlying ?? null;
    writeState(result);
}

export function isUnderlyingNotRegisteredError(error: unknown): boolean {
    const message = error instanceof Error ? error.message : String(error);
    return (
        message.includes("MoveAbort") &&
        message.includes("market_manager") &&
        message.includes("underlying_config") &&
        /},\s*0\)(?:\s|$)/.test(message)
    );
}

async function predictUnderlyingRegistered(runtime: Runtime): Promise<boolean> {
    const tx = new Transaction();
    call(tx, target(runtime.result, "predict", "registry", "cadence_configs"), [
        tx.object(sharedId(runtime.result, "predict", "registry::Registry")),
        tx.pure.u32(ASSET.propbookUnderlyingId),
    ]);
    try {
        await devInspect(runtime, "predict_underlying_registered", tx);
        return true;
    } catch (error) {
        if (isUnderlyingNotRegisteredError(error)) return false;
        throw error;
    }
}

async function ensureUnderlyingRegistered(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    if (!(await predictUnderlyingRegistered(runtime))) {
        const tx = new Transaction();
        call(tx, target(result, "predict", "registry", "register_underlying"), [
            tx.object(sharedId(result, "predict", "registry::Registry")),
            tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
            tx.object(capId(result, "predict", "admin::AdminCap")),
            tx.pure.u32(ASSET.propbookUnderlyingId),
        ]);
        const receipt = await executeTransaction(runtime, "register_predict_underlying", tx);
        result.wiring.asset.predictUnderlyingRegisteredTx = receipt.digest ?? null;
        if (!(await predictUnderlyingRegistered(runtime))) {
            throw new Error("Predict underlying registration did not persist on-chain");
        }
    }
    result.wiring.asset.predictUnderlyingRegistered = true;
    result.wiring.asset.predictUnderlyingRegisteredTx ??=
        result.transactions.register_predict_underlying ?? null;
    writeState(result);
}

async function readCadence(runtime: Runtime, spec: CadenceSpec): Promise<CadenceRecord> {
    const result = runtime.result;
    const registry = sharedId(result, "predict", "registry::Registry");
    const tx = new Transaction();
    const getters = [
        "cadence_tick_size",
        "cadence_admission_tick_size",
        "cadence_max_expiry_allocation",
        "cadence_initial_expiry_cash",
        "cadence_window_size",
    ];
    for (const getter of getters) {
        const config = call(tx, target(result, "predict", "registry", "cadence_config"), [
            tx.object(registry),
            tx.pure.u32(ASSET.propbookUnderlyingId),
            tx.pure.u8(spec.id),
        ]);
        call(tx, target(result, "predict", "market_manager", getter), [config]);
    }
    const response = await devInspect(runtime, `read_${spec.name}_cadence`, tx);
    const values = getters.map((_, index) => parseU64(returnBytes(response, index * 2 + 1)));
    return {
        id: spec.id,
        name: spec.name,
        tickSize: values[0].toString(),
        admissionTickSize: values[1].toString(),
        maxExpiryAllocation: values[2].toString(),
        initialExpiryCash: values[3].toString(),
        windowSize: values[4].toString(),
        setTx: result.transactions.set_cadence_configs ?? null,
    };
}

async function readCadences(runtime: Runtime): Promise<CadenceRecord[]> {
    const records: CadenceRecord[] = [];
    for (const cadence of CADENCES) records.push(await readCadence(runtime, cadence));
    return records;
}

async function ensureCadences(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    const current = await readCadences(runtime);
    if (!current.every((record, index) => cadenceMatches(record, CADENCES[index]))) {
        const tx = new Transaction();
        for (const cadence of CADENCES) {
            call(tx, target(result, "predict", "registry", "set_template_cadence_config"), [
                tx.object(sharedId(result, "predict", "registry::Registry")),
                tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
                tx.object(capId(result, "predict", "admin::AdminCap")),
                tx.pure.u32(ASSET.propbookUnderlyingId),
                tx.pure.u8(cadence.id),
                tx.pure.u64(cadence.tickSize),
                tx.pure.u64(cadence.admissionTickSize),
                tx.pure.u64(cadence.maxExpiryAllocation),
                tx.pure.u64(cadence.initialExpiryCash),
                tx.pure.u64(cadence.windowSize),
            ]);
        }
        const receipt = await executeTransaction(runtime, "set_cadence_configs", tx);
        result.wiring.cadences = CADENCES.map((cadence) =>
            expectedCadenceRecord(cadence, receipt.digest ?? null),
        );
        writeState(result);
    }
    const verified = await readCadences(runtime);
    if (!verified.every((record, index) => cadenceMatches(record, CADENCES[index]))) {
        throw new Error("on-chain cadence configuration does not match the deployment policy");
    }
    result.wiring.cadences = verified;
    writeState(result);
}

async function ensureAccountWrapper(runtime: Runtime): Promise<string> {
    const result = runtime.result;
    const registry = sharedId(result, "account", "account_registry::AccountRegistry");
    const exists = await inspectBool(
        runtime,
        "derived_wrapper_exists",
        target(result, "account", "account_registry", "derived_wrapper_exists"),
        (tx) => [tx.object(registry), tx.pure.address(DEPLOYER)],
    );
    let wrapperId: string;
    if (!exists) {
        const tx = new Transaction();
        const wrapper = call(tx, target(result, "account", "account_registry", "new"), [
            tx.object(registry),
        ]);
        call(tx, target(result, "account", "account", "share"), [wrapper]);
        const receipt = await executeTransaction(runtime, "create_deployer_account", tx);
        wrapperId = createdObjectId(receipt, "::account::AccountWrapper");
        result.wiring.account.createAccountTx = receipt.digest ?? null;
    } else {
        const tx = new Transaction();
        call(tx, target(result, "account", "account_registry", "derived_wrapper_address"), [
            tx.object(registry),
            tx.pure.address(DEPLOYER),
        ]);
        wrapperId = parseAddress(
            returnBytes(await devInspect(runtime, "derived_wrapper_address", tx)),
        );
    }
    if (
        result.wiring.account.accountWrapperId &&
        result.wiring.account.accountWrapperId !== wrapperId
    ) {
        throw new Error(
            `recorded account wrapper ${result.wiring.account.accountWrapperId} != ${wrapperId}`,
        );
    }
    result.wiring.account.accountWrapperId = wrapperId;
    result.wiring.account.createAccountTx ??= result.transactions.create_deployer_account ?? null;
    writeState(result);
    return wrapperId;
}

function generateOwnerAuth(result: DeploymentResult, tx: Transaction): TransactionResult {
    return call(tx, target(result, "account", "account", "generate_auth"), []);
}

async function deploymentAccountId(runtime: Runtime, accountWrapperId: string): Promise<string> {
    const tx = new Transaction();
    const account = call(tx, target(runtime.result, "account", "account", "load_account"), [
        tx.object(accountWrapperId),
    ]);
    call(tx, target(runtime.result, "account", "account", "account_id"), [account]);
    return parseAddress(returnBytes(await devInspect(runtime, "deployment_account_id", tx), 1));
}

async function deploymentAccountPlpBalance(
    runtime: Runtime,
    accountWrapperId: string,
): Promise<bigint> {
    const tx = new Transaction();
    const account = call(tx, target(runtime.result, "account", "account", "load_account"), [
        tx.object(accountWrapperId),
    ]);
    call(
        tx,
        target(runtime.result, "account", "account", "balance"),
        [account, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
        [plpType(runtime.result)],
    );
    return parseU64(
        returnBytes(await devInspect(runtime, "deployment_account_plp_balance", tx), 1),
    );
}

async function poolU64(runtime: Runtime, fn: string): Promise<bigint> {
    return inspectU64(runtime, fn, target(runtime.result, "predict", "plp", fn), (tx) => [
        tx.object(sharedId(runtime.result, "predict", "plp::PoolVault")),
    ]);
}

function integerEventField(fields: Record<string, unknown>, name: string): string {
    const value = fields[name];
    if (typeof value !== "string" && typeof value !== "number") {
        throw new Error(`bootstrap event field ${name} is not numeric`);
    }
    return String(value);
}

function validateBootstrapReceipt(
    receipt: Receipt,
    vaultId: string,
    accountId: string,
    accountWrapperId: string,
): { requestIndex: string; sharesMinted: string } {
    const requested = asRecord(eventNamed(receipt, "SupplyRequested")?.parsedJson);
    const filled = asRecord(eventNamed(receipt, "SupplyFilled")?.parsedJson);
    if (Object.keys(requested).length === 0 || Object.keys(filled).length === 0) {
        throw new Error(`bootstrap transaction ${receipt.digest} is missing supply events`);
    }
    const requestIndex = integerEventField(requested, "index");
    const sharesMinted = integerEventField(filled, "shares_minted");
    const expected = [
        [normalizeOptionalId(requested.pool_vault_id), vaultId, "requested pool"],
        [normalizeOptionalId(filled.pool_vault_id), vaultId, "filled pool"],
        [normalizeOptionalId(requested.account_id), accountId, "requested account"],
        [normalizeOptionalId(filled.account_id), accountId, "filled account"],
        [normalizeOptionalId(requested.recipient), accountWrapperId, "requested recipient"],
        [normalizeOptionalId(filled.recipient), accountWrapperId, "filled recipient"],
    ] as const;
    for (const [actual, wanted, label] of expected) {
        if (actual !== wanted) throw new Error(`${label} is ${actual}, expected ${wanted}`);
    }
    if (
        integerEventField(requested, "amount") !== BOOTSTRAP_SUPPLY_AMOUNT.toString() ||
        integerEventField(requested, "min_plp_out") !== "0" ||
        integerEventField(requested, "requests_pending_after") !== "1" ||
        integerEventField(filled, "index") !== requestIndex ||
        integerEventField(filled, "dusdc_amount") !== BOOTSTRAP_SUPPLY_AMOUNT.toString() ||
        sharesMinted !== BOOTSTRAP_SUPPLY_AMOUNT.toString() ||
        integerEventField(filled, "dusdc_remaining") !== "0" ||
        integerEventField(filled, "requests_pending_after") !== "0"
    ) {
        throw new Error(`bootstrap transaction ${receipt.digest} has unexpected supply events`);
    }
    return { requestIndex, sharesMinted };
}

async function ensureBootstrap(
    runtime: Runtime,
    lifecycleCapId: string,
    accountWrapperId: string,
): Promise<void> {
    const result = runtime.result;
    const vault = sharedId(result, "predict", "plp::PoolVault");
    const config = sharedId(result, "predict", "protocol_config::ProtocolConfig");
    const accountId = await deploymentAccountId(runtime, accountWrapperId);
    let totalSupply = await poolU64(runtime, "plp_total_supply");
    let pendingSupply = await poolU64(runtime, "supply_requests_pending");
    let pendingWithdraw = await poolU64(runtime, "withdraw_requests_pending");
    let accountPlpBalance = await deploymentAccountPlpBalance(runtime, accountWrapperId);
    if (totalSupply === 0n) {
        if (pendingSupply !== 0n || pendingWithdraw !== 0n || accountPlpBalance !== 0n) {
            throw new Error(
                `nonempty bootstrap state supply=${pendingSupply} withdraw=${pendingWithdraw} accountPLP=${accountPlpBalance}`,
            );
        }
        const tx = new Transaction();
        const lockPayment = coinWithBalance({
            type: dusdcType(),
            balance: LOCK_CAPITAL_AMOUNT,
            useGasCoin: false,
        })(tx);
        call(tx, target(result, "predict", "plp", "lock_capital"), [
            tx.object(vault),
            tx.object(config),
            tx.object(capId(result, "predict", "admin::AdminCap")),
            lockPayment,
        ]);
        const supplyPayment = coinWithBalance({
            type: dusdcType(),
            balance: BOOTSTRAP_SUPPLY_AMOUNT,
            useGasCoin: false,
        })(tx);
        const depositAuth = generateOwnerAuth(result, tx);
        call(
            tx,
            target(result, "account", "account", "deposit_funds"),
            [
                tx.object(accountWrapperId),
                depositAuth,
                supplyPayment,
                tx.object(ACCUMULATOR_ROOT_ID),
                tx.object(CLOCK_ID),
            ],
            [dusdcType()],
        );
        const supplyAuth = generateOwnerAuth(result, tx);
        call(tx, target(result, "predict", "plp", "request_supply"), [
            tx.object(vault),
            tx.object(accountWrapperId),
            supplyAuth,
            tx.object(config),
            tx.pure.u64(BOOTSTRAP_SUPPLY_AMOUNT),
            tx.pure.u64(0),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.object(CLOCK_ID),
        ]);
        const proof = call(tx, target(result, "predict", "registry", "generate_lifecycle_proof"), [
            tx.object(sharedId(result, "predict", "registry::Registry")),
            tx.object(lifecycleCapId),
        ]);
        const valuation = call(tx, target(result, "predict", "plp", "start_pool_valuation"), [
            tx.object(config),
            tx.object(vault),
            proof,
        ]);
        call(tx, target(result, "predict", "plp", "finish_flush"), [
            valuation,
            tx.object(vault),
            tx.object(config),
            tx.pure.option("u64", 1),
            tx.pure.option("u64", 0),
        ]);
        const receipt = await executeTransaction(runtime, "bootstrap_pool", tx);
        const eventState = validateBootstrapReceipt(receipt, vault, accountId, accountWrapperId);
        result.wiring.bootstrap.accountId = accountId;
        result.wiring.bootstrap.requestIndex = eventState.requestIndex;
        result.wiring.bootstrap.sharesMinted = eventState.sharesMinted;
        result.wiring.bootstrap.lockCapitalTx = receipt.digest ?? null;
        result.wiring.bootstrap.supplyRequestTx = receipt.digest ?? null;
        result.wiring.bootstrap.flushTx = receipt.digest ?? null;
        writeState(result);
    }
    totalSupply = await poolU64(runtime, "plp_total_supply");
    pendingSupply = await poolU64(runtime, "supply_requests_pending");
    pendingWithdraw = await poolU64(runtime, "withdraw_requests_pending");
    accountPlpBalance = await deploymentAccountPlpBalance(runtime, accountWrapperId);
    const bootstrapDigest = result.transactions.bootstrap_pool;
    if (
        totalSupply !== LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT ||
        pendingSupply !== 0n ||
        pendingWithdraw !== 0n ||
        accountPlpBalance !== BOOTSTRAP_SUPPLY_AMOUNT ||
        !bootstrapDigest
    ) {
        throw new Error(
            `bootstrap incomplete: totalSupply=${totalSupply} pending=${pendingSupply}/${pendingWithdraw} accountPLP=${accountPlpBalance} tx=${bootstrapDigest}`,
        );
    }
    if (
        !result.wiring.bootstrap.requestIndex ||
        !result.wiring.bootstrap.sharesMinted ||
        result.wiring.bootstrap.accountId !== accountId
    ) {
        const receipt = await settledReceipt(runtime.client, bootstrapDigest);
        const eventState = validateBootstrapReceipt(receipt, vault, accountId, accountWrapperId);
        result.wiring.bootstrap.accountId = accountId;
        result.wiring.bootstrap.requestIndex = eventState.requestIndex;
        result.wiring.bootstrap.sharesMinted = eventState.sharesMinted;
    }
    result.wiring.bootstrap.accountPlpBalance = accountPlpBalance.toString();
    result.wiring.bootstrap.lockCapitalTx = bootstrapDigest;
    result.wiring.bootstrap.supplyRequestTx = bootstrapDigest;
    result.wiring.bootstrap.flushTx = bootstrapDigest;
    writeState(result);
}

async function activeMarketIds(runtime: Runtime): Promise<string[]> {
    const tx = new Transaction();
    call(tx, target(runtime.result, "predict", "plp", "active_expiry_markets"), [
        tx.object(sharedId(runtime.result, "predict", "plp::PoolVault")),
    ]);
    return parseIdVector(returnBytes(await devInspect(runtime, "active_expiry_markets", tx)));
}

async function marketState(
    runtime: Runtime,
    id: string,
): Promise<{
    underlying: number;
    expiryMs: bigint;
    referenceTickSourceTimestampMs: bigint;
    cashBalance: bigint;
}> {
    const result = runtime.result;
    const tx = new Transaction();
    call(tx, target(result, "predict", "expiry_market", "propbook_underlying_id"), [tx.object(id)]);
    call(tx, target(result, "predict", "expiry_market", "expiry"), [tx.object(id)]);
    call(tx, target(result, "predict", "expiry_market", "reference_tick_source_timestamp_ms"), [
        tx.object(id),
    ]);
    call(tx, target(result, "predict", "expiry_market", "cash_balance"), [tx.object(id)]);
    const response = await devInspect(runtime, `market_state_${id}`, tx);
    return {
        underlying: parseU32(returnBytes(response, 0)),
        expiryMs: parseU64(returnBytes(response, 1)),
        referenceTickSourceTimestampMs: parseU64(returnBytes(response, 2)),
        cashBalance: parseU64(returnBytes(response, 3)),
    };
}

function cadenceForPeriod(periodMs: bigint): CadenceSpec {
    const match = CADENCES.find(
        (cadence) => cadence.windowSize > 0n && BigInt(cadence.periodMs) === periodMs,
    );
    if (!match) throw new Error(`cannot infer cadence for period ${periodMs}`);
    return match;
}

function cadenceForMarketLabel(label: string): CadenceSpec {
    const name = label.match(/^create_market_([^_]+)_[0-9]+$/)?.[1];
    const match = CADENCES.find((cadence) => cadence.windowSize > 0n && cadence.name === name);
    if (!match) throw new Error(`cannot infer cadence from transaction label ${label}`);
    return match;
}

function marketFromEvent(receipt: Receipt, cadence: CadenceSpec): MarketRecord {
    const event = eventNamed(receipt, "MarketCreated");
    const parsed = asRecord(event?.parsedJson);
    const id =
        normalizeOptionalId(parsed.expiry_market_id) ??
        createdObjectId(receipt, "::expiry_market::ExpiryMarket");
    const expiry = parsed.expiry;
    if (typeof expiry !== "string" && typeof expiry !== "number") {
        throw new Error(`MarketCreated in ${receipt.digest} has no expiry`);
    }
    return {
        id,
        cadenceId: cadence.id,
        cadence: cadence.name,
        expiryMs: String(expiry),
        tickSize: String(parsed.tick_size ?? cadence.tickSize),
        admissionTickSize: String(parsed.admission_tick_size ?? cadence.admissionTickSize),
        maxExpiryAllocation: String(parsed.max_expiry_allocation ?? cadence.maxExpiryAllocation),
        initialExpiryCash: String(parsed.initial_expiry_cash ?? cadence.initialExpiryCash),
        createTx: receipt.digest ?? null,
        rebalanceTx: null,
        cashBalance: "0",
    };
}

async function rebuildMarketsFromTransactions(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    const byId = new Map(result.wiring.markets.map((market) => [market.id, market]));
    for (const [label, digest] of Object.entries(result.transactions)) {
        if (!label.startsWith("create_market_")) continue;
        if (result.wiring.markets.some((market) => market.createTx === digest)) continue;
        const receipt = await settledReceipt(runtime.client, digest);
        const event = eventNamed(receipt, "MarketCreated");
        const parsed = asRecord(event?.parsedJson);
        if (typeof parsed.expiry !== "string" && typeof parsed.expiry !== "number") {
            throw new Error(`${label}/${digest} has no MarketCreated expiry`);
        }
        const cadence = cadenceForMarketLabel(label);
        const market = marketFromEvent(receipt, cadence);
        const existing = byId.get(market.id);
        if (existing) {
            existing.createTx ??= digest;
        } else {
            result.wiring.markets.push(market);
            byId.set(market.id, market);
        }
    }
    writeState(result);
}

async function discoverMarkets(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    await rebuildMarketsFromTransactions(runtime);
    const byId = new Map(result.wiring.markets.map((market) => [market.id, market]));
    for (const id of await activeMarketIds(runtime)) {
        const state = await marketState(runtime, id);
        if (state.underlying !== ASSET.propbookUnderlyingId) {
            throw new Error(`active market ${id} belongs to underlying ${state.underlying}`);
        }
        if (state.referenceTickSourceTimestampMs >= state.expiryMs) {
            throw new Error(
                `active market ${id} has invalid reference timestamp ${state.referenceTickSourceTimestampMs}`,
            );
        }
        const cadence = cadenceForPeriod(state.expiryMs - state.referenceTickSourceTimestampMs);
        const existing = byId.get(id);
        if (existing) {
            existing.cashBalance = state.cashBalance.toString();
            existing.rebalanceTx ??= result.transactions[`rebalance_market_${id}`] ?? null;
        } else {
            const evidence = await objectEvidence(
                runtime,
                id,
                `${packageId(result, "predict")}::expiry_market::ExpiryMarket`,
                "shared",
            );
            const market: MarketRecord = {
                id,
                cadenceId: cadence.id,
                cadence: cadence.name,
                expiryMs: state.expiryMs.toString(),
                tickSize: cadence.tickSize.toString(),
                admissionTickSize: cadence.admissionTickSize.toString(),
                maxExpiryAllocation: cadence.maxExpiryAllocation.toString(),
                initialExpiryCash: cadence.initialExpiryCash.toString(),
                createTx: state.cashBalance === 0n ? evidence.previousTransaction : null,
                rebalanceTx: state.cashBalance > 0n ? evidence.previousTransaction : null,
                cashBalance: state.cashBalance.toString(),
            };
            result.wiring.markets.push(market);
            byId.set(id, market);
        }
    }
    result.wiring.markets.sort((left, right) =>
        Number(BigInt(left.expiryMs) - BigInt(right.expiryMs)),
    );
    writeState(result);
}

async function currentClockMs(runtime: Runtime): Promise<bigint> {
    return inspectU64(runtime, "clock_timestamp_ms", "0x2::clock::timestamp_ms", (tx) => [
        tx.object(CLOCK_ID),
    ]);
}

async function waitForCadenceLead(runtime: Runtime, cadence: CadenceSpec): Promise<void> {
    const now = Number(await currentClockMs(runtime));
    const nextExpiry = (Math.floor(now / cadence.periodMs) + 1) * cadence.periodMs;
    const lead = nextExpiry - now;
    const minimumLead = Math.min(90_000, Math.floor(cadence.periodMs / 2));
    if (lead >= minimumLead) return;
    const wait = lead + 1_500;
    console.log(
        `[deploy] ${cadence.name} next slot has ${lead}ms lead; waiting ${wait}ms for a fresh slot`,
    );
    await new Promise((done) => setTimeout(done, wait));
}

function isCadenceWindowFull(error: unknown): boolean {
    return (
        error instanceof DryRunFailure &&
        error.detail.includes("market_manager") &&
        (/,\s*5\)?/.test(error.detail) || /"abortCode":"5"/.test(error.detail))
    );
}

function marketCreationTransaction(
    result: DeploymentResult,
    lifecycleCapId: string,
    cadence: CadenceSpec,
): Transaction {
    const tx = new Transaction();
    call(tx, target(result, "predict", "registry", "create_and_share_expiry_market"), [
        tx.object(sharedId(result, "predict", "registry::Registry")),
        tx.object(sharedId(result, "predict", "plp::PoolVault")),
        tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
        tx.object(sharedId(result, "propbook", "registry::OracleRegistry")),
        tx.object(lifecycleCapId),
        tx.pure.u32(ASSET.propbookUnderlyingId),
        tx.pure.u8(cadence.id),
        tx.object(CLOCK_ID),
    ]);
    return tx;
}

function nextMarketLabel(result: DeploymentResult, cadence: CadenceSpec): string {
    let sequence = 0;
    while (result.transactions[`create_market_${cadence.name}_${sequence}`]) sequence++;
    return `create_market_${cadence.name}_${sequence}`;
}

async function liveMarketSnapshot(runtime: Runtime): Promise<{
    clockMs: bigint;
    markets: MarketRecord[];
}> {
    const [clockMs, activeIds] = await Promise.all([
        currentClockMs(runtime),
        activeMarketIds(runtime),
    ]);
    const active = new Set(activeIds);
    return {
        clockMs,
        markets: runtime.result.wiring.markets.filter(
            (market) => active.has(market.id) && BigInt(market.expiryMs) > clockMs,
        ),
    };
}

async function assertLiveMarketWindows(
    runtime: Runtime,
    lifecycleCapId: string,
    canProbe: boolean,
): Promise<void> {
    await discoverMarkets(runtime);
    const snapshot = await liveMarketSnapshot(runtime);
    const checks: WiringState["marketWindowChecks"] = [];
    for (const cadence of CADENCES.filter((candidate) => candidate.marketsToCreate > 0)) {
        const recorded = snapshot.markets.filter(
            (market) => market.cadenceId === cadence.id,
        ).length;
        let windowFull = false;
        if (recorded < cadence.marketsToCreate) {
            if (canProbe) {
                const tx = marketCreationTransaction(runtime.result, lifecycleCapId, cadence);
                tx.setSender(DEPLOYER);
                tx.setGasBudget(TRANSACTION_GAS_BUDGET);
                const bytes = await tx.build({ client: runtime.client });
                try {
                    await dryRun(runtime, `check_${cadence.name}_market_window`, bytes);
                } catch (error) {
                    if (!isCadenceWindowFull(error)) throw error;
                    windowFull = true;
                }
                if (!windowFull) {
                    throw new Error(`${cadence.name} still has a deployable market slot`);
                }
            } else {
                const prior = runtime.result.wiring.marketWindowChecks.find(
                    (check) => check.cadenceId === cadence.id,
                );
                if (
                    !prior?.windowFull ||
                    prior.recorded !== recorded ||
                    !prior.checkedAtChainMs ||
                    snapshot.clockMs < BigInt(prior.checkedAtChainMs) ||
                    snapshot.clockMs / BigInt(cadence.periodMs) !==
                        BigInt(prior.checkedAtChainMs) / BigInt(cadence.periodMs)
                ) {
                    throw new Error(
                        `${cadence.name} has only ${recorded}/${cadence.marketsToCreate} future markets after lifecycle-cap handoff`,
                    );
                }
                windowFull = true;
            }
        }
        checks.push({
            cadenceId: cadence.id,
            cadence: cadence.name,
            target: cadence.marketsToCreate,
            recorded,
            windowFull,
            checkedAtChainMs: snapshot.clockMs.toString(),
            checkedAt: new Date().toISOString(),
        });
    }
    if (canProbe) {
        runtime.result.wiring.marketWindowChecks = checks;
        writeState(runtime.result);
    }
}

async function rebalanceMarket(runtime: Runtime, market: MarketRecord): Promise<void> {
    if (market.cashBalance && BigInt(market.cashBalance) > 0n) return;
    const result = runtime.result;
    const tx = new Transaction();
    call(tx, target(result, "predict", "plp", "rebalance_expiry_cash"), [
        tx.object(sharedId(result, "predict", "plp::PoolVault")),
        tx.object(market.id),
        tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
        tx.object(CLOCK_ID),
    ]);
    const label = `rebalance_market_${market.id}`;
    const receipt = await executeTransaction(runtime, label, tx);
    market.rebalanceTx = receipt.digest ?? null;
    market.cashBalance = (await marketState(runtime, market.id)).cashBalance.toString();
    if (BigInt(market.cashBalance) === 0n) {
        throw new Error(`market ${market.id} remained unfunded after rebalance`);
    }
    writeState(result);
}

async function ensureMarkets(runtime: Runtime, lifecycleCapId: string): Promise<void> {
    const result = runtime.result;
    if (result.wiring.lifecycleCap.owner === "recipient") {
        await assertLiveMarketWindows(runtime, lifecycleCapId, false);
        return;
    }
    await discoverMarkets(runtime);
    for (const market of (await liveMarketSnapshot(runtime)).markets) {
        await rebalanceMarket(runtime, market);
    }

    const enabledCadences = CADENCES.filter((candidate) => candidate.marketsToCreate > 0)
        .slice()
        .sort((left, right) => right.periodMs - left.periodMs);
    for (const cadence of enabledCadences) {
        while (
            (await liveMarketSnapshot(runtime)).markets.filter(
                (market) => market.cadenceId === cadence.id,
            ).length < cadence.marketsToCreate
        ) {
            const creationLimit = cadence.marketsToCreate + MARKET_ROLLOVER_RESERVE_PER_CADENCE;
            const creationsThisRun = runtime.marketCreationsThisRun[cadence.id] ?? 0;
            if (creationsThisRun >= creationLimit) {
                throw new Error(
                    `${cadence.name} exceeded its per-run market rollover bound (${creationLimit}); preserve the journal and resume`,
                );
            }
            await waitForCadenceLead(runtime, cadence);
            const tx = marketCreationTransaction(result, lifecycleCapId, cadence);
            const label = nextMarketLabel(result, cadence);
            let receipt: Receipt;
            try {
                receipt = await executeTransaction(runtime, label, tx);
            } catch (error) {
                if (isCadenceWindowFull(error)) {
                    console.log(`[deploy] ${cadence.name} cadence window is full`);
                    break;
                }
                throw error;
            }
            runtime.marketCreationsThisRun[cadence.id] = creationsThisRun + 1;
            const market = marketFromEvent(receipt, cadence);
            result.wiring.markets.push(market);
            writeState(result);
            await rebalanceMarket(runtime, market);
        }
    }
    await assertLiveMarketWindows(runtime, lifecycleCapId, true);
}

async function transferLifecycleCap(runtime: Runtime, lifecycleCapId: string): Promise<void> {
    const result = runtime.result;
    const evidence = await objectEvidence(
        runtime,
        lifecycleCapId,
        `${packageId(result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`,
        null,
    );
    if (evidence.owner === partyOwnerLabel(LIFECYCLE_CAP_RECIPIENT)) {
        result.wiring.lifecycleCap.owner = "recipient";
        result.wiring.lifecycleCap.transferTx ??=
            result.transactions.transfer_lifecycle_cap_to_keeper ?? null;
        writeState(result);
        return;
    }
    if (evidence.owner !== DEPLOYER) {
        throw new Error(`lifecycle cap is owned by ${evidence.owner}, expected ${DEPLOYER}`);
    }
    const tx = new Transaction();
    const party = call(tx, "0x2::party::single_owner", [tx.pure.address(LIFECYCLE_CAP_RECIPIENT)]);
    call(
        tx,
        "0x2::transfer::public_party_transfer",
        [tx.object(lifecycleCapId), party],
        [`${packageId(result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`],
    );
    const receipt = await executeTransaction(runtime, "transfer_lifecycle_cap_to_keeper", tx);
    await objectEvidence(
        runtime,
        lifecycleCapId,
        `${packageId(result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`,
        partyOwnerLabel(LIFECYCLE_CAP_RECIPIENT),
    );
    result.wiring.lifecycleCap.owner = "recipient";
    result.wiring.lifecycleCap.transferTx = receipt.digest ?? null;
    writeState(result);
}

function boolField(fields: Record<string, unknown>, name: string): boolean {
    const value = fields[name];
    if (typeof value !== "boolean") throw new Error(`ProtocolConfig.${name} is not a bool`);
    return value;
}

function stringField(fields: Record<string, unknown>, name: string): string {
    const value = fields[name];
    if (typeof value !== "string" && typeof value !== "number") {
        throw new Error(`ProtocolConfig.${name} is not numeric`);
    }
    return String(value);
}

async function readProtocolConfig(runtime: Runtime): Promise<Verification["protocolConfig"]> {
    const fields = await moveObjectFields(
        runtime,
        sharedId(runtime.result, "predict", "protocol_config::ProtocolConfig"),
    );
    const pricing = asRecord(fields.pricing_config);
    const ewma = asRecord(fields.ewma_config);
    const strike = asRecord(fields.strike_exposure_template_config);
    const config: ProtocolConfigRecord = {
        usePythSpotForForward: boolField(pricing, "use_pyth_spot_for_forward"),
        pythSpotFreshnessMs: stringField(pricing, "pyth_spot_freshness_ms"),
        blockScholesPriceFreshnessMs: stringField(pricing, "block_scholes_price_freshness_ms"),
        blockScholesSviFreshnessMs: stringField(pricing, "block_scholes_svi_freshness_ms"),
        ewmaAlpha: stringField(ewma, "alpha"),
        ewmaZScoreThreshold: stringField(ewma, "z_score_threshold"),
        ewmaPenaltyRate: stringField(ewma, "penalty_rate"),
        ewmaEnabled: boolField(ewma, "enabled"),
        protocolReserveProfitShare: stringField(fields, "protocol_reserve_profit_share"),
        referralFeeRate: stringField(fields, "referral_fee_rate"),
        plpSupplyFeeRate: stringField(fields, "plp_supply_fee_rate"),
        plpWithdrawFeeRate: stringField(fields, "plp_withdraw_fee_rate"),
        lpRequestLimitFlushAttempts: stringField(fields, "lp_request_limit_flush_attempts"),
        maxLpPoolValue: stringField(fields, "max_lp_pool_value"),
        backingBufferLambda: stringField(strike, "backing_buffer_lambda"),
        inventoryImpactMaxRate: stringField(strike, "inventory_impact_max_rate"),
        baseFee: stringField(strike, "base_fee"),
        minFee: stringField(strike, "min_fee"),
        minEntryProbability: stringField(strike, "min_entry_probability"),
        maxEntryProbability: stringField(strike, "max_entry_probability"),
        expiryFeeWindowMs: stringField(strike, "expiry_fee_window_ms"),
        expiryFeeMaxMultiplier: stringField(strike, "expiry_fee_max_multiplier"),
        versionWatermark: stringField(fields, "version_watermark"),
        tradingPaused: boolField(fields, "trading_paused"),
        frozen: boolField(fields, "frozen"),
        valuationInProgress: boolField(fields, "valuation_in_progress"),
    };
    if (JSON.stringify(config) !== JSON.stringify(EXPECTED_PROTOCOL_CONFIG)) {
        throw new Error(`ProtocolConfig defaults are unexpected: ${JSON.stringify(config)}`);
    }
    return config;
}

async function verifyDeployment(runtime: Runtime): Promise<Verification> {
    const result = runtime.result;
    await assertSdkTarget(runtime);
    const external = await verifyExternalDependencies(runtime);
    if (!result.wiring.lifecycleCap.id) throw new Error("lifecycle cap is missing");
    await assertLiveMarketWindows(runtime, result.wiring.lifecycleCap.id, true);
    const packages: Record<string, ObjectEvidence> = {};
    const sharedObjects: Record<string, Record<string, ObjectEvidence>> = {};
    const ownedCaps: Record<string, Record<string, ObjectEvidence>> = {};
    for (const pkg of PACKAGES) {
        assertCompletedPackage(result, pkg);
        const id = packageId(result, pkg);
        packages[pkg] = await objectEvidence(runtime, id, "package", null);
        assertPublishedPackageGraph(runtime, pkg, id);
        if (packages[pkg].previousTransaction !== result.publishTx[pkg]) {
            throw new Error(`${pkg} package was not created by ${result.publishTx[pkg]}`);
        }
        const shared: Record<string, ObjectEvidence> = {};
        for (const [type, objectId] of Object.entries(result.sharedObjects[pkg] ?? {})) {
            shared[type] = await objectEvidence(runtime, objectId, `${id}::${type}`, "shared");
        }
        if (Object.keys(shared).length > 0) sharedObjects[pkg] = shared;
        const caps: Record<string, ObjectEvidence> = {};
        for (const [type, objectId] of Object.entries(result.ownedCaps[pkg] ?? {})) {
            caps[type] = await objectEvidence(runtime, objectId, type, DEPLOYER);
        }
        ownedCaps[pkg] = caps;
    }

    const oracleRegistry = sharedId(result, "propbook", "registry::OracleRegistry");
    const oracleSnapshot = await stableObjectSnapshot(
        runtime,
        oracleRegistry,
        `${packageId(result, "propbook")}::registry::OracleRegistry`,
        async () => ({
            pythFeed: await inspectOptionId(
                runtime,
                "verify_pyth_binding",
                target(result, "propbook", "registry", "propbook_pyth_id_for_underlying"),
                (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
            ),
            storePair: await inspectBlockScholesStorePair(
                runtime,
                "verify_block_scholes_store_pair",
                oracleRegistry,
            ),
        }),
    );
    const { pythFeed, storePair } = oracleSnapshot.value;
    sharedObjects.propbook!["registry::OracleRegistry"] = oracleSnapshot.evidence;
    if (
        !storePair ||
        pythFeed !== result.wiring.asset.pythFeedId ||
        storePair.valueStoreId !== result.wiring.asset.blockScholesValueStoreId ||
        storePair.sviStoreId !== result.wiring.asset.blockScholesSviStoreId
    ) {
        throw new Error(`Propbook canonical bindings do not match ${STATE_RELATIVE}`);
    }
    await assertBlockScholesStoreBaseAssets(runtime, storePair);
    const oracleObjects = {
        pythFeed: await objectEvidence(
            runtime,
            pythFeed!,
            `${packageId(result, "propbook")}::pyth_feed::PythFeed`,
            "shared",
        ),
        blockScholesValueStore: await objectEvidence(
            runtime,
            storePair.valueStoreId,
            `${packageId(result, "propbook")}::block_scholes_store::BlockScholesValueStore`,
            "shared",
        ),
        blockScholesSviStore: await objectEvidence(
            runtime,
            storePair.sviStoreId,
            `${packageId(result, "propbook")}::block_scholes_store::BlockScholesSVIStore`,
            "shared",
        ),
    };

    const predictAppAuthorized = await accountAppAuthorized(
        runtime,
        "verify_predict_app",
        `${packageId(result, "predict")}::predict_account::PredictApp`,
    );
    const deepbookCoreAccountAppAuthorized = await accountAppAuthorized(
        runtime,
        "verify_deepbook_core_app",
        `${packageId(result, "deepbook_core_account")}::account_data::DeepbookCoreAccountApp`,
    );
    const sessionsAppAuthorized = await accountAppAuthorized(
        runtime,
        "verify_sessions_app",
        `${packageId(result, "sessions")}::sessions::SessionsApp`,
    );
    const deepbookSnapshot = await stableObjectSnapshot(
        runtime,
        DEEPBOOK_REGISTRY,
        `${LINKED.deepbook}::registry::Registry`,
        () => deepbookCoreAppAuthorized(runtime),
    );
    const deepbookCoreAuthorized = deepbookSnapshot.value;
    if (
        !predictAppAuthorized ||
        !deepbookCoreAccountAppAuthorized ||
        !sessionsAppAuthorized ||
        !result.wiring.account.accountWrapperId
    ) {
        throw new Error("application authorization or deployment account is missing");
    }
    result.wiring.deepbook = {
        coreAppAuthorized: deepbookCoreAuthorized,
        verifiedAt: new Date().toISOString(),
    };
    const sessionsConfigId = sharedId(result, "sessions", "session_config::SessionsConfig");
    const sessionsSnapshot = await stableObjectSnapshot(
        runtime,
        sessionsConfigId,
        `${packageId(result, "sessions")}::session_config::SessionsConfig`,
        () => moveObjectFields(runtime, sessionsConfigId),
    );
    const sessionsConfigFields = sessionsSnapshot.value;
    sharedObjects.sessions!["session_config::SessionsConfig"] = sessionsSnapshot.evidence;
    if (stringField(sessionsConfigFields, "version_watermark") !== "1") {
        throw new Error("SessionsConfig version watermark is not 1");
    }
    const accountWrapper = await objectEvidence(
        runtime,
        result.wiring.account.accountWrapperId,
        `${packageId(result, "account")}::account::AccountWrapper`,
        "shared",
    );
    const accountId = await deploymentAccountId(runtime, result.wiring.account.accountWrapperId);
    const accountPlpBalance = await deploymentAccountPlpBalance(
        runtime,
        result.wiring.account.accountWrapperId,
    );
    const bootstrapDigest = result.transactions.bootstrap_pool;
    if (
        result.wiring.bootstrap.accountId !== accountId ||
        !result.wiring.bootstrap.requestIndex ||
        result.wiring.bootstrap.sharesMinted !== BOOTSTRAP_SUPPLY_AMOUNT.toString() ||
        result.wiring.bootstrap.accountPlpBalance !== accountPlpBalance.toString() ||
        accountPlpBalance !== BOOTSTRAP_SUPPLY_AMOUNT ||
        !bootstrapDigest ||
        result.wiring.bootstrap.lockCapitalTx !== bootstrapDigest ||
        result.wiring.bootstrap.supplyRequestTx !== bootstrapDigest ||
        result.wiring.bootstrap.flushTx !== bootstrapDigest
    ) {
        throw new Error("bootstrap supply is not attributed to the deployment account");
    }
    const lifecycleCap = await objectEvidence(
        runtime,
        result.wiring.lifecycleCap.id,
        `${packageId(result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`,
        DEPLOYER,
    );

    const registryId = sharedId(result, "predict", "registry::Registry");
    const cadenceSnapshot = await stableObjectSnapshot(
        runtime,
        registryId,
        `${packageId(result, "predict")}::registry::Registry`,
        () => readCadences(runtime),
    );
    const cadences = cadenceSnapshot.value;
    sharedObjects.predict!["registry::Registry"] = cadenceSnapshot.evidence;
    if (!cadences.every((record, index) => cadenceMatches(record, CADENCES[index]))) {
        throw new Error("verified cadence policy does not match deploy.ts");
    }
    await discoverMarkets(runtime);
    const activeIds = await activeMarketIds(runtime);
    const verificationClockMs = await currentClockMs(runtime);
    let activeMarketCash = 0n;
    const verifiedMarkets: MarketRecord[] = [];
    for (const id of activeIds) {
        const state = await marketState(runtime, id);
        const record = result.wiring.markets.find((market) => market.id === id);
        if (!record) throw new Error(`active market ${id} is absent from ${STATE_RELATIVE}`);
        if (state.cashBalance === 0n) throw new Error(`active market ${id} has zero cash`);
        activeMarketCash += state.cashBalance;
        record.cashBalance = state.cashBalance.toString();
        await objectEvidence(
            runtime,
            id,
            `${packageId(result, "predict")}::expiry_market::ExpiryMarket`,
            "shared",
        );
        verifiedMarkets.push({ ...record });
    }
    for (const cadence of CADENCES.filter((spec) => spec.marketsToCreate > 0)) {
        const futureCount = verifiedMarkets.filter(
            (market) =>
                market.cadenceId === cadence.id && BigInt(market.expiryMs) > verificationClockMs,
        ).length;
        const check = result.wiring.marketWindowChecks.find(
            (candidate) => candidate.cadenceId === cadence.id,
        );
        if (
            futureCount === 0 ||
            !check ||
            check.recorded !== futureCount ||
            (futureCount < cadence.marketsToCreate && !check.windowFull)
        ) {
            throw new Error(
                `${cadence.name} future market window is incomplete (${futureCount}/${cadence.marketsToCreate})`,
            );
        }
    }

    const totalSupply = await poolU64(runtime, "plp_total_supply");
    const idleBalance = await poolU64(runtime, "idle_balance");
    const pendingSupply = await poolU64(runtime, "supply_requests_pending");
    const pendingWithdraw = await poolU64(runtime, "withdraw_requests_pending");
    if (
        totalSupply !== LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT ||
        pendingSupply !== 0n ||
        pendingWithdraw !== 0n ||
        idleBalance + activeMarketCash !== totalSupply
    ) {
        throw new Error(
            `pool accounting mismatch supply=${totalSupply} idle=${idleBalance} activeCash=${activeMarketCash} pending=${pendingSupply}/${pendingWithdraw}`,
        );
    }
    const packageCheckpoints = PACKAGES.map((pkg) =>
        transactionCheckpoint(
            runtime.snapshot,
            requiredString(result.publishTx[pkg], `${pkg} publish digest`),
        ),
    );
    const indexingStartCheckpoint = packageCheckpoints
        .map((checkpoint) => BigInt(checkpoint))
        .reduce((earliest, checkpoint) => (checkpoint < earliest ? checkpoint : earliest))
        .toString();
    const protocolConfigId = sharedId(result, "predict", "protocol_config::ProtocolConfig");
    const protocolSnapshot = await stableObjectSnapshot(
        runtime,
        protocolConfigId,
        `${packageId(result, "predict")}::protocol_config::ProtocolConfig`,
        () => readProtocolConfig(runtime),
    );
    sharedObjects.predict!["protocol_config::ProtocolConfig"] = protocolSnapshot.evidence;
    const linkedObjects = {
        ...external.objects,
        deepbookRegistry: deepbookSnapshot.evidence,
    };

    const verification: Verification = {
        verifiedAt: new Date().toISOString(),
        chainId: await shortChainId(runtime.client),
        indexingStartCheckpoint,
        verifiedAfterCheckpoint: null,
        packages,
        linkedPackages: external.packages,
        linkedObjects,
        sharedObjects,
        ownedCaps,
        oracleObjects,
        account: {
            predictAppAuthorized,
            deepbookCoreAppAuthorized: deepbookCoreAccountAppAuthorized,
            sessionsAppAuthorized,
            deepbookCoreAuthorized,
            accountWrapper,
        },
        lifecycleCap,
        cadences,
        protocolConfig: protocolSnapshot.value,
        pool: {
            totalSupply: totalSupply.toString(),
            idleBalance: idleBalance.toString(),
            supplyRequestsPending: pendingSupply.toString(),
            withdrawRequestsPending: pendingWithdraw.toString(),
            activeMarketIds: activeIds,
            activeMarketCash: activeMarketCash.toString(),
            deployerAccountPlpBalance: accountPlpBalance.toString(),
        },
        markets: verifiedMarkets,
    };
    writeState(result);
    await assertSdkTarget(runtime);
    return verification;
}

async function finalizeLifecycleCapHandoff(
    runtime: Runtime,
    verification: Verification,
): Promise<Verification> {
    await assertSdkTarget(runtime);
    const lifecycleCap = await objectEvidence(
        runtime,
        requiredObjectId(runtime.result.wiring.lifecycleCap.id, "lifecycle capability"),
        `${packageId(runtime.result, "predict")}::market_lifecycle_cap::MarketLifecycleCap`,
        partyOwnerLabel(LIFECYCLE_CAP_RECIPIENT),
    );
    const verifiedAfterCheckpoint = transactionCheckpoint(
        runtime.snapshot,
        requiredString(
            runtime.result.wiring.lifecycleCap.transferTx,
            "lifecycle capability transfer digest",
        ),
    );
    if (BigInt(verifiedAfterCheckpoint) < BigInt(verification.indexingStartCheckpoint)) {
        throw new Error("configuration verification fence precedes package publication");
    }
    return {
        ...verification,
        verifiedAt: new Date().toISOString(),
        verifiedAfterCheckpoint,
        lifecycleCap,
    };
}

async function assertFunding(runtime: Runtime): Promise<void> {
    const totalSupply =
        runtime.result.packages.predict && runtime.result.sharedObjects.predict
            ? await poolU64(runtime, "plp_total_supply")
            : 0n;
    if (totalSupply === LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT) return;
    if (totalSupply !== 0n) {
        throw new Error(`unexpected partial PLP bootstrap supply: ${totalSupply}`);
    }
    const balance = await runtime.client.getBalance({
        owner: DEPLOYER,
        coinType: dusdcType(),
    });
    const available = BigInt(balance.balance.balance);
    const required = LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT;
    if (available < required) {
        throw new Error(
            `insufficient deployer DUSDC: have ${available}, need ${required} (short ${required - available})`,
        );
    }
}

async function assertGasFunding(runtime: Runtime): Promise<void> {
    const balance = await runtime.client.getBalance({ owner: DEPLOYER });
    const available = BigInt(balance.balance.balance);
    const remainingPackages = PACKAGES.filter((pkg) => !runtime.result.packages[pkg]).length;
    const remainingFixedTransactions = FIXED_TRANSACTION_STEPS.filter(
        (label) => !runtime.result.transactions[label],
    ).length;
    const remainingMarketTransactions =
        runtime.result.wiring.lifecycleCap.owner === "recipient"
            ? 0
            : maximumTransactionCountPerRun() - FIXED_TRANSACTION_STEPS.length;
    const required =
        BigInt(PACKAGE_GAS_BUDGET) * BigInt(remainingPackages) +
        TRANSACTION_GAS_BUDGET * BigInt(remainingFixedTransactions + remainingMarketTransactions);
    if (available < required) {
        throw new Error(
            `insufficient deployer SUI gas: have ${available}, need at least ${required} for ${remainingPackages} publications, ${remainingFixedTransactions} fixed transactions, and ${remainingMarketTransactions} bounded market transactions`,
        );
    }
}

export async function runBroadcastBoundary(
    execute: boolean,
    broadcast: () => Promise<void>,
): Promise<boolean> {
    if (!execute) return false;
    await broadcast();
    return true;
}

async function executeDeployment(runtime: Runtime, bindings: ExecutionBindings): Promise<void> {
    const result = runtime.result;
    result.suiVersion ??= bindings.suiVersion;
    result.suiBinaryPath ??= bindings.suiBinaryPath;
    result.suiBinaryDigest ??= bindings.suiBinaryDigest;
    result.rpcUrl ??= bindings.rpcUrl;
    result.clientConfigDigest ??= bindings.clientConfigDigest;
    result.sourceCommit ??= runtime.sourceCommit;
    result.packageGasBudget ??= bindings.packageGasBudget;
    result.transactionGasBudget ??= bindings.transactionGasBudget;
    result.startedAt ??= new Date().toISOString();
    result.completedAt = null;
    result.lastError = null;
    result.status = "publishing";
    writeState(result);

    try {
        for (const pkg of PACKAGES) {
            if (irreversibleStepDigest(result, "publish", `publish_${pkg}`, pkg)) {
                await verifyPublishedPackageCheckpoint(runtime, pkg);
                console.log(`[deploy] ${pkg} checkpoint verified; skipping publish`);
            } else {
                await publishPackage(runtime, pkg);
            }
        }
        result.status = "wiring";
        writeState(result);

        await ensureAccountAppsAuthorized(runtime);
        await ensureDeepbookCoreAppAuthorized(runtime);
        const lifecycleCapId = await ensureLifecycleCap(runtime);
        if (result.wiring.lifecycleCap.owner === "recipient") {
            if (!result.verification) {
                throw new Error(
                    "lifecycle capability was handed off without a persisted pre-handoff audit",
                );
            }
            result.verification = await finalizeLifecycleCapHandoff(runtime, result.verification);
            result.status = "complete";
            result.completedAt = new Date().toISOString();
            result.lastError = null;
            writeState(result);
            writeIntegrationManifest(buildIntegrationManifest(result));
            console.log(`[deploy] complete state: ${STATE}`);
            console.log(`[deploy] integration manifest: ${MANIFEST}`);
            return;
        }
        result.verification = null;
        await ensureOracleObjects(runtime);
        await ensureUnderlyingRegistered(runtime);
        await ensureCadences(runtime);
        const accountWrapperId = await ensureAccountWrapper(runtime);
        await ensureBootstrap(runtime, lifecycleCapId, accountWrapperId);
        await ensureMarkets(runtime, lifecycleCapId);

        result.status = "verifying";
        writeState(result);
        result.verification = await verifyDeployment(runtime);
        result.status = "handoff";
        writeState(result);
        await transferLifecycleCap(runtime, lifecycleCapId);
        result.verification = await finalizeLifecycleCapHandoff(runtime, result.verification);
        result.status = "complete";
        result.completedAt = new Date().toISOString();
        result.lastError = null;
        writeState(result);
        writeIntegrationManifest(buildIntegrationManifest(result));
        console.log(`[deploy] complete state: ${STATE}`);
        console.log(`[deploy] integration manifest: ${MANIFEST}`);
    } catch (error) {
        result.status = result.inFlight
            ? "ambiguous"
            : Object.keys(result.publishTx).length > 0 ||
                Object.keys(result.transactions).length > 0
              ? "partial"
              : "failed";
        result.lastError = error instanceof Error ? error.message : String(error);
        writeState(result);
        throw error;
    }
}

async function run(execute: boolean): Promise<void> {
    if (!/^[1-9][0-9]*$/.test(PACKAGE_GAS_BUDGET) || TRANSACTION_GAS_BUDGET <= 0n) {
        throw new Error("gas budgets must be positive integers");
    }
    const result = loadState();
    assertStateFile(result);
    assertPackageCheckpoints(result);
    assertExpectedWorktree(result);
    const sourceCommit = git(["rev-parse", "HEAD"]);
    if (result.sourceCommit && result.sourceCommit !== sourceCommit) {
        throw new Error(`deployment started from ${result.sourceCommit}, HEAD is ${sourceCommit}`);
    }
    const binary = suiBinaryIdentity();
    const suiVersion = sui(["--version"]);
    assertSuiCliVersion(suiVersion);

    const snapshot = snapshotClientConfig();
    try {
        assertCliTarget(snapshot);
        const signer = getSigner(snapshot.keystorePath);
        const runtime: Runtime = {
            result,
            snapshot,
            client: new SuiGrpcClient({
                baseUrl: snapshot.rpcUrl,
                network: NETWORK,
            }),
            signer,
            sourceCommit,
            packageMetadataCache: new Map(),
            marketCreationsThisRun: {},
        };
        const executionBindings: ExecutionBindings = {
            suiVersion,
            suiBinaryPath: binary.path,
            suiBinaryDigest: binary.digest,
            rpcUrl: snapshot.rpcUrl,
            clientConfigDigest: snapshot.configDigest,
            packageGasBudget: PACKAGE_GAS_BUDGET,
            transactionGasBudget: TRANSACTION_GAS_BUDGET.toString(),
        };
        if (result.startedAt) assertExecutionBindings(result, executionBindings);
        await assertSdkTarget(runtime);
        if (result.inFlight) await reconcileInFlight(runtime);

        console.log("[deploy] compiling Predict and proving resolved Testnet package IDs");
        assertResolvedLinkedPackages();
        assertExpectedWorktree(result);
        await verifyExternalDependencies(runtime);
        await assertGasFunding(runtime);
        await assertFunding(runtime);

        console.log(`[deploy] network: ${NETWORK} (${CHAIN_ID})`);
        console.log(`[deploy] deployer: ${DEPLOYER}`);
        console.log(`[deploy] source: ${sourceCommit}`);
        console.log(`[deploy] Sui CLI: ${suiVersion}`);
        console.log(`[deploy] package plan: ${PACKAGES.join(" -> ")}`);
        console.log(`[deploy] lifecycle cap party owner: ${LIFECYCLE_CAP_RECIPIENT}`);
        console.log(
            `[deploy] DUSDC bootstrap: lock=${LOCK_CAPITAL_AMOUNT} supply=${BOOTSTRAP_SUPPLY_AMOUNT}`,
        );
        if (!execute) {
            console.log("[deploy] preflight complete; no transactions submitted (pass --execute)");
        }
        await runBroadcastBoundary(execute, () => executeDeployment(runtime, executionBindings));
    } finally {
        rmSync(snapshot.directory, { recursive: true, force: true });
    }
}

export function parseDeploymentArgs(args: readonly string[]): DeploymentMode {
    const unknown = args.filter((arg) => arg !== "--execute");
    if (unknown.length > 0) throw new Error(`unknown deployment arguments: ${unknown.join(", ")}`);
    return { execute: args.includes("--execute"), sessions: false, smoke: false };
}

export async function main(args = process.argv.slice(2)): Promise<void> {
    const mode = parseDeploymentArgs(args);
    const lock = acquireLock();
    try {
        await run(mode.execute);
    } finally {
        releaseLock(lock);
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch((error) => {
        console.error(error);
        process.exitCode = 1;
    });
}
