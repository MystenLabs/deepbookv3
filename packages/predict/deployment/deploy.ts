// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/**
 * Publish and fully configure an independent Predict deployment on Sui Testnet.
 *
 * A run publishes fixed_math, account, propbook, and predict; authorizes the
 * Predict app; creates and binds the oracle objects; stores the cadence policy
 * on-chain; bootstraps the pool; creates and funds the initial market windows;
 * and transfers the lifecycle capability to the keeper operator. Every package,
 * object, configuration value, and transaction digest is written to
 * deployment.testnet.json and verified from Testnet before completion.
 *
 * The default invocation is non-broadcasting:
 *   SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts
 *
 * Broadcast only from a committed deployment branch:
 *   SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --execute
 *
 * `--skip-dependency-verification` is intentional for publication. The
 * committed manifests select the canonical Testnet package identities, while
 * some published dependency bytecode does not reproduce from the available
 * source. Preflight still compiles with warnings denied and proves that every
 * resolved dependency ID is the expected Testnet package.
 */
import { execFileSync } from "node:child_process";
import {
    chmodSync,
    closeSync,
    copyFileSync,
    existsSync,
    mkdtempSync,
    openSync,
    readFileSync,
    renameSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
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
const OUT_RELATIVE = "packages/predict/deployment/deployment.testnet.json";
const OUT = resolve(REPO_ROOT, OUT_RELATIVE);
const OUT_TEMP = `${OUT}.tmp`;
const SUI = process.env.SUI_BINARY ?? "sui";
const PACKAGE_GAS_BUDGET = process.env.PACKAGE_GAS_BUDGET ?? "5000000000";
const TRANSACTION_GAS_BUDGET = BigInt(process.env.TRANSACTION_GAS_BUDGET ?? "1000000000");
const NETWORK = "testnet";
const CHAIN_ID = "4c78adac";
const DEPLOYER = "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef";
const LIFECYCLE_CAP_RECIPIENT =
    "0xc230d3a341a4fddd752979fbac7625fb2b302ea28202d218a81b007653380c82";
const SUI_VERSION = /^sui 1\.74\.1(?:-|$)/;
const OBJECT_ID = /^0x[0-9a-f]{64}$/;
const CLOCK_ID = "0x0000000000000000000000000000000000000000000000000000000000000006";
const ACCUMULATOR_ROOT_ID = "0x0000000000000000000000000000000000000000000000000000000000000acc";

const PACKAGES = ["fixed_math", "account", "propbook", "predict"] as const;
type PackageName = (typeof PACKAGES)[number];

const LINKED = {
    dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
    deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
    pyth_lazer: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
    wormhole: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
    bs_oracle: "0x87cc43db9b6c1e8b174841221e8e4bde5ab8fc8aaffacc58699c77e9e6340ff6",
} as const;

const LINKED_OBJECTS = {
    clock: CLOCK_ID,
    accumulatorRoot: ACCUMULATOR_ROOT_ID,
    pythLazerState: "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
    wormholeState: "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
    blockScholesSignerRegistry:
        "0xe1198f0add6ba5286d23f2790818937e4a629b95a86e98b1ece93c0ef3c2c440",
} as const;

const EXPECTED_SHARED: Record<PackageName, readonly string[]> = {
    fixed_math: [],
    account: ["account_registry::AccountRegistry"],
    propbook: ["registry::OracleRegistry"],
    predict: ["plp::PoolVault", "protocol_config::ProtocolConfig", "registry::Registry"],
};

const DUSDC_SCALING = 1_000_000n;
const LOCK_CAPITAL_AMOUNT = 10n * DUSDC_SCALING;
const BOOTSTRAP_SUPPLY_AMOUNT = 1_500_000n * DUSDC_SCALING;
const ASSET = {
    name: "BTC_USD",
    propbookUnderlyingId: 1,
    pythLazerFeedId: 1,
    blockScholesSourceId: 1,
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

const CADENCES: readonly CadenceSpec[] = [
    {
        id: 0,
        name: "1m",
        periodMs: 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 50_000n * DUSDC_SCALING,
        initialExpiryCash: 10_000n * DUSDC_SCALING,
        windowSize: 3n,
        marketsToCreate: 3,
    },
    {
        id: 1,
        name: "5m",
        periodMs: 5 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 50_000n * DUSDC_SCALING,
        initialExpiryCash: 10_000n * DUSDC_SCALING,
        windowSize: 3n,
        marketsToCreate: 3,
    },
    {
        id: 2,
        name: "1h",
        periodMs: 60 * 60_000,
        tickSize: 10_000_000n,
        admissionTickSize: 1_000_000_000n,
        maxExpiryAllocation: 250_000n * DUSDC_SCALING,
        initialExpiryCash: 50_000n * DUSDC_SCALING,
        windowSize: 3n,
        marketsToCreate: 3,
    },
    {
        id: 3,
        name: "1d",
        periodMs: 24 * 60 * 60_000,
        tickSize: 0n,
        admissionTickSize: 0n,
        maxExpiryAllocation: 0n,
        initialExpiryCash: 0n,
        windowSize: 0n,
        marketsToCreate: 0,
    },
    {
        id: 4,
        name: "1w",
        periodMs: 7 * 24 * 60 * 60_000,
        tickSize: 0n,
        admissionTickSize: 0n,
        maxExpiryAllocation: 0n,
        initialExpiryCash: 0n,
        windowSize: 0n,
        marketsToCreate: 0,
    },
    {
        id: 5,
        name: "1mo",
        periodMs: 0,
        tickSize: 0n,
        admissionTickSize: 0n,
        maxExpiryAllocation: 0n,
        initialExpiryCash: 0n,
        windowSize: 0n,
        marketsToCreate: 0,
    },
] as const;

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

interface Receipt {
    digest?: string;
    effects?: unknown;
    objectChanges?: ObjectChange[] | null;
    events?: EventRecord[] | null;
}

interface InFlight {
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
        accountWrapperId: string | null;
        createAccountTx: string | null;
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

interface Verification {
    verifiedAt: string;
    chainId: string;
    packages: Record<string, ObjectEvidence>;
    linkedPackages: Record<string, ObjectEvidence>;
    linkedObjects: Record<string, ObjectEvidence>;
    sharedObjects: Record<string, Record<string, ObjectEvidence>>;
    ownedCaps: Record<string, Record<string, ObjectEvidence>>;
    oracleObjects: Record<string, ObjectEvidence>;
    account: {
        predictAppAuthorized: boolean;
        accountWrapper: ObjectEvidence;
    };
    lifecycleCap: ObjectEvidence;
    cadences: CadenceRecord[];
    protocolConfig: {
        usePythSpotForForward: boolean;
        pythSpotFreshnessMs: string;
        blockScholesPriceFreshnessMs: string;
        blockScholesSviFreshnessMs: string;
        versionWatermark: string;
        tradingPaused: boolean;
        frozen: boolean;
        valuationInProgress: boolean;
    };
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

interface DeploymentResult {
    schemaVersion: number;
    status:
        | "pending"
        | "publishing"
        | "wiring"
        | "verifying"
        | "partial"
        | "failed"
        | "ambiguous"
        | "complete";
    network: string;
    chainId: string;
    buildEnvironment: string;
    suiVersion: string | null;
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
    wiring: WiringState;
    verification: Verification | null;
}

interface ClientSnapshot {
    directory: string;
    configPath: string;
    rpcUrl: string;
    keystorePath: string;
}

interface Runtime {
    result: DeploymentResult;
    snapshot: ClientSnapshot;
    client: SuiGrpcClient;
    signer: Ed25519Keypair;
    sourceCommit: string;
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

function command(executable: string, args: string[]): string {
    return execFileSync(executable, args, {
        cwd: REPO_ROOT,
        encoding: "utf8",
        maxBuffer: 256 * 1024 * 1024,
    }).trim();
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

function loadResult(): DeploymentResult {
    return JSON.parse(readFileSync(OUT, "utf8")) as DeploymentResult;
}

function writeResult(result: DeploymentResult): void {
    result.wiring.updatedAt = new Date().toISOString();
    writeFileSync(OUT_TEMP, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
    renameSync(OUT_TEMP, OUT);
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

function ownerLabel(owner: unknown): string {
    if (isShared(owner)) return "shared";
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
    }
}

function publishedPath(pkg: PackageName): string {
    return resolve(REPO_ROOT, "packages", pkg, "Published.toml");
}

function publishedField(section: string, field: string, label: string): string {
    const match = section.match(new RegExp(`^${field}\\s*=\\s*"?([^"\\n]+)"?\\s*$`, "m"));
    if (!match) throw new Error(`${label} is missing '${field}'`);
    return match[1].trim();
}

function assertPublishedIdentity(path: string, expectedId: string, label: string): void {
    if (!existsSync(path)) throw new Error(`${label} is missing ${path}`);
    const text = readFileSync(path, "utf8");
    const section = text.match(/\[published\.testnet\]([\s\S]*?)(?=\n\[|$)/)?.[1];
    if (!section) throw new Error(`${label} is missing [published.testnet]`);
    const chainId = publishedField(section, "chain-id", label);
    const publishedAt = normalizeId(publishedField(section, "published-at", label));
    const originalId = normalizeId(publishedField(section, "original-id", label));
    if (chainId !== CHAIN_ID || publishedAt !== expectedId || originalId !== expectedId) {
        throw new Error(
            `${label} metadata is ${chainId}/${publishedAt}/${originalId}, expected ${CHAIN_ID}/${expectedId}`,
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
        } else if (existsSync(publishedPath(pkg))) {
            throw new Error(
                `${publishedPath(pkg)} exists without a complete JSON checkpoint; reconcile it before continuing`,
            );
        }
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

function assertExpectedWorktree(result: DeploymentResult): void {
    const allowed = new Set<string>([OUT_RELATIVE]);
    for (const pkg of PACKAGES) {
        if (result.packages[pkg] || result.inFlight?.package === pkg) {
            allowed.add(`packages/${pkg}/Published.toml`);
        }
    }
    const unexpected = changedPaths().filter((path) => !allowed.has(path));
    if (unexpected.length > 0) {
        throw new Error(
            `deployment source is dirty outside generated artifacts: ${unexpected.join(", ")}`,
        );
    }
}

function assertSourceCommit(expectedCommit: string): void {
    const head = git(["rev-parse", "HEAD"]);
    if (head !== expectedCommit) {
        throw new Error(`deployment source commit changed from ${expectedCommit} to ${head}`);
    }
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

function assertResultFile(result: DeploymentResult): void {
    if (
        result.schemaVersion !== 2 ||
        result.network !== NETWORK ||
        result.chainId !== CHAIN_ID ||
        result.buildEnvironment !== NETWORK ||
        normalizeId(result.deployer) !== DEPLOYER
    ) {
        throw new Error(`${OUT_RELATIVE} is not the expected schema-2 Testnet deployment`);
    }
    if (JSON.stringify(result.linked) !== JSON.stringify(LINKED)) {
        throw new Error("linked package IDs in deployment.testnet.json do not match deploy.ts");
    }
    if (JSON.stringify(result.linkedObjects) !== JSON.stringify(LINKED_OBJECTS)) {
        throw new Error("linked object IDs in deployment.testnet.json do not match deploy.ts");
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
                `deployment lock already exists at ${path}. Fail closed: inspect ${OUT_RELATIVE} and Testnet before removing it. lock=${detail}`,
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

    const configuredKeystore = yaml.match(/keystore:\s*\n\s*File:\s*(.+)$/m)?.[1];
    const keystorePath =
        process.env.SUI_KEYSTORE_PATH ??
        (configuredKeystore
            ? stripYamlScalar(configuredKeystore)
            : resolve(homedir(), ".sui", "sui_config", "sui.keystore"));
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
    };
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

function assertResolvedLinkedPackages(): void {
    command(SUI, [
        "move",
        "build",
        "--path",
        resolve(REPO_ROOT, "packages", "predict"),
        "--build-env",
        NETWORK,
        "--warnings-are-errors",
        "--force",
    ]);
    const debug = resolve(
        REPO_ROOT,
        "packages",
        "predict",
        "build",
        "deepbook_predict",
        "debug_info",
        "dependencies",
    );
    const resolved: Record<keyof typeof LINKED, string> = {
        dusdc: debugPackageId(resolve(debug, "dusdc", "dusdc.json")),
        deep: debugPackageId(resolve(debug, "token", "deep.json")),
        pyth_lazer: debugPackageId(resolve(debug, "pyth_lazer", "channel.json")),
        wormhole: debugPackageId(resolve(debug, "wormhole", "external_address.json")),
        bs_oracle: debugPackageId(resolve(debug, "bs_oracle", "verify.json")),
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

function assertCliTarget(snapshot: ClientSnapshot): void {
    const environment = suiClient(snapshot, ["active-env"]);
    const chainId = suiClient(snapshot, ["chain-identifier"]);
    const address = normalizeId(suiClient(snapshot, ["active-address"]));
    if (environment !== NETWORK || chainId !== CHAIN_ID || address !== DEPLOYER) {
        throw new Error(
            `isolated CLI target is ${environment}/${chainId}/${address}, expected ${NETWORK}/${CHAIN_ID}/${DEPLOYER}`,
        );
    }
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
    writeResult(runtime.result);

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
    if (failure) throw new Error(`${label} failed at ${digest}: ${failure}`);
    receipt = await settledReceipt(runtime.client, digest);
    runtime.result.transactions[label] = digest;
    runtime.result.inFlight = null;
    runtime.result.status = "wiring";
    writeResult(runtime.result);
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
    writeResult(runtime.result);

    const output = suiClient(runtime.snapshot, [
        "publish",
        resolve(REPO_ROOT, "packages", pkg),
        "--build-env",
        NETWORK,
        "--warnings-are-errors",
        "--force",
        "--sender",
        DEPLOYER,
        "--skip-dependency-verification",
        "--gas-budget",
        PACKAGE_GAS_BUDGET,
        "--json",
    ]);
    const receipt = JSON.parse(output) as Receipt;
    const failure = effectsError(receipt.effects);
    if (failure || !receipt.digest) throw new Error(`publish ${pkg} failed: ${failure}`);
    runtime.result.inFlight.digest = receipt.digest;
    writeResult(runtime.result);
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
    runtime.result.inFlight = null;
    writeResult(runtime.result);
    console.log(`[deploy] ${pkg}: ${runtime.result.packages[pkg]} (${receipt.digest})`);
}

async function reconcileInFlight(runtime: Runtime): Promise<void> {
    const inFlight = runtime.result.inFlight;
    if (!inFlight) return;
    if (!inFlight.digest) {
        throw new Error(
            `${inFlight.label} has no known digest. Fail closed: reconcile the deployer transaction history and Published.toml before retrying`,
        );
    }
    let receipt: Receipt;
    try {
        receipt = await settledReceipt(runtime.client, inFlight.digest, 4);
    } catch {
        throw new Error(
            `${inFlight.label}/${inFlight.digest} is not visible on Testnet. Fail closed; do not retry with new transaction bytes`,
        );
    }
    const failure = effectsError(receipt.effects);
    if (failure) throw new Error(`${inFlight.label}/${inFlight.digest} failed: ${failure}`);
    if (inFlight.kind === "publish") {
        if (!inFlight.package) throw new Error("in-flight publish is missing its package");
        assertPublishedIdentity(
            publishedPath(inFlight.package),
            normalizeId(
                (receipt.objectChanges ?? []).find((change) => change.type === "published")
                    ?.packageId ?? "",
            ),
            inFlight.package,
        );
        recordPublish(runtime.result, inFlight.package, receipt);
        assertCompletedPackage(runtime.result, inFlight.package);
    } else {
        runtime.result.transactions[inFlight.label] = inFlight.digest;
    }
    runtime.result.inFlight = null;
    writeResult(runtime.result);
    console.log(`[deploy] reconciled ${inFlight.label}: ${inFlight.digest}`);
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
    if (
        expectedOwner &&
        (expectedOwner === "shared"
            ? actualOwner !== "shared"
            : actualOwner !== normalizeId(expectedOwner))
    ) {
        throw new Error(`${objectId} is owned by ${actualOwner}, expected ${expectedOwner}`);
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
    };
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
    const now = Math.floor(Date.now() / 1_000);
    if (
        !Array.isArray(trustedSigners) ||
        !trustedSigners.some((value) => Number(asRecord(value).expires_at) > now)
    ) {
        throw new Error("Pyth Lazer state has no unexpired trusted signer");
    }
    return { packages, objects };
}

async function ensurePredictAppAuthorized(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    const registry = sharedId(result, "account", "account_registry::AccountRegistry");
    const appType = `${packageId(result, "predict")}::predict_account::PredictApp`;
    const authorized = await inspectBool(
        runtime,
        "is_app_authorized",
        target(result, "account", "account_registry", "is_app_authorized"),
        (tx) => [tx.object(registry)],
        [appType],
    );
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
        const receipt = await executeTransaction(runtime, "authorize_predict_app", tx);
        result.wiring.account.authorizeTx = receipt.digest ?? null;
    }
    result.wiring.account.predictAppAuthorized = true;
    result.wiring.account.authorizeTx ??= result.transactions.authorize_predict_app ?? null;
    writeResult(result);
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
        writeResult(result);
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
        else if (evidence.owner === LIFECYCLE_CAP_RECIPIENT) {
            result.wiring.lifecycleCap.owner = "recipient";
        } else {
            throw new Error(`lifecycle cap ${recorded} has unexpected owner ${evidence.owner}`);
        }
        result.wiring.lifecycleCap.mintTx ??= result.transactions.mint_lifecycle_cap ?? null;
        result.wiring.lifecycleCap.transferTx ??=
            result.transactions.transfer_lifecycle_cap_to_keeper ?? null;
        writeResult(result);
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
    writeResult(result);
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

    let valueStoreId = await inspectOptionId(
        runtime,
        "block_scholes_value_store_for_underlying",
        target(
            result,
            "propbook",
            "registry",
            "propbook_block_scholes_value_store_id_for_underlying",
        ),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    let sviStoreId = await inspectOptionId(
        runtime,
        "block_scholes_svi_store_for_underlying",
        target(
            result,
            "propbook",
            "registry",
            "propbook_block_scholes_svi_store_id_for_underlying",
        ),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    if ((valueStoreId && !sviStoreId) || (!valueStoreId && sviStoreId)) {
        throw new Error(
            `partial Block Scholes store pair: value=${valueStoreId} svi=${sviStoreId}`,
        );
    }
    if (!valueStoreId && !sviStoreId) {
        const tx = new Transaction();
        call(tx, target(result, "propbook", "registry", "create_and_share_block_scholes_stores"), [
            tx.object(oracleRegistry),
            tx.object(registryAdmin),
            tx.pure.u32(ASSET.propbookUnderlyingId),
        ]);
        const receipt = await executeTransaction(runtime, "create_block_scholes_stores", tx);
        valueStoreId = createdObjectId(receipt, "::block_scholes_store::BlockScholesValueStore");
        sviStoreId = createdObjectId(receipt, "::block_scholes_store::BlockScholesSVIStore");
        result.wiring.asset.blockScholesStoresCreateTx = receipt.digest ?? null;
    }
    result.wiring.asset.blockScholesValueStoreId = valueStoreId;
    result.wiring.asset.blockScholesSviStoreId = sviStoreId;
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
    writeResult(result);
}

async function ensureUnderlyingRegistered(runtime: Runtime): Promise<void> {
    const result = runtime.result;
    if (result.transactions.register_predict_underlying) {
        result.wiring.asset.predictUnderlyingRegistered = true;
        result.wiring.asset.predictUnderlyingRegisteredTx ??=
            result.transactions.register_predict_underlying;
        writeResult(result);
    }
    if (!result.wiring.asset.predictUnderlyingRegistered) {
        const tx = new Transaction();
        call(tx, target(result, "predict", "registry", "register_underlying"), [
            tx.object(sharedId(result, "predict", "registry::Registry")),
            tx.object(sharedId(result, "predict", "protocol_config::ProtocolConfig")),
            tx.object(capId(result, "predict", "admin::AdminCap")),
            tx.pure.u32(ASSET.propbookUnderlyingId),
        ]);
        const receipt = await executeTransaction(runtime, "register_predict_underlying", tx);
        result.wiring.asset.predictUnderlyingRegisteredTx = receipt.digest ?? null;
        result.wiring.asset.predictUnderlyingRegistered = true;
        writeResult(result);
    }
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
        writeResult(result);
    }
    const verified = await readCadences(runtime);
    if (!verified.every((record, index) => cadenceMatches(record, CADENCES[index]))) {
        throw new Error("on-chain cadence configuration does not match the deployment policy");
    }
    result.wiring.cadences = verified;
    writeResult(result);
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
    writeResult(result);
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
        writeResult(result);
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
    writeResult(result);
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
    writeResult(result);
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
    writeResult(result);
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
        writeResult(runtime.result);
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
    writeResult(result);
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
            const market = marketFromEvent(receipt, cadence);
            result.wiring.markets.push(market);
            writeResult(result);
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
    if (evidence.owner === LIFECYCLE_CAP_RECIPIENT) {
        result.wiring.lifecycleCap.owner = "recipient";
        result.wiring.lifecycleCap.transferTx ??=
            result.transactions.transfer_lifecycle_cap_to_keeper ?? null;
        writeResult(result);
        return;
    }
    if (evidence.owner !== DEPLOYER) {
        throw new Error(`lifecycle cap is owned by ${evidence.owner}, expected ${DEPLOYER}`);
    }
    const tx = new Transaction();
    tx.transferObjects([tx.object(lifecycleCapId)], tx.pure.address(LIFECYCLE_CAP_RECIPIENT));
    const receipt = await executeTransaction(runtime, "transfer_lifecycle_cap_to_keeper", tx);
    result.wiring.lifecycleCap.owner = "recipient";
    result.wiring.lifecycleCap.transferTx = receipt.digest ?? null;
    writeResult(result);
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
    const config = {
        usePythSpotForForward: boolField(pricing, "use_pyth_spot_for_forward"),
        pythSpotFreshnessMs: stringField(pricing, "pyth_spot_freshness_ms"),
        blockScholesPriceFreshnessMs: stringField(pricing, "block_scholes_price_freshness_ms"),
        blockScholesSviFreshnessMs: stringField(pricing, "block_scholes_svi_freshness_ms"),
        versionWatermark: stringField(fields, "version_watermark"),
        tradingPaused: boolField(fields, "trading_paused"),
        frozen: boolField(fields, "frozen"),
        valuationInProgress: boolField(fields, "valuation_in_progress"),
    };
    if (
        !config.usePythSpotForForward ||
        config.pythSpotFreshnessMs !== "10000" ||
        config.blockScholesPriceFreshnessMs !== "10000" ||
        config.blockScholesSviFreshnessMs !== "60000" ||
        config.versionWatermark !== "1" ||
        config.tradingPaused ||
        config.frozen ||
        config.valuationInProgress
    ) {
        throw new Error(`ProtocolConfig defaults are unexpected: ${JSON.stringify(config)}`);
    }
    return config;
}

async function verifyDeployment(
    runtime: Runtime,
    external: Awaited<ReturnType<typeof verifyExternalDependencies>>,
): Promise<Verification> {
    const result = runtime.result;
    await assertSdkTarget(runtime);
    if (!result.wiring.lifecycleCap.id) throw new Error("lifecycle cap is missing");
    await assertLiveMarketWindows(runtime, result.wiring.lifecycleCap.id, false);
    const packages: Record<string, ObjectEvidence> = {};
    const sharedObjects: Record<string, Record<string, ObjectEvidence>> = {};
    const ownedCaps: Record<string, Record<string, ObjectEvidence>> = {};
    for (const pkg of PACKAGES) {
        assertCompletedPackage(result, pkg);
        const id = packageId(result, pkg);
        packages[pkg] = await objectEvidence(runtime, id, "package", null);
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
    const pythFeed = await inspectOptionId(
        runtime,
        "verify_pyth_binding",
        target(result, "propbook", "registry", "propbook_pyth_id_for_underlying"),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    const valueStore = await inspectOptionId(
        runtime,
        "verify_value_store_binding",
        target(
            result,
            "propbook",
            "registry",
            "propbook_block_scholes_value_store_id_for_underlying",
        ),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    const sviStore = await inspectOptionId(
        runtime,
        "verify_svi_store_binding",
        target(
            result,
            "propbook",
            "registry",
            "propbook_block_scholes_svi_store_id_for_underlying",
        ),
        (tx) => [tx.object(oracleRegistry), tx.pure.u32(ASSET.propbookUnderlyingId)],
    );
    if (
        pythFeed !== result.wiring.asset.pythFeedId ||
        valueStore !== result.wiring.asset.blockScholesValueStoreId ||
        sviStore !== result.wiring.asset.blockScholesSviStoreId
    ) {
        throw new Error("Propbook canonical bindings do not match deployment.testnet.json");
    }
    const oracleObjects = {
        pythFeed: await objectEvidence(
            runtime,
            pythFeed!,
            `${packageId(result, "propbook")}::pyth_feed::PythFeed`,
            "shared",
        ),
        blockScholesValueStore: await objectEvidence(
            runtime,
            valueStore!,
            `${packageId(result, "propbook")}::block_scholes_store::BlockScholesValueStore`,
            "shared",
        ),
        blockScholesSviStore: await objectEvidence(
            runtime,
            sviStore!,
            `${packageId(result, "propbook")}::block_scholes_store::BlockScholesSVIStore`,
            "shared",
        ),
    };

    const appAuthorized = await inspectBool(
        runtime,
        "verify_predict_app_authorized",
        target(result, "account", "account_registry", "is_app_authorized"),
        (tx) => [tx.object(sharedId(result, "account", "account_registry::AccountRegistry"))],
        [`${packageId(result, "predict")}::predict_account::PredictApp`],
    );
    if (!appAuthorized || !result.wiring.account.accountWrapperId) {
        throw new Error("Predict app authorization or deployment account is missing");
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
        LIFECYCLE_CAP_RECIPIENT,
    );

    const cadences = await readCadences(runtime);
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
        if (!record) throw new Error(`active market ${id} is absent from deployment JSON`);
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

    const verification: Verification = {
        verifiedAt: new Date().toISOString(),
        chainId: await shortChainId(runtime.client),
        packages,
        linkedPackages: external.packages,
        linkedObjects: external.objects,
        sharedObjects,
        ownedCaps,
        oracleObjects,
        account: {
            predictAppAuthorized: appAuthorized,
            accountWrapper,
        },
        lifecycleCap,
        cadences,
        protocolConfig: await readProtocolConfig(runtime),
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
    writeResult(result);
    await assertSdkTarget(runtime);
    return verification;
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

async function run(execute: boolean): Promise<void> {
    if (!/^[1-9][0-9]*$/.test(PACKAGE_GAS_BUDGET) || TRANSACTION_GAS_BUDGET <= 0n) {
        throw new Error("gas budgets must be positive integers");
    }
    const result = loadResult();
    assertResultFile(result);
    assertPackageCheckpoints(result);
    assertExpectedWorktree(result);
    const sourceCommit = git(["rev-parse", "HEAD"]);
    if (result.sourceCommit && result.sourceCommit !== sourceCommit) {
        throw new Error(`deployment started from ${result.sourceCommit}, HEAD is ${sourceCommit}`);
    }
    const suiVersion = sui(["--version"]);
    if (!SUI_VERSION.test(suiVersion)) {
        throw new Error(`Sui CLI must be 1.74.1, got '${suiVersion}'`);
    }

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
        };
        await assertSdkTarget(runtime);
        if (result.inFlight) await reconcileInFlight(runtime);

        console.log("[deploy] compiling Predict and proving resolved Testnet package IDs");
        assertResolvedLinkedPackages();
        assertExpectedWorktree(result);
        const external = await verifyExternalDependencies(runtime);
        await assertFunding(runtime);

        console.log(`[deploy] network: ${NETWORK} (${CHAIN_ID})`);
        console.log(`[deploy] deployer: ${DEPLOYER}`);
        console.log(`[deploy] source: ${sourceCommit}`);
        console.log(`[deploy] Sui CLI: ${suiVersion}`);
        console.log(
            `[deploy] DUSDC bootstrap: lock=${LOCK_CAPITAL_AMOUNT} supply=${BOOTSTRAP_SUPPLY_AMOUNT}`,
        );
        if (!execute) {
            console.log("[deploy] preflight complete; no transactions submitted (pass --execute)");
            return;
        }

        result.suiVersion = suiVersion;
        result.sourceCommit ??= sourceCommit;
        result.packageGasBudget = PACKAGE_GAS_BUDGET;
        result.transactionGasBudget = TRANSACTION_GAS_BUDGET.toString();
        result.startedAt ??= new Date().toISOString();
        result.completedAt = null;
        result.lastError = null;
        result.verification = null;
        result.status = "publishing";
        writeResult(result);

        try {
            for (const pkg of PACKAGES) {
                if (result.packages[pkg]) {
                    assertCompletedPackage(result, pkg);
                    console.log(`[deploy] ${pkg} checkpoint verified; skipping publish`);
                } else {
                    await publishPackage(runtime, pkg);
                }
            }
            result.status = "wiring";
            writeResult(result);

            await ensurePredictAppAuthorized(runtime);
            const lifecycleCapId = await ensureLifecycleCap(runtime);
            await ensureOracleObjects(runtime);
            await ensureUnderlyingRegistered(runtime);
            await ensureCadences(runtime);
            const accountWrapperId = await ensureAccountWrapper(runtime);
            await ensureBootstrap(runtime, lifecycleCapId, accountWrapperId);
            await ensureMarkets(runtime, lifecycleCapId);
            await transferLifecycleCap(runtime, lifecycleCapId);

            result.status = "verifying";
            writeResult(result);
            result.verification = await verifyDeployment(runtime, external);
            result.status = "complete";
            result.completedAt = new Date().toISOString();
            result.lastError = null;
            writeResult(result);
            console.log(`[deploy] complete: ${OUT}`);
        } catch (error) {
            result.status = result.inFlight
                ? "ambiguous"
                : Object.keys(result.publishTx).length > 0 ||
                    Object.keys(result.transactions).length > 0
                  ? "partial"
                  : "failed";
            result.lastError = error instanceof Error ? error.message : String(error);
            writeResult(result);
            throw error;
        }
    } finally {
        rmSync(snapshot.directory, { recursive: true, force: true });
    }
}

const execute = process.argv.slice(2).includes("--execute");
const unknownArgs = process.argv.slice(2).filter((arg) => arg !== "--execute");
if (unknownArgs.length > 0) {
    throw new Error(`unknown deployment arguments: ${unknownArgs.join(", ")}`);
}

const lock = acquireLock();
run(execute)
    .catch((error) => {
        console.error(error);
        process.exitCode = 1;
    })
    .finally(() => {
        releaseLock(lock);
    });
