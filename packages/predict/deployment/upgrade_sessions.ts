// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/** Upgrade the deployed Testnet Sessions package to v2 and exercise spot trading. */
import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomUUID } from "node:crypto";
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
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import {
    Transaction,
    TransactionDataBuilder,
    type TransactionArgument,
    type TransactionResult,
} from "@mysten/sui/transactions";
import { fromBase58, fromBase64, toHex } from "@mysten/sui/utils";
import { assertIntegrationManifest, type IntegrationManifest } from "./deploy.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..", "..");
const NETWORK = "testnet";
const CHAIN_ID = "4c78adac";
const DEPLOYER = "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef";
const SUI = process.env.SUI_BINARY ?? "sui";
const SUI_VERSION = /^sui 1\.74\.1(?:-|$)/;
const PACKAGE_GAS_BUDGET = process.env.PACKAGE_GAS_BUDGET ?? "5000000000";
const TRANSACTION_GAS_BUDGET = BigInt(process.env.TRANSACTION_GAS_BUDGET ?? "1000000000");
const SESSION_GAS = 500_000_000n;
const SESSION_TRANSACTION_GAS_BUDGET = 50_000_000n;
const SESSION_TRANSACTION_COUNT = 4n;
const MAX_SESSION_FAILED_TRANSACTIONS = 4;
const SESSION_DURATION_MS = 5n * 60n * 1_000n;
const MAX_SPOT_PRINCIPAL = 2_000_000_000n;
const SMOKE_BUFFER = 50_000_000n;
const PRICE_SCALE = 1_000_000_000n;
const MAX_TAKER_FEE = 3_000_000n;
const CLOCK = normalizeId("0x6");
const ACCUMULATOR_ROOT = normalizeId("0xacc");
const ACCOUNT = "0xbdbb60b00f2d4f30daeff62f2c642b18433a8fcdfbebccc808df578df2a0c203";
const ACCOUNT_REGISTRY = "0x21a7ed28397363b5550853c1f08795731257de81028cd1bf87f20c0752c8ca2f";
const SESSIONS_V1 = "0x78887ffbb5e449776152c612fe05af03f729c02dbb7218c270e645c241ad527b";
const SESSIONS_CAP = "0xec1a56cd72b2a6a97c592b0a66512bf92ce2d0508ebac2b8956abbc5d98a55a8";
const WRAPPER = "0x7ea715df00320b9460cd17531ecb507d8cc28925dce5be5de40af448c1d34239";
const DEEPBOOK = "0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24";
const DEEPBOOK_ORIGINAL = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const DEEPBOOK_REGISTRY = "0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1";
const DEEP_SUI_POOL = "0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f";
const DEEP = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8";
const DEEP_TYPE = `${DEEP}::deep::DEEP`;
const SUI_TYPE = `${normalizeId("0x2")}::sui::SUI`;
const STATE_RELATIVE = "packages/predict/deployment/deployment.sessions-v2.testnet.state.json";
const MANIFEST_RELATIVE = "packages/predict/deployment/deployment.testnet.json";
const PUBLISHED_RELATIVE = "packages/sessions/Published.toml";
const STATE_PATH = resolve(REPO_ROOT, STATE_RELATIVE);
const STATE_TEMP = `${STATE_PATH}.tmp`;
const MANIFEST_PATH = resolve(REPO_ROOT, MANIFEST_RELATIVE);
const MANIFEST_TEMP = `${MANIFEST_PATH}.tmp`;
const PUBLISHED_PATH = resolve(REPO_ROOT, PUBLISHED_RELATIVE);
const PUBLISHED_TEMP = `${PUBLISHED_PATH}.tmp`;

const EXPECTED_DEPENDENCIES = new Set([
    normalizeId("0x1"),
    normalizeId("0x2"),
    "0xdf0bd2a0d201562f2bdecb1b77d7998c7af316f6fd7d1eab9b9035064f21bfd4",
    ACCOUNT,
    "0xed1295ff3c9a9415766afff20a74cdf2e362647be09aaf13b809302c0109e912",
    "0xfe742239a3b033f7d52ed5275f238c17d27498ca0ee5ea5672ea732eb3f4dbbb",
    WRAPPER,
    DEEPBOOK,
    "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
    DEEP,
    "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
    "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
    "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
    "0x6a54299d593fca24edf6b17bf8c3aff0b7ba8bc8f4276e9c1065689c50223bba",
]);
const EXPECTED_LINKAGES = new Map([...EXPECTED_DEPENDENCIES].map((id) => [id, id] as const));
EXPECTED_LINKAGES.delete(DEEPBOOK);
EXPECTED_LINKAGES.set(DEEPBOOK_ORIGINAL, DEEPBOOK);
const SESSION_TRANSACTION_LABELS = new Set([
    "smoke_session_limit_place",
    "smoke_session_limit_cancel",
    "smoke_session_market_fill",
    "smoke_return_session_gas",
]);

export interface SessionsUpgradeMode {
    execute: boolean;
    smoke: boolean;
}

interface InFlight {
    label: string;
    digest: string;
    startedAt: string;
}

interface SpotSmoke {
    attempt: number;
    status: "not_started" | "running" | "complete" | "failed";
    wrapperId: string | null;
    sessionAddress: string | null;
    poolId: string;
    quantity: string | null;
    fundingAmount: string | null;
    initialSuiBalance: string | null;
    initialDeepBalance: string | null;
    marketPreSuiBalance: string | null;
    marketPreDeepBalance: string | null;
    limitClientId: string | null;
    marketClientId: string | null;
    limitPrice: string | null;
    marketPriceLimit: string | null;
    limitOrderId: string | null;
    marketExecutedQuantity: string | null;
    marketQuoteQuantity: string | null;
    marketPaidFees: string | null;
    marketPostSuiBalance: string | null;
    marketPostDeepBalance: string | null;
    marketFillExact: boolean | null;
    accountFundsRecovered: boolean;
    sessionRevoked: boolean;
    sessionGasReturned: boolean;
    sessionFailedTransactions: number;
    transactions: Record<string, string>;
    lastError: string | null;
}

export interface SessionsUpgradeState {
    schemaVersion: 1;
    status:
        | "pending"
        | "upgrading"
        | "verifying"
        | "smoke"
        | "complete"
        | "failed"
        | "partial"
        | "ambiguous";
    network: "testnet";
    chainId: string;
    buildEnvironment: "testnet";
    deployer: string;
    packageGasBudget: string;
    transactionGasBudget: string;
    sessionGas: string;
    sessionTransactionGasBudget: string;
    maxSessionFailedTransactions: number;
    maxSpotPrincipal: string;
    rpcUrlHash: string | null;
    suiVersion: string | null;
    sourceCommit: string | null;
    startedAt: string | null;
    completedAt: string | null;
    previousPackageId: string;
    packageId: string | null;
    upgradeCapId: string;
    upgradeTx: string | null;
    inFlight: InFlight | null;
    transactions: Record<string, string>;
    verification: {
        packageVersion: "2";
        upgradeCapVersion: "2";
        moduleNames: ["sessions"];
        typeOriginsPreserved: true;
        dependencies: string[];
        sessionsAppAuthorized: true;
        wrapperAppAuthorized: true;
        verifiedAt: string;
    } | null;
    smoke: SpotSmoke;
    lastError: string | null;
}

interface ClientSnapshot {
    directory: string;
    configPath: string;
    rpcUrl: string;
    keystorePath: string;
}

interface Runtime {
    state: SessionsUpgradeState;
    snapshot: ClientSnapshot;
    client: SuiGrpcClient;
    signer: Ed25519Keypair;
    sourceCommit: string;
}

interface EventRecord {
    type?: string;
    parsedJson?: unknown;
}

export interface Receipt {
    digest?: string;
    effects?: unknown;
    events?: EventRecord[];
}

class KnownTransactionFailure extends Error {
    constructor(
        readonly label: string,
        message: string,
    ) {
        super(message);
        this.name = "KnownTransactionFailure";
    }
}

interface PackageMetadata {
    id: string;
    version: string;
    modules: string[];
    typeOrigins: Array<{ module: string; datatype: string; package: string }>;
    dependencies: string[];
    linkages: Array<{ originalId: string; upgradedId: string }>;
    previousTransaction: string | null;
}

interface UpgradeCapMetadata {
    packageId: string;
    version: string;
    policy: string;
    owner: string;
}

function asRecord(value: unknown): Record<string, unknown> {
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function normalizeId(value: string): string {
    const hex = value.toLowerCase().replace(/^0x/, "");
    return `0x${hex.padStart(64, "0")}`;
}

function requiredString(value: unknown, label: string): string {
    if (typeof value !== "string" || value.length === 0) throw new Error(`${label} is missing`);
    return value;
}

function decimal(value: unknown, label: string): string {
    const result = String(value);
    if (!/^\d+$/.test(result)) throw new Error(`${label} is not an unsigned integer`);
    return result;
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

function suiClient(snapshot: ClientSnapshot, args: string[]): string {
    return command(SUI, [
        "client",
        "--client.config",
        snapshot.configPath,
        "--client.env",
        NETWORK,
        ...args,
    ]);
}

export function parseSessionsUpgradeArgs(args: readonly string[]): SessionsUpgradeMode {
    const unknown = args.filter((arg) => arg !== "--execute" && arg !== "--smoke");
    if (unknown.length)
        throw new Error(`unknown Sessions upgrade arguments: ${unknown.join(", ")}`);
    const result = { execute: args.includes("--execute"), smoke: args.includes("--smoke") };
    if (result.smoke && !result.execute) throw new Error("--smoke requires --execute");
    return result;
}

export function assertSmokeSessionResume(
    sessionRevoked: boolean,
    marketCheckpointed: boolean,
    expiration: bigint | null,
    nowMs: bigint,
): void {
    if (marketCheckpointed) return;
    if (sessionRevoked) {
        throw new Error("smoke session was revoked before the market checkpoint");
    }
    if (expiration === null || expiration <= nowMs) {
        throw new Error("journaled smoke session is no longer authorized");
    }
}

export function assertUpgradeCapResumeVersion(
    packageCheckpointed: boolean,
    inFlightLabel: string | null,
    capVersion: string,
): void {
    const reconcilingUpgrade = !packageCheckpointed && inFlightLabel === "upgrade_sessions_v2";
    const valid = packageCheckpointed
        ? capVersion === "2"
        : reconcilingUpgrade
          ? capVersion === "1" || capVersion === "2"
          : capVersion === "1";
    if (!valid) throw new Error("live Sessions package is not at the expected upgrade boundary");
}

export interface ObservedPreflightBindings {
    sourceCommit: string;
    suiVersion: string;
    rpcUrlHash: string;
    network: string;
    chainId: string;
    deployer: string;
}

export function assertObservedPreflightBindings(
    state: SessionsUpgradeState,
    observed: ObservedPreflightBindings,
): void {
    if (state.sourceCommit && state.sourceCommit !== observed.sourceCommit) {
        throw new Error(
            `upgrade journal is bound to ${state.sourceCommit}, not ${observed.sourceCommit}`,
        );
    }
    if (!SUI_VERSION.test(observed.suiVersion)) {
        throw new Error(`unsupported Sui CLI ${observed.suiVersion}`);
    }
    if (state.suiVersion && state.suiVersion !== observed.suiVersion) {
        throw new Error(`upgrade journal is bound to Sui CLI ${state.suiVersion}`);
    }
    if (state.rpcUrlHash && state.rpcUrlHash !== observed.rpcUrlHash) {
        throw new Error("upgrade journal is bound to a different RPC endpoint");
    }
    if (
        observed.network !== NETWORK ||
        observed.chainId !== CHAIN_ID ||
        normalizeId(observed.deployer) !== DEPLOYER
    ) {
        throw new Error("isolated Sui CLI target does not match Testnet deployer");
    }
}

export function unexpectedUpgradeSourcePaths(status: string): string[] {
    const allowed = new Set([
        STATE_RELATIVE,
        `${STATE_RELATIVE}.tmp`,
        MANIFEST_RELATIVE,
        PUBLISHED_RELATIVE,
    ]);
    return status
        .split("\n")
        .filter(Boolean)
        .map((line) => line.slice(3))
        .filter((path) => !allowed.has(path));
}

function createSpotSmoke(attempt = 0): SpotSmoke {
    return {
        attempt,
        status: "not_started",
        wrapperId: null,
        sessionAddress: null,
        poolId: DEEP_SUI_POOL,
        quantity: null,
        fundingAmount: null,
        initialSuiBalance: null,
        initialDeepBalance: null,
        marketPreSuiBalance: null,
        marketPreDeepBalance: null,
        limitClientId: null,
        marketClientId: null,
        limitPrice: null,
        marketPriceLimit: null,
        limitOrderId: null,
        marketExecutedQuantity: null,
        marketQuoteQuantity: null,
        marketPaidFees: null,
        marketPostSuiBalance: null,
        marketPostDeepBalance: null,
        marketFillExact: null,
        accountFundsRecovered: false,
        sessionRevoked: false,
        sessionGasReturned: false,
        sessionFailedTransactions: 0,
        transactions: {},
        lastError: null,
    };
}

export function createSessionsUpgradeState(): SessionsUpgradeState {
    return {
        schemaVersion: 1,
        status: "pending",
        network: NETWORK,
        chainId: CHAIN_ID,
        buildEnvironment: NETWORK,
        deployer: DEPLOYER,
        packageGasBudget: PACKAGE_GAS_BUDGET,
        transactionGasBudget: TRANSACTION_GAS_BUDGET.toString(),
        sessionGas: SESSION_GAS.toString(),
        sessionTransactionGasBudget: SESSION_TRANSACTION_GAS_BUDGET.toString(),
        maxSessionFailedTransactions: MAX_SESSION_FAILED_TRANSACTIONS,
        maxSpotPrincipal: MAX_SPOT_PRINCIPAL.toString(),
        rpcUrlHash: null,
        suiVersion: null,
        sourceCommit: null,
        startedAt: null,
        completedAt: null,
        previousPackageId: SESSIONS_V1,
        packageId: null,
        upgradeCapId: SESSIONS_CAP,
        upgradeTx: null,
        inFlight: null,
        transactions: {},
        verification: null,
        smoke: createSpotSmoke(),
        lastError: null,
    };
}

export function assertSessionsUpgradeState(state: SessionsUpgradeState): void {
    if (
        state.schemaVersion !== 1 ||
        state.network !== NETWORK ||
        state.chainId !== CHAIN_ID ||
        state.buildEnvironment !== NETWORK ||
        normalizeId(state.deployer) !== DEPLOYER ||
        state.packageGasBudget !== PACKAGE_GAS_BUDGET ||
        state.transactionGasBudget !== TRANSACTION_GAS_BUDGET.toString() ||
        state.sessionGas !== SESSION_GAS.toString() ||
        state.sessionTransactionGasBudget !== SESSION_TRANSACTION_GAS_BUDGET.toString() ||
        state.maxSessionFailedTransactions !== MAX_SESSION_FAILED_TRANSACTIONS ||
        state.maxSpotPrincipal !== MAX_SPOT_PRINCIPAL.toString() ||
        normalizeId(state.previousPackageId) !== SESSIONS_V1 ||
        normalizeId(state.upgradeCapId) !== SESSIONS_CAP
    ) {
        throw new Error(`${STATE_RELATIVE} does not match the pinned Sessions v2 upgrade`);
    }
    if (state.packageId && !state.upgradeTx) throw new Error("package checkpoint lacks upgrade tx");
    if (state.verification && !state.packageId) throw new Error("verification lacks package ID");
    if (
        (SESSION_TRANSACTION_COUNT + BigInt(MAX_SESSION_FAILED_TRANSACTIONS)) *
            SESSION_TRANSACTION_GAS_BUDGET >
        SESSION_GAS
    ) {
        throw new Error("funded session gas does not cover its writes and retry reserve");
    }
    if (
        state.status === "complete" &&
        (!state.completedAt ||
            !state.sourceCommit ||
            !state.suiVersion ||
            !state.rpcUrlHash ||
            !state.verification ||
            state.smoke.status !== "complete" ||
            !state.smoke.marketExecutedQuantity ||
            state.smoke.marketFillExact !== true ||
            !state.smoke.accountFundsRecovered ||
            !state.smoke.sessionRevoked ||
            !state.smoke.sessionGasReturned)
    ) {
        throw new Error("complete Sessions upgrade lacks verification or smoke evidence");
    }
}

function loadState(): SessionsUpgradeState {
    if (!existsSync(STATE_PATH)) return createSessionsUpgradeState();
    const state = JSON.parse(readFileSync(STATE_PATH, "utf8")) as SessionsUpgradeState;
    assertSessionsUpgradeState(state);
    return state;
}

function writeState(state: SessionsUpgradeState): void {
    assertSessionsUpgradeState(state);
    writeFileSync(STATE_TEMP, `${JSON.stringify(state, null, 4)}\n`, { mode: 0o600 });
    chmodSync(STATE_TEMP, 0o600);
    renameSync(STATE_TEMP, STATE_PATH);
    chmodSync(STATE_PATH, 0o600);
}

export function buildSessionsUpgradeManifest(
    baseValue: unknown,
    state: SessionsUpgradeState,
): IntegrationManifest {
    assertIntegrationManifest(baseValue);
    assertSessionsUpgradeState(state);
    if (
        baseValue.schemaVersion !== 5 ||
        baseValue.packages.deepbookCoreAccount !== WRAPPER ||
        state.status !== "complete" ||
        state.inFlight ||
        !state.sourceCommit ||
        !state.packageId ||
        !state.verification ||
        state.smoke.status !== "complete"
    ) {
        throw new Error("Sessions v2 manifest requires a complete audited upgrade and spot smoke");
    }
    const manifest = JSON.parse(JSON.stringify(baseValue)) as IntegrationManifest;
    manifest.sourceCommit = state.sourceCommit;
    manifest.packages.sessions = normalizeId(state.packageId);
    assertIntegrationManifest(manifest);
    return manifest;
}

export function parsePackageMetadata(raw: unknown): PackageMetadata {
    const root = asRecord(raw);
    const contentRoot = asRecord(root.content ?? asRecord(root.data).content);
    const content = asRecord(contentRoot.Package ?? contentRoot.package ?? contentRoot);
    const modules = asRecord(content.module_map ?? content.moduleMap ?? content.modules);
    const origins = content.type_origin_table ?? content.typeOriginTable;
    const linkage = asRecord(content.linkage_table ?? content.linkageTable);
    if (!Array.isArray(origins)) throw new Error("package type origins are missing");
    const linkages = Object.entries(linkage)
        .map(([originalId, value]) => {
            const link = asRecord(value);
            return {
                originalId: normalizeId(originalId),
                upgradedId: normalizeId(
                    requiredString(link.upgraded_id ?? link.upgradedId, "linked package"),
                ),
            };
        })
        .sort((left, right) => left.originalId.localeCompare(right.originalId));
    return {
        id: normalizeId(requiredString(content.id ?? root.objectId, "package ID")),
        version: decimal(content.version ?? root.version, "package version"),
        modules: Object.keys(modules).sort(),
        typeOrigins: origins.map((value) => {
            const origin = asRecord(value);
            return {
                module: requiredString(origin.module_name ?? origin.moduleName, "origin module"),
                datatype: requiredString(
                    origin.datatype_name ?? origin.datatypeName,
                    "origin datatype",
                ),
                package: normalizeId(requiredString(origin.package, "origin package")),
            };
        }),
        dependencies: linkages.map(({ upgradedId }) => upgradedId).sort(),
        linkages,
        previousTransaction:
            typeof root.prevTx === "string"
                ? root.prevTx
                : typeof root.previousTransaction === "string"
                  ? root.previousTransaction
                  : null,
    };
}

export function parseUpgradeCapMetadata(raw: unknown): UpgradeCapMetadata {
    const root = asRecord(raw);
    const fields = asRecord(root.content ?? asRecord(root.data).content);
    const owner = asRecord(root.owner ?? asRecord(root.data).owner);
    return {
        packageId: normalizeId(requiredString(fields.package, "UpgradeCap package")),
        version: decimal(fields.version, "UpgradeCap version"),
        policy: decimal(fields.policy, "UpgradeCap policy"),
        owner: normalizeId(requiredString(owner.AddressOwner, "UpgradeCap owner")),
    };
}

function writeManifest(manifest: IntegrationManifest): void {
    writeFileSync(MANIFEST_TEMP, `${JSON.stringify(manifest, null, 4)}\n`, { mode: 0o644 });
    chmodSync(MANIFEST_TEMP, 0o644);
    renameSync(MANIFEST_TEMP, MANIFEST_PATH);
}

function writePublished(state: SessionsUpgradeState, suiVersion: string): void {
    if (!state.packageId || !state.upgradeTx || !state.verification) {
        throw new Error("cannot write Sessions publication metadata before audit");
    }
    const toolchain = suiVersion.match(/^sui ([0-9.]+)/)?.[1];
    if (!toolchain) throw new Error(`cannot parse toolchain from ${suiVersion}`);
    const text = [
        "# Generated by Move",
        "# This file contains metadata about published versions of this package in different environments",
        "# This file SHOULD be committed to source control",
        "",
        "[published.testnet]",
        `chain-id = "${CHAIN_ID}"`,
        `published-at = "${state.packageId}"`,
        `original-id = "${SESSIONS_V1}"`,
        "version = 2",
        `toolchain-version = "${toolchain}"`,
        'build-config = { flavor = "sui", edition = "2024" }',
        `upgrade-capability = "${SESSIONS_CAP}"`,
        "",
    ].join("\n");
    writeFileSync(PUBLISHED_TEMP, text, { mode: 0o644 });
    chmodSync(PUBLISHED_TEMP, 0o644);
    renameSync(PUBLISHED_TEMP, PUBLISHED_PATH);
}

function stripYaml(value: string): string {
    const result = value.trim();
    return (result.startsWith('"') && result.endsWith('"')) ||
        (result.startsWith("'") && result.endsWith("'"))
        ? result.slice(1, -1)
        : result;
}

function snapshotClientConfig(): ClientSnapshot {
    const source =
        process.env.SUI_CLIENT_CONFIG ?? resolve(homedir(), ".sui", "sui_config", "client.yaml");
    const yaml = readFileSync(source, "utf8");
    const activeEnv = yaml.match(/^active_env:\s*(.+)$/m)?.[1];
    const activeAddress = yaml.match(/^active_address:\s*(.+)$/m)?.[1];
    if (
        !activeEnv ||
        stripYaml(activeEnv) !== NETWORK ||
        !activeAddress ||
        normalizeId(stripYaml(activeAddress)) !== DEPLOYER
    ) {
        throw new Error(`Sui client must target ${NETWORK} as ${DEPLOYER}`);
    }
    const block = yaml.match(
        new RegExp(
            `^\\s*- alias:\\s*${NETWORK}\\s*$([\\s\\S]*?)(?=^\\s*- alias:|^active_env:)`,
            "m",
        ),
    )?.[1];
    const rpc = block?.match(/^\s*rpc:\s*(.+)$/m)?.[1];
    const chain = block?.match(/^\s*chain_id:\s*(.+)$/m)?.[1];
    if (!rpc || !chain || stripYaml(chain) !== CHAIN_ID) {
        throw new Error(`Sui config lacks ${NETWORK}/${CHAIN_ID}`);
    }
    const configured = yaml.match(/keystore:\s*\n\s*File:\s*(.+)$/m)?.[1];
    const keystorePath =
        process.env.SUI_KEYSTORE_PATH ??
        (configured
            ? stripYaml(configured)
            : resolve(homedir(), ".sui", "sui_config", "sui.keystore"));
    const directory = mkdtempSync(join(tmpdir(), "sessions-v2-testnet-"));
    const configPath = resolve(directory, "client.yaml");
    copyFileSync(source, configPath);
    chmodSync(configPath, 0o600);
    return { directory, configPath, rpcUrl: stripYaml(rpc), keystorePath };
}

function signerFromKeystore(path: string): Ed25519Keypair {
    const entries = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!Array.isArray(entries)) throw new Error(`invalid Sui keystore ${path}`);
    for (const entry of entries) {
        if (typeof entry !== "string") continue;
        const raw = fromBase64(entry);
        if (raw.length !== 33 || raw[0] !== 0) continue;
        const signer = Ed25519Keypair.fromSecretKey(raw.slice(1));
        if (normalizeId(signer.getPublicKey().toSuiAddress()) === DEPLOYER) return signer;
    }
    throw new Error(`configured keystore has no Ed25519 key for ${DEPLOYER}`);
}

async function shortChainId(client: SuiGrpcClient): Promise<string> {
    const { chainIdentifier } = await client.core.getChainIdentifier();
    return toHex(fromBase58(chainIdentifier).slice(0, 4));
}

function effectsError(effects: unknown): string | null {
    const status = asRecord(asRecord(effects).status);
    if (status.status === "success" || status.success === true) return null;
    return typeof status.error === "string" ? status.error : JSON.stringify(status);
}

function coreReceipt(response: unknown): Receipt {
    const envelope = asRecord(response);
    const transaction = asRecord(envelope.Transaction ?? envelope.FailedTransaction);
    const rawEvents = transaction.events;
    return {
        digest: typeof transaction.digest === "string" ? transaction.digest : undefined,
        effects: transaction.effects,
        events: Array.isArray(rawEvents)
            ? rawEvents.map((value) => {
                  const event = asRecord(value);
                  return {
                      type: typeof event.eventType === "string" ? event.eventType : undefined,
                      parsedJson: event.json,
                  };
              })
            : [],
    };
}

async function settledReceipt(client: SuiGrpcClient, digest: string): Promise<Receipt> {
    let last: unknown;
    for (let attempt = 0; attempt < 30; attempt++) {
        try {
            return coreReceipt(
                await client.getTransaction({
                    digest,
                    include: { effects: true, events: true, objectTypes: true },
                }),
            );
        } catch (error) {
            last = error;
            await new Promise((done) => setTimeout(done, 250));
        }
    }
    throw last;
}

export function commitSuccessfulTransaction(
    state: SessionsUpgradeState,
    label: string,
    digest: string,
): void {
    state.transactions[label] = digest;
    if (label.startsWith("smoke_")) state.smoke.transactions[label] = digest;
    state.inFlight = null;
}

export function commitFailedTransaction(
    state: SessionsUpgradeState,
    label: string,
    digest: string,
    failure: string,
): void {
    if (SESSION_TRANSACTION_LABELS.has(label)) state.smoke.sessionFailedTransactions += 1;
    state.inFlight = null;
    state.lastError = `${label} failed at ${digest}: ${failure}`;
}

export function canRetrySessionTransaction(state: SessionsUpgradeState, label: string): boolean {
    return (
        SESSION_TRANSACTION_LABELS.has(label) &&
        state.smoke.sessionFailedTransactions < MAX_SESSION_FAILED_TRANSACTIONS
    );
}

export async function reconcileJournaledTransaction(
    state: SessionsUpgradeState,
    getReceipt: (digest: string) => Promise<Receipt>,
    checkpoint: (label: string, receipt: Receipt, digest: string) => Promise<void>,
    persist: (state: SessionsUpgradeState) => void,
): Promise<string | null> {
    const inFlight = state.inFlight;
    if (!inFlight) return null;
    let receipt: Receipt;
    try {
        receipt = await getReceipt(inFlight.digest);
    } catch {
        throw new Error(
            `${inFlight.label}/${inFlight.digest} is not visible on Testnet; fail closed before constructing replacement bytes`,
        );
    }
    const failure = effectsError(receipt.effects);
    if (failure) {
        commitFailedTransaction(state, inFlight.label, inFlight.digest, failure);
        persist(state);
        throw new KnownTransactionFailure(
            inFlight.label,
            requiredString(state.lastError, "failed transaction error"),
        );
    }
    await checkpoint(inFlight.label, receipt, inFlight.digest);
    commitSuccessfulTransaction(state, inFlight.label, inFlight.digest);
    persist(state);
    return inFlight.digest;
}

async function executeBytes(
    runtime: Runtime,
    label: string,
    bytes: Uint8Array,
    signer = runtime.signer,
): Promise<Receipt> {
    if (runtime.state.inFlight) throw new Error(`${runtime.state.inFlight.label} is in flight`);
    const simulated = await runtime.client.simulateTransaction({
        transaction: bytes,
        checksEnabled: true,
        include: { effects: true },
    });
    const dryRunError = effectsError(coreReceipt(simulated).effects);
    if (dryRunError) throw new Error(`${label} dry run failed: ${dryRunError}`);
    const digest = TransactionDataBuilder.getDigestFromBytes(bytes);
    runtime.state.inFlight = { label, digest, startedAt: new Date().toISOString() };
    writeState(runtime.state);
    let receipt: Receipt;
    try {
        const { signature } = await signer.signTransaction(bytes);
        receipt = coreReceipt(
            await runtime.client.executeTransaction({
                transaction: bytes,
                signatures: [signature],
                include: { effects: true, events: true, objectTypes: true },
            }),
        );
    } catch (error) {
        try {
            receipt = await settledReceipt(runtime.client, digest);
        } catch {
            runtime.state.status = "ambiguous";
            runtime.state.lastError = `${label} submission is ambiguous at ${digest}: ${String(error)}`;
            writeState(runtime.state);
            throw new Error(runtime.state.lastError);
        }
    }
    if (receipt.digest !== digest) throw new Error(`${label} returned the wrong digest`);
    const failure = effectsError(receipt.effects);
    if (failure) {
        commitFailedTransaction(runtime.state, label, digest, failure);
        writeState(runtime.state);
        throw new KnownTransactionFailure(
            label,
            requiredString(runtime.state.lastError, "failed transaction error"),
        );
    }
    receipt = await settledReceipt(runtime.client, digest);
    await checkpointTransaction(runtime, label, receipt, digest);
    commitSuccessfulTransaction(runtime.state, label, digest);
    writeState(runtime.state);
    console.log(`[sessions:v2] ${label}: ${digest}`);
    return receipt;
}

async function executeTransaction(
    runtime: Runtime,
    label: string,
    tx: Transaction,
    signer = runtime.signer,
    gasBudget = TRANSACTION_GAS_BUDGET,
): Promise<Receipt> {
    if (
        SESSION_TRANSACTION_LABELS.has(label) &&
        label !== "smoke_return_session_gas" &&
        runtime.state.smoke.sessionFailedTransactions >= MAX_SESSION_FAILED_TRANSACTIONS
    ) {
        throw new Error("temporary session exhausted its bounded transaction retry reserve");
    }
    tx.setSender(normalizeId(signer.getPublicKey().toSuiAddress()));
    tx.setGasBudget(gasBudget);
    return executeBytes(runtime, label, await tx.build({ client: runtime.client }), signer);
}

function call(
    tx: Transaction,
    target: string,
    args: TransactionArgument[],
    typeArguments: string[] = [],
): TransactionResult {
    return tx.moveCall({
        target: target as `${string}::${string}::${string}`,
        arguments: args,
        typeArguments,
    });
}

async function devInspect(runtime: Runtime, label: string, tx: Transaction): Promise<unknown> {
    tx.setSender(DEPLOYER);
    const response = await runtime.client.simulateTransaction({
        transaction: tx,
        checksEnabled: false,
        include: { commandResults: true, effects: true },
    });
    const error = effectsError(coreReceipt(response).effects);
    if (error) throw new Error(`${label} simulation failed: ${error}`);
    return response;
}

function returnBytes(response: unknown, resultIndex = 0, returnIndex = 0): number[] {
    const results = asRecord(response).commandResults;
    if (!Array.isArray(results)) throw new Error("simulation has no command results");
    const values = asRecord(results[resultIndex]).returnValues;
    if (!Array.isArray(values)) throw new Error(`command ${resultIndex} has no return values`);
    const bcs = asRecord(values[returnIndex]).bcs;
    if (bcs instanceof Uint8Array) return Array.from(bcs);
    if (Array.isArray(bcs)) return bcs as number[];
    throw new Error("simulation return is not byte encoded");
}

function parseU64(bytes: number[]): bigint {
    if (bytes.length < 8) throw new Error("invalid u64 return");
    let result = 0n;
    for (let index = 7; index >= 0; index--) result = (result << 8n) + BigInt(bytes[index]);
    return result;
}

function parseBool(bytes: number[]): boolean {
    if (bytes.length !== 1) throw new Error("invalid bool return");
    return bytes[0] === 1;
}

function parseAddress(bytes: number[]): string {
    if (bytes.length < 32) throw new Error("invalid address return");
    return normalizeId(
        `0x${bytes
            .slice(0, 32)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("")}`,
    );
}

function parseOptionU64(bytes: number[]): bigint | null {
    if (bytes.length === 1 && bytes[0] === 0) return null;
    if (bytes.length !== 9 || bytes[0] !== 1) throw new Error("invalid Option<u64> return");
    return parseU64(bytes.slice(1));
}

async function inspectAuthorization(
    runtime: Runtime,
): Promise<{ sessions: boolean; wrapper: boolean }> {
    const tx = new Transaction();
    call(
        tx,
        `${ACCOUNT}::account_registry::is_app_authorized`,
        [tx.object(ACCOUNT_REGISTRY)],
        [`${runtime.state.packageId ?? SESSIONS_V1}::sessions::SessionsApp`],
    );
    call(
        tx,
        `${DEEPBOOK}::registry::is_app_authorized`,
        [tx.object(DEEPBOOK_REGISTRY)],
        [`${WRAPPER}::account_data::DeepbookCoreAccountApp`],
    );
    const response = await devInspect(runtime, "application authorization", tx);
    return {
        sessions: parseBool(returnBytes(response, 0)),
        wrapper: parseBool(returnBytes(response, 1)),
    };
}

function readPackage(snapshot: ClientSnapshot, id: string): PackageMetadata {
    return parsePackageMetadata(JSON.parse(suiClient(snapshot, ["object", id, "--json"])));
}

function readUpgradeCap(snapshot: ClientSnapshot): UpgradeCapMetadata {
    return parseUpgradeCapMetadata(
        JSON.parse(suiClient(snapshot, ["object", SESSIONS_CAP, "--json"])),
    );
}

function assertExactDependencies(dependencies: string[], label: string): void {
    const expected = [...EXPECTED_DEPENDENCIES].sort();
    const actual = [...dependencies].map(normalizeId).sort();
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(
            `${label} dependency mismatch: got ${actual.join(",")}; expected ${expected.join(",")}`,
        );
    }
}

function normalizedLinkages(linkages: ReadonlyMap<string, string>): PackageMetadata["linkages"] {
    return [...linkages]
        .map(([originalId, upgradedId]) => ({ originalId, upgradedId }))
        .sort((left, right) => left.originalId.localeCompare(right.originalId));
}

function assertExactLinkages(
    actual: PackageMetadata["linkages"],
    expectedMap: ReadonlyMap<string, string>,
    label: string,
): void {
    const expected = normalizedLinkages(expectedMap);
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(
            `${label} original-to-upgraded linkage mismatch: got ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}`,
        );
    }
}

function auditDependencySet(metadata: PackageMetadata): void {
    assertExactDependencies(metadata.dependencies, "Sessions v2 linkage");
    assertExactLinkages(metadata.linkages, EXPECTED_LINKAGES, "Sessions v2");
}

function compiledDependencies(): string[] {
    const lock = resolve(REPO_ROOT, "packages", "sessions", "Move.lock");
    const hadLock = existsSync(lock);
    try {
        const output = command(SUI, [
            "move",
            "build",
            "--path",
            resolve(REPO_ROOT, "packages", "sessions"),
            "--dump-bytecode-as-base64",
            "--build-env",
            NETWORK,
            "--warnings-are-errors",
        ]);
        const line = output
            .split("\n")
            .reverse()
            .find((candidate) => candidate.trimStart().startsWith('{"modules"'));
        if (!line) throw new Error("Sui Move build did not return bytecode metadata");
        const metadata = asRecord(JSON.parse(line));
        if (!Array.isArray(metadata.dependencies)) {
            throw new Error("Sui Move build did not return a dependency list");
        }
        const dependencies = metadata.dependencies.map((value) =>
            normalizeId(requiredString(value, "compiled dependency")),
        );
        assertExactDependencies(dependencies, "compiled Sessions v2");
        return dependencies;
    } finally {
        if (!hadLock) rmSync(lock, { force: true });
    }
}

async function auditUpgrade(runtime: Runtime): Promise<void> {
    if (!runtime.state.packageId || !runtime.state.upgradeTx)
        throw new Error("upgrade is incomplete");
    const metadata = readPackage(runtime.snapshot, runtime.state.packageId);
    const cap = readUpgradeCap(runtime.snapshot);
    if (
        metadata.id !== runtime.state.packageId ||
        metadata.version !== "2" ||
        JSON.stringify(metadata.modules) !== JSON.stringify(["sessions"]) ||
        metadata.previousTransaction !== runtime.state.upgradeTx
    ) {
        throw new Error("Sessions v2 package identity, version, modules, or provenance mismatch");
    }
    const expectedOrigins = ["SessionAuthorized", "SessionRevoked", "SessionsApp", "SessionsData"];
    if (
        metadata.typeOrigins.length !== 4 ||
        metadata.typeOrigins.some((origin) => origin.package !== SESSIONS_V1) ||
        JSON.stringify(metadata.typeOrigins.map((origin) => origin.datatype).sort()) !==
            JSON.stringify(expectedOrigins)
    ) {
        throw new Error("Sessions v2 did not preserve all v1 type origins");
    }
    auditDependencySet(metadata);
    if (
        cap.packageId !== SESSIONS_V1 ||
        cap.version !== "2" ||
        cap.policy !== "0" ||
        cap.owner !== DEPLOYER
    ) {
        throw new Error("Sessions UpgradeCap identity, policy, owner, or version mismatch");
    }
    const authorization = await inspectAuthorization(runtime);
    if (!authorization.sessions || !authorization.wrapper) {
        throw new Error("SessionsApp or DeepbookCoreAccountApp is not authorized");
    }
    runtime.state.verification = {
        packageVersion: "2",
        upgradeCapVersion: "2",
        moduleNames: ["sessions"],
        typeOriginsPreserved: true,
        dependencies: metadata.dependencies,
        sessionsAppAuthorized: true,
        wrapperAppAuthorized: true,
        verifiedAt: new Date().toISOString(),
    };
    writeState(runtime.state);
}

function transactionBlock(snapshot: ClientSnapshot, digest: string): Record<string, unknown> {
    return JSON.parse(suiClient(snapshot, ["tx-block", digest, "--json"])) as Record<
        string,
        unknown
    >;
}

function publishedPackageId(block: Record<string, unknown>): string {
    const changes = block.objectChanges;
    if (!Array.isArray(changes)) throw new Error("upgrade receipt has no object changes");
    for (const value of changes) {
        const change = asRecord(value);
        if (change.type === "published" && typeof change.packageId === "string") {
            return normalizeId(change.packageId);
        }
    }
    throw new Error("upgrade receipt has no published package");
}

export function serializedUpgradeArgs(): string[] {
    return [
        "upgrade",
        resolve(REPO_ROOT, "packages", "sessions"),
        "--upgrade-capability",
        SESSIONS_CAP,
        "--warnings-are-errors",
        "--force",
        "--sender",
        DEPLOYER,
        // Immutable Testnet dependencies do not all reproduce byte-for-byte with this
        // historical toolchain. Preflight independently binds the exact compiled latest-ID
        // set and the exact live original-ID -> latest-ID map before these bytes are signed.
        "--skip-dependency-verification",
        "--gas-budget",
        PACKAGE_GAS_BUDGET,
        "--serialize-unsigned-transaction",
    ];
}

function serializedUpgrade(snapshot: ClientSnapshot): Uint8Array {
    const lock = resolve(REPO_ROOT, "packages", "sessions", "Move.lock");
    const hadLock = existsSync(lock);
    try {
        const output = suiClient(snapshot, serializedUpgradeArgs());
        const encoded = output.split(/\r?\n/).filter(Boolean).at(-1);
        if (!encoded || !/^[A-Za-z0-9+/=]+$/.test(encoded)) {
            throw new Error("Sui CLI did not return serialized upgrade bytes");
        }
        return fromBase64(encoded);
    } finally {
        if (!hadLock) rmSync(lock, { force: true });
    }
}

async function runUpgrade(runtime: Runtime): Promise<void> {
    if (runtime.state.packageId) {
        await auditUpgrade(runtime);
        return;
    }
    runtime.state.status = "upgrading";
    writeState(runtime.state);
    await executeBytes(runtime, "upgrade_sessions_v2", serializedUpgrade(runtime.snapshot));
    await auditUpgrade(runtime);
}

async function reconcileInFlight(runtime: Runtime): Promise<void> {
    const label = runtime.state.inFlight?.label;
    let digest: string | null;
    try {
        digest = await reconcileJournaledTransaction(
            runtime.state,
            (value) => settledReceipt(runtime.client, value),
            (checkpointLabel, receipt, checkpointDigest) =>
                checkpointTransaction(runtime, checkpointLabel, receipt, checkpointDigest),
            writeState,
        );
    } catch (error) {
        if (
            error instanceof KnownTransactionFailure &&
            canRetrySessionTransaction(runtime.state, error.label)
        ) {
            console.log(`[sessions:v2] ${error.message}; retrying from its semantic checkpoint`);
            return;
        }
        throw error;
    }
    if (digest) console.log(`[sessions:v2] reconciled ${label}: ${digest}`);
}

async function accountWrapper(runtime: Runtime): Promise<string> {
    const tx = new Transaction();
    call(tx, `${ACCOUNT}::account_registry::derived_wrapper_address`, [
        tx.object(ACCOUNT_REGISTRY),
        tx.pure.address(DEPLOYER),
    ]);
    return parseAddress(returnBytes(await devInspect(runtime, "account wrapper", tx)));
}

async function accountBalance(
    runtime: Runtime,
    wrapper: string,
    coinType: string,
): Promise<bigint> {
    const tx = new Transaction();
    const account = call(tx, `${ACCOUNT}::account::load_account`, [tx.object(wrapper)]);
    call(
        tx,
        `${ACCOUNT}::account::balance`,
        [account, tx.object(ACCUMULATOR_ROOT), tx.object(CLOCK)],
        [coinType],
    );
    return parseU64(returnBytes(await devInspect(runtime, `${coinType} account balance`, tx), 1));
}

async function poolParameters(runtime: Runtime): Promise<{
    tickSize: bigint;
    lotSize: bigint;
    minSize: bigint;
    bestAsk: bigint;
    bestBid: bigint | null;
    quoteRequired: bigint;
}> {
    const types = [DEEP_TYPE, SUI_TYPE];
    const tx = new Transaction();
    call(tx, `${DEEPBOOK}::pool::pool_book_params`, [tx.object(DEEP_SUI_POOL)], types);
    call(
        tx,
        `${DEEPBOOK}::pool::best_ask_price`,
        [tx.object(DEEP_SUI_POOL), tx.object(CLOCK)],
        types,
    );
    call(
        tx,
        `${DEEPBOOK}::pool::best_bid_price`,
        [tx.object(DEEP_SUI_POOL), tx.object(CLOCK)],
        types,
    );
    const response = await devInspect(runtime, "DEEP/SUI book", tx);
    const tickSize = parseU64(returnBytes(response, 0, 0));
    const lotSize = parseU64(returnBytes(response, 0, 1));
    const minSize = parseU64(returnBytes(response, 0, 2));
    const bestAsk = parseOptionU64(returnBytes(response, 1));
    const bestBid = parseOptionU64(returnBytes(response, 2));
    if (!bestAsk) throw new Error("DEEP/SUI has no live ask for the market-fill smoke");
    const quoteTx = new Transaction();
    call(
        quoteTx,
        `${DEEPBOOK}::pool::get_quote_quantity_in`,
        [
            quoteTx.object(DEEP_SUI_POOL),
            quoteTx.pure.u64(minSize),
            quoteTx.pure.bool(false),
            quoteTx.object(CLOCK),
        ],
        types,
    );
    const quoteResponse = await devInspect(runtime, "DEEP/SUI market quote", quoteTx);
    const executable = parseU64(returnBytes(quoteResponse, 0, 0));
    const quoteRequired = parseU64(returnBytes(quoteResponse, 0, 1));
    if (executable < minSize || quoteRequired === 0n)
        throw new Error("DEEP/SUI quote is not fillable");
    return { tickSize, lotSize, minSize, bestAsk, bestBid, quoteRequired };
}

async function openOrderCount(runtime: Runtime, wrapper: string): Promise<bigint> {
    const tx = new Transaction();
    const account = call(tx, `${ACCOUNT}::account::load_account`, [tx.object(wrapper)]);
    const orders = call(
        tx,
        `${WRAPPER}::deepbook_core_account::pool_account_open_orders`,
        [tx.object(DEEP_SUI_POOL), account],
        [DEEP_TYPE, SUI_TYPE],
    );
    call(tx, `${normalizeId("0x2")}::vec_set::length`, [orders], ["u128"]);
    return parseU64(returnBytes(await devInspect(runtime, "open spot orders", tx), 2));
}

async function sessionExpiration(
    runtime: Runtime,
    wrapper: string,
    session: string,
): Promise<bigint | null> {
    const tx = new Transaction();
    call(tx, `${runtime.state.packageId}::sessions::session_expiration_ms`, [
        tx.object(wrapper),
        tx.pure.address(session),
    ]);
    return parseOptionU64(returnBytes(await devInspect(runtime, "session expiration", tx)));
}

async function clockTimestamp(runtime: Runtime): Promise<bigint> {
    const tx = new Transaction();
    call(tx, `${normalizeId("0x2")}::clock::timestamp_ms`, [tx.object(CLOCK)]);
    return parseU64(returnBytes(await devInspect(runtime, "clock timestamp", tx)));
}

function eventJson(receipt: Receipt, suffix: string): Record<string, unknown> {
    const event = receipt.events?.find((candidate) => candidate.type?.endsWith(suffix));
    if (!event) throw new Error(`transaction ${receipt.digest} did not emit ${suffix}`);
    return asRecord(event.parsedJson);
}

function smokeValue(smoke: SpotSmoke, key: keyof SpotSmoke, label: string): string {
    return requiredString(smoke[key], label);
}

function eventId(value: unknown, label: string): string {
    if (typeof value === "string") return normalizeId(value);
    const record = asRecord(value);
    return normalizeId(requiredString(record.bytes ?? record.id, label));
}

function eventBool(value: unknown, label: string): boolean {
    if (typeof value !== "boolean") throw new Error(`${label} is not boolean`);
    return value;
}

async function checkpointTransaction(
    runtime: Runtime,
    label: string,
    receipt: Receipt,
    digest: string,
): Promise<void> {
    const smoke = runtime.state.smoke;
    if (label === "upgrade_sessions_v2") {
        runtime.state.upgradeTx = digest;
        runtime.state.packageId = publishedPackageId(transactionBlock(runtime.snapshot, digest));
        runtime.state.status = "verifying";
        return;
    }
    const wrapper = smokeValue(smoke, "wrapperId", "smoke wrapper");
    if (label === "smoke_authorize_and_fund") {
        const session = smokeValue(smoke, "sessionAddress", "smoke session");
        const expiration = await sessionExpiration(runtime, wrapper, session);
        const suiBalance = await accountBalance(runtime, wrapper, SUI_TYPE);
        const deepBalance = await accountBalance(runtime, wrapper, DEEP_TYPE);
        const expectedSui =
            BigInt(smokeValue(smoke, "initialSuiBalance", "initial SUI balance")) +
            BigInt(smokeValue(smoke, "fundingAmount", "smoke funding"));
        const expectedDeep = BigInt(
            smokeValue(smoke, "initialDeepBalance", "initial DEEP balance"),
        );
        const sessionBalance = await runtime.client.getBalance({ owner: session });
        if (
            expiration === null ||
            suiBalance !== expectedSui ||
            deepBalance !== expectedDeep ||
            BigInt(sessionBalance.balance.balance) !== SESSION_GAS
        ) {
            throw new Error("authorize/fund checkpoint does not match the journaled smoke bounds");
        }
        return;
    }
    if (label === "smoke_session_limit_place") {
        const placed = eventJson(receipt, "::order_info::OrderPlaced");
        if (
            eventId(placed.pool_id ?? placed.poolId, "limit pool") !== DEEP_SUI_POOL ||
            decimal(placed.client_order_id ?? placed.clientOrderId, "limit client order ID") !==
                smokeValue(smoke, "limitClientId", "limit client order ID") ||
            decimal(placed.placed_quantity ?? placed.placedQuantity, "limit quantity") !==
                smokeValue(smoke, "quantity", "limit quantity") ||
            decimal(placed.price, "limit price") !==
                smokeValue(smoke, "limitPrice", "limit price") ||
            eventBool(placed.is_bid ?? placed.isBid, "limit direction") !== true
        ) {
            throw new Error("limit placement event does not match the journaled order");
        }
        const orderId = decimal(placed.order_id ?? placed.orderId, "limit order ID");
        if ((await openOrderCount(runtime, wrapper)) !== 1n) {
            throw new Error("non-crossing limit order is not open at checkpoint");
        }
        smoke.limitOrderId = orderId;
        return;
    }
    if (label === "smoke_session_limit_cancel" || label === "smoke_owner_cancel_cleanup") {
        if ((await openOrderCount(runtime, wrapper)) !== 0n) {
            throw new Error("limit order remains open after cancellation");
        }
        return;
    }
    if (label === "smoke_session_market_fill") {
        const info = eventJson(receipt, "::order_info::OrderInfo");
        const quantity = BigInt(smokeValue(smoke, "quantity", "market quantity"));
        const executed = BigInt(
            decimal(info.executed_quantity ?? info.executedQuantity, "executed quantity"),
        );
        const quote = BigInt(
            decimal(
                info.cumulative_quote_quantity ?? info.cumulativeQuoteQuantity,
                "market quote quantity",
            ),
        );
        const paidFees = BigInt(decimal(info.paid_fees ?? info.paidFees, "market paid fees"));
        const expectedStatus = executed === quantity ? "2" : "3";
        if (
            eventId(info.pool_id ?? info.poolId, "market pool") !== DEEP_SUI_POOL ||
            decimal(info.client_order_id ?? info.clientOrderId, "market client order ID") !==
                smokeValue(smoke, "marketClientId", "market client order ID") ||
            decimal(info.original_quantity ?? info.originalQuantity, "market original quantity") !==
                quantity.toString() ||
            decimal(info.order_type ?? info.orderType, "market order type") !== "1" ||
            decimal(info.status, "market order status") !== expectedStatus ||
            eventBool(info.is_bid ?? info.isBid, "market direction") !== true ||
            eventBool(info.market_order ?? info.marketOrder, "market order flag") !== true ||
            eventBool(info.order_inserted ?? info.orderInserted, "market insertion flag") !==
                false ||
            eventBool(info.fee_is_deep ?? info.feeIsDeep, "market fee currency") !== false ||
            executed > quantity ||
            (executed === 0n) !== (quote === 0n)
        ) {
            throw new Error("market result event does not match the journaled order");
        }
        const preSui = BigInt(smokeValue(smoke, "marketPreSuiBalance", "pre-market SUI balance"));
        const preDeep = BigInt(
            smokeValue(smoke, "marketPreDeepBalance", "pre-market DEEP balance"),
        );
        const postSui = await accountBalance(runtime, wrapper, SUI_TYPE);
        const postDeep = await accountBalance(runtime, wrapper, DEEP_TYPE);
        if (postSui !== preSui - quote - paidFees || postDeep !== preDeep + executed) {
            throw new Error("market fill Account deltas do not match OrderInfo");
        }
        smoke.marketExecutedQuantity = executed.toString();
        smoke.marketQuoteQuantity = quote.toString();
        smoke.marketPaidFees = paidFees.toString();
        smoke.marketPostSuiBalance = postSui.toString();
        smoke.marketPostDeepBalance = postDeep.toString();
        smoke.marketFillExact = executed === quantity;
        return;
    }
    if (label === "smoke_revoke_session") {
        const session = smokeValue(smoke, "sessionAddress", "smoke session");
        if ((await sessionExpiration(runtime, wrapper, session)) !== null) {
            throw new Error("session grant remains after revocation");
        }
        smoke.sessionRevoked = true;
        return;
    }
    if (label === "smoke_recover_account_funds") {
        const suiBalance = await accountBalance(runtime, wrapper, SUI_TYPE);
        const deepBalance = await accountBalance(runtime, wrapper, DEEP_TYPE);
        if (
            suiBalance !== BigInt(smokeValue(smoke, "initialSuiBalance", "initial SUI balance")) ||
            deepBalance !== BigInt(smokeValue(smoke, "initialDeepBalance", "initial DEEP balance"))
        ) {
            throw new Error("smoke-attributable Account funds were not recovered to baseline");
        }
        smoke.accountFundsRecovered = true;
        return;
    }
    if (label === "smoke_return_session_gas") {
        const session = smokeValue(smoke, "sessionAddress", "smoke session");
        const balance = await runtime.client.getBalance({ owner: session });
        if (BigInt(balance.balance.balance) !== 0n) {
            throw new Error("temporary session gas remains after return transaction");
        }
        smoke.sessionGasReturned = true;
        return;
    }
    throw new Error(`no semantic checkpoint is defined for ${label}`);
}

async function cleanupOwnerOrder(
    runtime: Runtime,
    wrapper: string,
    orderId: bigint,
): Promise<void> {
    const count = await openOrderCount(runtime, wrapper);
    if (count === 0n) return;
    if (count !== 1n) throw new Error(`smoke Account has ${count} open orders during cleanup`);
    const tx = new Transaction();
    const auth = call(tx, `${ACCOUNT}::account::generate_auth`, []);
    call(
        tx,
        `${WRAPPER}::deepbook_core_account::cancel_live_order`,
        [
            tx.object(DEEP_SUI_POOL),
            tx.object(wrapper),
            auth,
            tx.pure.u128(orderId),
            tx.object(CLOCK),
        ],
        [DEEP_TYPE, SUI_TYPE],
    );
    await executeTransaction(runtime, "smoke_owner_cancel_cleanup", tx);
}

function smokeSessionSigner(runtime: Runtime): Ed25519Keypair {
    // Derive the one-rollout session deterministically so a resumed process can clean it up
    // without putting any private key or signature in the operator journal.
    const seed = createHmac("sha256", runtime.signer.getSecretKey())
        .update(
            `deepbookv3/DBU-712/sessions-v2-smoke/${runtime.sourceCommit}/${runtime.state.packageId}`,
        )
        .digest();
    return Ed25519Keypair.fromSecretKey(seed);
}

async function ensureSessionRevoked(runtime: Runtime, wrapper: string): Promise<void> {
    const session = smokeValue(runtime.state.smoke, "sessionAddress", "smoke session");
    if ((await sessionExpiration(runtime, wrapper, session)) === null) {
        runtime.state.smoke.sessionRevoked = true;
        writeState(runtime.state);
        return;
    }
    const revoke = new Transaction();
    call(revoke, `${runtime.state.packageId}::sessions::revoke_session`, [
        revoke.object(wrapper),
        revoke.pure.address(session),
    ]);
    await executeTransaction(runtime, "smoke_revoke_session", revoke);
}

async function ensureAccountFundsRecovered(runtime: Runtime, wrapper: string): Promise<void> {
    const smoke = runtime.state.smoke;
    const initialSui = BigInt(smokeValue(smoke, "initialSuiBalance", "initial SUI balance"));
    const initialDeep = BigInt(smokeValue(smoke, "initialDeepBalance", "initial DEEP balance"));
    const currentSui = await accountBalance(runtime, wrapper, SUI_TYPE);
    const currentDeep = await accountBalance(runtime, wrapper, DEEP_TYPE);
    if (currentSui < initialSui || currentDeep < initialDeep) {
        throw new Error("smoke Account balance fell below its journaled baseline");
    }
    const suiDelta = currentSui - initialSui;
    const deepDelta = currentDeep - initialDeep;
    const funding = BigInt(smokeValue(smoke, "fundingAmount", "smoke funding"));
    const executed = BigInt(smoke.marketExecutedQuantity ?? "0");
    if (suiDelta > funding || deepDelta > executed) {
        throw new Error("Account cleanup delta exceeds journaled smoke attribution");
    }
    if (suiDelta === 0n && deepDelta === 0n) {
        smoke.accountFundsRecovered = true;
        writeState(runtime.state);
        return;
    }
    const tx = new Transaction();
    const recovered = [];
    if (suiDelta > 0n) {
        const auth = call(tx, `${ACCOUNT}::account::generate_auth`, []);
        recovered.push(
            call(
                tx,
                `${ACCOUNT}::account::withdraw_funds`,
                [
                    tx.object(wrapper),
                    auth,
                    tx.pure.u64(suiDelta),
                    tx.object(ACCUMULATOR_ROOT),
                    tx.object(CLOCK),
                ],
                [SUI_TYPE],
            ),
        );
    }
    if (deepDelta > 0n) {
        const auth = call(tx, `${ACCOUNT}::account::generate_auth`, []);
        recovered.push(
            call(
                tx,
                `${ACCOUNT}::account::withdraw_funds`,
                [
                    tx.object(wrapper),
                    auth,
                    tx.pure.u64(deepDelta),
                    tx.object(ACCUMULATOR_ROOT),
                    tx.object(CLOCK),
                ],
                [DEEP_TYPE],
            ),
        );
    }
    tx.transferObjects(recovered, tx.pure.address(DEPLOYER));
    await executeTransaction(runtime, "smoke_recover_account_funds", tx);
}

async function ensureSessionGasReturned(
    runtime: Runtime,
    sessionSigner: Ed25519Keypair,
): Promise<void> {
    const session = smokeValue(runtime.state.smoke, "sessionAddress", "smoke session");
    const balance = await runtime.client.getBalance({ owner: session });
    if (BigInt(balance.balance.balance) === 0n) {
        runtime.state.smoke.sessionGasReturned = true;
        writeState(runtime.state);
        return;
    }
    if (BigInt(balance.balance.balance) < SESSION_TRANSACTION_GAS_BUDGET) {
        throw new Error("temporary session balance is below its return transaction gas budget");
    }
    const returnGas = new Transaction();
    returnGas.transferObjects([returnGas.gas], returnGas.pure.address(DEPLOYER));
    await executeTransaction(
        runtime,
        "smoke_return_session_gas",
        returnGas,
        sessionSigner,
        SESSION_TRANSACTION_GAS_BUDGET,
    );
}

async function cleanupSmokeAttempt(
    runtime: Runtime,
    wrapper: string,
    sessionSigner: Ed25519Keypair,
): Promise<void> {
    const smoke = runtime.state.smoke;
    const openOrders = await openOrderCount(runtime, wrapper);
    if (openOrders > 0n) {
        await cleanupOwnerOrder(
            runtime,
            wrapper,
            BigInt(smokeValue(smoke, "limitOrderId", "limit order ID")),
        );
    }
    await ensureSessionRevoked(runtime, wrapper);
    await ensureAccountFundsRecovered(runtime, wrapper);
    await ensureSessionGasReturned(runtime, sessionSigner);
}

function restartSmokeAttempt(runtime: Runtime): void {
    const previous = runtime.state.smoke;
    for (const [label, digest] of Object.entries(previous.transactions)) {
        runtime.state.transactions[`smoke_attempt_${previous.attempt}_${label}`] = digest;
        delete runtime.state.transactions[label];
    }
    runtime.state.smoke = createSpotSmoke(previous.attempt + 1);
    runtime.state.lastError = null;
    writeState(runtime.state);
}

async function runSmoke(runtime: Runtime): Promise<void> {
    const packageId = requiredString(runtime.state.packageId, "Sessions v2 package");
    const wrapper = await accountWrapper(runtime);
    const sessionSigner = smokeSessionSigner(runtime);
    const session = normalizeId(sessionSigner.getPublicKey().toSuiAddress());
    const smoke = runtime.state.smoke;
    if (smoke.status === "not_started") {
        const book = await poolParameters(runtime);
        if (book.minSize % book.lotSize !== 0n) throw new Error("pool min size is not lot aligned");
        const marketPriceLimit = book.bestAsk + book.bestAsk / 4n + book.tickSize;
        const maxQuoteAtLimit = (book.minSize * marketPriceLimit + PRICE_SCALE - 1n) / PRICE_SCALE;
        const maxFeeAtLimit = (maxQuoteAtLimit * MAX_TAKER_FEE + PRICE_SCALE - 1n) / PRICE_SCALE;
        const fundingAmount = maxQuoteAtLimit + maxFeeAtLimit + SMOKE_BUFFER;
        if (fundingAmount > MAX_SPOT_PRINCIPAL) {
            throw new Error(
                `worst-case market cost ${fundingAmount} exceeds smoke principal bound`,
            );
        }
        if (book.quoteRequired > maxQuoteAtLimit) {
            throw new Error("live market quote exceeds its journaled price-limit bound");
        }
        if ((await openOrderCount(runtime, wrapper)) !== 0n) {
            throw new Error("smoke Account already has live DEEP/SUI orders");
        }
        const passivePrice =
            book.bestBid && book.bestBid + book.tickSize < book.bestAsk
                ? book.bestBid + book.tickSize
                : book.bestAsk - book.tickSize;
        if (passivePrice <= 0n || passivePrice >= book.bestAsk) {
            throw new Error("cannot derive a non-crossing DEEP/SUI bid");
        }
        const limitClientId = BigInt(Date.now());
        runtime.state.status = "smoke";
        Object.assign(smoke, {
            status: "running",
            wrapperId: wrapper,
            sessionAddress: session,
            quantity: book.minSize.toString(),
            fundingAmount: fundingAmount.toString(),
            initialSuiBalance: (await accountBalance(runtime, wrapper, SUI_TYPE)).toString(),
            initialDeepBalance: (await accountBalance(runtime, wrapper, DEEP_TYPE)).toString(),
            limitClientId: limitClientId.toString(),
            marketClientId: (limitClientId + 1n).toString(),
            limitPrice: passivePrice.toString(),
            marketPriceLimit: marketPriceLimit.toString(),
            lastError: null,
        });
        writeState(runtime.state);
    } else if (
        normalizeId(smokeValue(smoke, "wrapperId", "smoke wrapper")) !== wrapper ||
        normalizeId(smokeValue(smoke, "sessionAddress", "smoke session")) !== session
    ) {
        throw new Error("resumed smoke wrapper or deterministic session does not match journal");
    }

    try {
        if (!smoke.transactions.smoke_authorize_and_fund) {
            const setup = new Transaction();
            const [accountFunding, sessionGas] = setup.splitCoins(setup.gas, [
                setup.pure.u64(BigInt(smokeValue(smoke, "fundingAmount", "smoke funding"))),
                setup.pure.u64(SESSION_GAS),
            ]);
            const ownerAuth = call(setup, `${ACCOUNT}::account::generate_auth`, []);
            call(
                setup,
                `${ACCOUNT}::account::deposit_funds`,
                [
                    setup.object(wrapper),
                    ownerAuth,
                    accountFunding,
                    setup.object(ACCUMULATOR_ROOT),
                    setup.object(CLOCK),
                ],
                [SUI_TYPE],
            );
            setup.transferObjects([sessionGas], setup.pure.address(session));
            call(setup, `${packageId}::sessions::authorize_session`, [
                setup.object(wrapper),
                setup.pure.address(session),
                setup.pure.u64(SESSION_DURATION_MS),
                setup.object(CLOCK),
            ]);
            await executeTransaction(runtime, "smoke_authorize_and_fund", setup);
        } else {
            const marketCheckpointed = Boolean(smoke.transactions.smoke_session_market_fill);
            const expiration = await sessionExpiration(runtime, wrapper, session);
            const nowMs = await clockTimestamp(runtime);
            try {
                assertSmokeSessionResume(
                    smoke.sessionRevoked,
                    marketCheckpointed,
                    expiration,
                    nowMs,
                );
            } catch (error) {
                const expired =
                    !marketCheckpointed &&
                    !smoke.sessionRevoked &&
                    expiration !== null &&
                    expiration <= nowMs;
                if (!expired) throw error;
                await cleanupSmokeAttempt(runtime, wrapper, sessionSigner);
                restartSmokeAttempt(runtime);
                return runSmoke(runtime);
            }
        }

        if (!smoke.transactions.smoke_session_limit_place) {
            const limit = new Transaction();
            call(
                limit,
                `${packageId}::sessions::place_limit_order`,
                [
                    limit.object(DEEP_SUI_POOL),
                    limit.object(DEEPBOOK_REGISTRY),
                    limit.object(ACCOUNT_REGISTRY),
                    limit.object(wrapper),
                    limit.pure.u64(
                        BigInt(smokeValue(smoke, "limitClientId", "limit client order ID")),
                    ),
                    limit.pure.u8(3),
                    limit.pure.u8(0),
                    limit.pure.u64(BigInt(smokeValue(smoke, "limitPrice", "limit price"))),
                    limit.pure.u64(BigInt(smokeValue(smoke, "quantity", "limit quantity"))),
                    limit.pure.bool(true),
                    limit.pure.bool(false),
                    limit.pure.u64(0n),
                    limit.object(ACCUMULATOR_ROOT),
                    limit.object(CLOCK),
                ],
                [DEEP_TYPE, SUI_TYPE],
            );
            await executeTransaction(
                runtime,
                "smoke_session_limit_place",
                limit,
                sessionSigner,
                SESSION_TRANSACTION_GAS_BUDGET,
            );
        }

        if (!smoke.transactions.smoke_session_limit_cancel) {
            const cancel = new Transaction();
            call(
                cancel,
                `${packageId}::sessions::cancel_live_order`,
                [
                    cancel.object(DEEP_SUI_POOL),
                    cancel.object(ACCOUNT_REGISTRY),
                    cancel.object(wrapper),
                    cancel.pure.u128(BigInt(smokeValue(smoke, "limitOrderId", "limit order ID"))),
                    cancel.object(CLOCK),
                ],
                [DEEP_TYPE, SUI_TYPE],
            );
            await executeTransaction(
                runtime,
                "smoke_session_limit_cancel",
                cancel,
                sessionSigner,
                SESSION_TRANSACTION_GAS_BUDGET,
            );
        }

        if (!smoke.marketPreSuiBalance || !smoke.marketPreDeepBalance) {
            const marketPreSui = await accountBalance(runtime, wrapper, SUI_TYPE);
            const marketPreDeep = await accountBalance(runtime, wrapper, DEEP_TYPE);
            if (
                marketPreSui !==
                    BigInt(smokeValue(smoke, "initialSuiBalance", "initial SUI balance")) +
                        BigInt(smokeValue(smoke, "fundingAmount", "smoke funding")) ||
                marketPreDeep !==
                    BigInt(smokeValue(smoke, "initialDeepBalance", "initial DEEP balance"))
            ) {
                throw new Error("pre-market Account balances exceed the smoke funding boundary");
            }
            smoke.marketPreSuiBalance = marketPreSui.toString();
            smoke.marketPreDeepBalance = marketPreDeep.toString();
            writeState(runtime.state);
        }

        if (!smoke.transactions.smoke_session_market_fill) {
            const market = new Transaction();
            call(
                market,
                `${packageId}::sessions::place_market_order`,
                [
                    market.object(DEEP_SUI_POOL),
                    market.object(DEEPBOOK_REGISTRY),
                    market.object(ACCOUNT_REGISTRY),
                    market.object(wrapper),
                    market.pure.u64(
                        BigInt(smokeValue(smoke, "marketClientId", "market client order ID")),
                    ),
                    market.pure.u8(0),
                    market.pure.u64(BigInt(smokeValue(smoke, "quantity", "market quantity"))),
                    market.pure.u64(
                        BigInt(smokeValue(smoke, "marketPriceLimit", "market price limit")),
                    ),
                    market.pure.bool(true),
                    market.pure.bool(false),
                    market.object(ACCUMULATOR_ROOT),
                    market.object(CLOCK),
                ],
                [DEEP_TYPE, SUI_TYPE],
            );
            await executeTransaction(
                runtime,
                "smoke_session_market_fill",
                market,
                sessionSigner,
                SESSION_TRANSACTION_GAS_BUDGET,
            );
        }
        await cleanupSmokeAttempt(runtime, wrapper, sessionSigner);
        if (smoke.marketFillExact !== true) {
            throw new Error("market smoke applied a non-exact IOC result; cleanup completed");
        }
    } catch (error) {
        if (
            error instanceof KnownTransactionFailure &&
            canRetrySessionTransaction(runtime.state, error.label)
        ) {
            smoke.status = "running";
            smoke.lastError = error.message;
            writeState(runtime.state);
            return runSmoke(runtime);
        }
        let cleanupError: unknown;
        if (
            !runtime.state.inFlight &&
            Boolean(smoke.transactions.smoke_authorize_and_fund) &&
            (!smoke.accountFundsRecovered || !smoke.sessionRevoked || !smoke.sessionGasReturned)
        ) {
            try {
                await cleanupSmokeAttempt(runtime, wrapper, sessionSigner);
            } catch (failure) {
                cleanupError = failure;
            }
        }
        smoke.status = "failed";
        const primary = error instanceof Error ? error.message : String(error);
        smoke.lastError = cleanupError
            ? `${primary}; cleanup also failed: ${String(cleanupError)}`
            : primary;
        writeState(runtime.state);
        if (cleanupError) throw new Error(smoke.lastError, { cause: error });
        throw error;
    }
    if (
        !smoke.marketExecutedQuantity ||
        !smoke.marketQuoteQuantity ||
        smoke.marketFillExact !== true ||
        !smoke.accountFundsRecovered ||
        !smoke.sessionRevoked ||
        !smoke.sessionGasReturned
    ) {
        throw new Error("live spot smoke did not reach its audited completion state");
    }
    smoke.status = "complete";
    smoke.lastError = null;
    writeState(runtime.state);
}

function assertCleanSource(): void {
    const unexpected = unexpectedUpgradeSourcePaths(
        git(["status", "--porcelain=v1", "--untracked-files=all"]),
    );
    if (unexpected.length)
        throw new Error(`upgrade source has unexpected dirt: ${unexpected.join(", ")}`);
}

export function requiredDeployerBalance(state: SessionsUpgradeState): bigint {
    if (state.status === "complete" && state.smoke.status === "complete") return 0n;
    const inFlight = state.inFlight?.label;
    let required = 0n;
    if (!state.packageId && inFlight !== "upgrade_sessions_v2") {
        required += BigInt(PACKAGE_GAS_BUDGET);
    }
    if (state.smoke.status === "complete") return required;

    const smoke = state.smoke;
    const checkpointedOrInFlight = (label: string): boolean =>
        Boolean(smoke.transactions[label]) || inFlight === label;
    if (!checkpointedOrInFlight("smoke_authorize_and_fund")) {
        required += TRANSACTION_GAS_BUDGET + MAX_SPOT_PRINCIPAL + SESSION_GAS;
    }
    if (
        !checkpointedOrInFlight("smoke_session_limit_cancel") &&
        !checkpointedOrInFlight("smoke_owner_cancel_cleanup")
    ) {
        required += TRANSACTION_GAS_BUDGET;
    }
    if (!smoke.sessionRevoked && !checkpointedOrInFlight("smoke_revoke_session")) {
        required += TRANSACTION_GAS_BUDGET;
    }
    if (!smoke.accountFundsRecovered && !checkpointedOrInFlight("smoke_recover_account_funds")) {
        required += TRANSACTION_GAS_BUDGET;
    }
    return required;
}

function acquireLock(): { path: string; token: string } {
    const raw = git(["rev-parse", "--git-common-dir"]);
    const common = isAbsolute(raw) ? raw : resolve(REPO_ROOT, raw);
    const path = resolve(common, "predict-testnet-deployment.lock");
    const token = randomUUID();
    const fd = openSync(path, "wx", 0o600);
    writeFileSync(fd, `${JSON.stringify({ token, pid: process.pid, worktree: REPO_ROOT })}\n`);
    closeSync(fd);
    return { path, token };
}

function releaseLock(lock: { path: string; token: string }): void {
    if (!existsSync(lock.path)) return;
    const current = JSON.parse(readFileSync(lock.path, "utf8")) as { token?: string };
    if (current.token !== lock.token) throw new Error("deployment lock token changed");
    rmSync(lock.path);
}

async function preflight(snapshot: ClientSnapshot, state: SessionsUpgradeState): Promise<Runtime> {
    assertCleanSource();
    const sourceCommit = git(["rev-parse", "HEAD"]);
    const suiVersion = command(SUI, ["--version"]);
    const rpcUrlHash = createHash("sha256").update(snapshot.rpcUrl).digest("hex");
    assertObservedPreflightBindings(state, {
        sourceCommit,
        suiVersion,
        rpcUrlHash,
        network: suiClient(snapshot, ["active-env"]),
        chainId: suiClient(snapshot, ["chain-identifier"]),
        deployer: suiClient(snapshot, ["active-address"]),
    });
    const client = new SuiGrpcClient({ baseUrl: snapshot.rpcUrl, network: NETWORK });
    if ((await shortChainId(client)) !== CHAIN_ID) throw new Error("SDK RPC chain mismatch");
    const signer = signerFromKeystore(snapshot.keystorePath);
    compiledDependencies();
    const balance = await client.getBalance({ owner: DEPLOYER });
    const available = BigInt(balance.balance.balance);
    const required = requiredDeployerBalance(state);
    if (available < required) {
        throw new Error(
            `insufficient deployer SUI: have ${available}, require at least ${required} for upgrade and smoke bounds`,
        );
    }
    const manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8")) as unknown;
    assertIntegrationManifest(manifest);
    if (manifest.schemaVersion !== 5 || manifest.packages.deepbookCoreAccount !== WRAPPER) {
        throw new Error("committed manifest does not bind the Sessions spot wrapper");
    }
    const manifestSessions = normalizeId(
        requiredString(manifest.packages.sessions, "manifest Sessions package"),
    );
    if (
        (!state.packageId && manifestSessions !== SESSIONS_V1) ||
        (state.packageId &&
            manifestSessions !== SESSIONS_V1 &&
            manifestSessions !== normalizeId(state.packageId))
    ) {
        throw new Error("committed manifest does not match the journaled Sessions package");
    }
    const oldPackage = readPackage(snapshot, SESSIONS_V1);
    const wrapperPackage = readPackage(snapshot, WRAPPER);
    const deepbookPackage = readPackage(snapshot, DEEPBOOK);
    const cap = readUpgradeCap(snapshot);
    const expectedV1Dependencies = [...EXPECTED_DEPENDENCIES]
        .filter((id) => id !== WRAPPER && id !== DEEPBOOK)
        .sort();
    const expectedV1Linkages = new Map(EXPECTED_LINKAGES);
    expectedV1Linkages.delete(WRAPPER);
    expectedV1Linkages.delete(DEEPBOOK_ORIGINAL);
    if (
        oldPackage.version !== "1" ||
        JSON.stringify(oldPackage.dependencies) !== JSON.stringify(expectedV1Dependencies) ||
        wrapperPackage.id !== WRAPPER ||
        wrapperPackage.version !== "1" ||
        wrapperPackage.typeOrigins.some((origin) => origin.package !== WRAPPER) ||
        deepbookPackage.id !== DEEPBOOK ||
        deepbookPackage.version !== "20" ||
        !deepbookPackage.typeOrigins.some((origin) => origin.package === DEEPBOOK_ORIGINAL)
    ) {
        throw new Error("live Sessions v1, spot wrapper, or DeepBook dependency identity mismatch");
    }
    assertExactLinkages(oldPackage.linkages, expectedV1Linkages, "live Sessions v1");
    if (
        cap.packageId !== SESSIONS_V1 ||
        (state.packageId && normalizeId(state.packageId) === SESSIONS_V1)
    ) {
        throw new Error("live Sessions upgrade does not match its v2 journal checkpoint");
    }
    assertUpgradeCapResumeVersion(
        Boolean(state.packageId),
        state.inFlight?.label ?? null,
        cap.version,
    );
    return { state, snapshot, client, signer, sourceCommit };
}

export async function main(args = process.argv.slice(2)): Promise<void> {
    const mode = parseSessionsUpgradeArgs(args);
    const lock = acquireLock();
    let snapshot: ClientSnapshot | null = null;
    try {
        snapshot = snapshotClientConfig();
        const state = loadState();
        const runtime = await preflight(snapshot, state);
        const suiVersion = command(SUI, ["--version"]);
        console.log(`[sessions:v2] network: ${NETWORK} (${CHAIN_ID})`);
        console.log(`[sessions:v2] deployer: ${DEPLOYER}`);
        console.log(`[sessions:v2] source: ${runtime.sourceCommit}`);
        console.log(`[sessions:v2] package: ${SESSIONS_V1} -> version 2`);
        console.log(`[sessions:v2] wrapper: ${WRAPPER}`);
        console.log(`[sessions:v2] Sui CLI: ${suiVersion}`);
        if (!mode.execute) {
            serializedUpgrade(snapshot);
            console.log("[sessions:v2] preflight complete; no transactions submitted");
            return;
        }
        state.sourceCommit ??= runtime.sourceCommit;
        state.suiVersion ??= suiVersion;
        state.rpcUrlHash ??= createHash("sha256").update(snapshot.rpcUrl).digest("hex");
        state.startedAt ??= new Date().toISOString();
        state.lastError = null;
        writeState(state);
        try {
            await reconcileInFlight(runtime);
            await runUpgrade(runtime);
            if (mode.smoke && state.smoke.status !== "complete") await runSmoke(runtime);
            if (!mode.smoke && state.smoke.status !== "complete") {
                console.log(
                    "[sessions:v2] upgrade audited; rerun with --execute --smoke to finish",
                );
                return;
            }
            state.status = "complete";
            state.completedAt = new Date().toISOString();
            state.lastError = null;
            writeState(state);
            writePublished(state, suiVersion);
            writeManifest(
                buildSessionsUpgradeManifest(
                    JSON.parse(readFileSync(MANIFEST_PATH, "utf8")),
                    state,
                ),
            );
            console.log(`[sessions:v2] complete state: ${STATE_PATH}`);
            console.log(`[sessions:v2] deployment records updated`);
        } catch (error) {
            if (state.status !== "ambiguous") {
                state.status = state.upgradeTx ? "partial" : "failed";
                state.lastError = error instanceof Error ? error.message : String(error);
                writeState(state);
            }
            throw error;
        }
    } finally {
        if (snapshot) rmSync(snapshot.directory, { recursive: true, force: true });
        releaseLock(lock);
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch((error) => {
        console.error(error);
        process.exitCode = 1;
    });
}
