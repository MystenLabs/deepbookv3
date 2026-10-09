// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/**
 * Move an existing Predict deployment to version 4, the first rollout of the split order flow.
 *
 * On-chain steps, in order, with trading paused throughout:
 *   1. publish `deepbook_predict_math`;
 *   2. upgrade Predict with its UpgradeCap, linked to the library (logical version 4);
 *   3. publish `deepbook_predict_orders`, whose `init` shares the one OrderDesk;
 *   4. one admin transaction: allowlist the companion's `OrderFlow` witness, re-state the desk's
 *      launch order fee so `DelayedExecutionPolicyUpdated` records the policy and desk, and add
 *      the market keeper's signer as a flush operator unless it already is one;
 *   5. create the queue of every live market, skipping a queue that already exists;
 *   6. upgrade Sessions with its UpgradeCap, linked to Predict and the companion;
 *   7. (`--cutover`) bump Predict's version watermark to 4 and Sessions' to 3;
 *   8. (`--reopen`) unpause trading.
 *
 * The default invocation only checks the target and prints the plan:
 *   node --import tsx deployment/upgrade_v4.ts --network testnet --sender <address>
 * Localnet and Testnet sign with the active keystore address (`--execute`). Mainnet is never
 * signed here: `--emit-unsigned` writes the next transaction's unsigned bytes and a summary for
 * the multisig, and a later run records what landed before emitting the step after it.
 */
import { execFileSync } from "node:child_process";
import {
    chmodSync,
    closeSync,
    cpSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    openSync,
    readFileSync,
    realpathSync,
    renameSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import {
    Transaction,
    TransactionDataBuilder,
    type TransactionArgument,
} from "@mysten/sui/transactions";
import { fromBase58, fromBase64, toBase64, toHex } from "@mysten/sui/utils";
import {
    EXPECTED_ORDER_DESK,
    EXPECTED_SESSIONS_VERSION_WATERMARK,
    addressOwner,
    asRecord,
    assertNoKeystoreOverride,
    coreReceipt,
    decimalString,
    delayedExecutionPolicyRecord,
    effectsError,
    isObjectNotFound,
    marketQueueId,
    normalizeId,
    ownerLabel,
    parseIdVector,
    parsePackageMetadata,
    parseU64,
    requiredObjectId,
    requiredString,
    returnBytes,
    settledReceipt,
    sha256,
    stripYamlScalar,
    type PublishedPackageMetadata,
    type Receipt,
} from "./deploy.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..", "..");
const SUI = process.env.SUI_BINARY ?? "sui";
// CI's Move toolchain (`.github/workflows/move_test.yml`); the Testnet v4 and Mainnet v3
// publication records name the same release.
export const SUI_RELEASE = "1.80.1";
const PACKAGE_GAS_BUDGET = process.env.PACKAGE_GAS_BUDGET ?? "5000000000";
const TRANSACTION_GAS_BUDGET = process.env.TRANSACTION_GAS_BUDGET ?? "1000000000";
// The CLI only serializes the package transactions. The SDK rebuilds them from their
// programmable-transaction kind with the real budget and gas payment, so this budget only has
// to pass the CLI's own gas-coin selection and never reaches the chain.
const CLI_SERIALIZATION_GAS_BUDGET = "50000000";
const CLOCK_ID = "0x0000000000000000000000000000000000000000000000000000000000000006";
const OBJECT_ID = /^0x[0-9a-f]{64}$/;
// `queue::create_and_share` calls per transaction: one derived object each, far under Sui's
// per-transaction object and command limits.
export const QUEUE_BATCH = 50;
// Predict's `constants::current_version!()` after this upgrade: the cutover watermark.
export const PREDICT_CURRENT_VERSION = "4";
// Sessions' `session_config::current_version!()` after this upgrade.
export const SESSIONS_CURRENT_VERSION = EXPECTED_SESSIONS_VERSION_WATERMARK;

export type UpgradeNetwork = "localnet" | "testnet" | "mainnet";
export type UpgradePackage = "predict_math" | "predict" | "predict_orders" | "sessions";

interface NetworkProfile {
    chainId: string | null;
    buildEnv: string;
    // The package versions published today, which the UpgradeCaps must record.
    predictVersion: string;
    sessionsVersion: string;
}

// Testnet runs Predict package version 4 and Mainnet version 3; both run Sessions version 2.
// A localnet started from the v3 source publishes every package at version 1, and compiles the
// Testnet dependency graph with its addresses in an ephemeral publication file, as the harness
// does.
export const NETWORK_PROFILES: Record<UpgradeNetwork, NetworkProfile> = {
    localnet: { chainId: null, buildEnv: "testnet", predictVersion: "1", sessionsVersion: "1" },
    testnet: { chainId: "4c78adac", buildEnv: "testnet", predictVersion: "4", sessionsVersion: "2" },
    mainnet: { chainId: "35834a8a", buildEnv: "mainnet", predictVersion: "3", sessionsVersion: "2" },
};

export const UPGRADE_STEPS = [
    "publish_predict_math",
    "upgrade_predict",
    "publish_predict_orders",
    "enable_order_flow",
    "create_market_queues",
    "upgrade_sessions",
    "bump_version_watermarks",
    "unpause_trading",
] as const;
export type UpgradeStep = (typeof UPGRADE_STEPS)[number];

export interface UpgradeOptions {
    network: UpgradeNetwork;
    sender: string;
    // The market keeper's signer, which completes LP flushes: v4's `finish_flush` admits only
    // flush operators, and Predict before v4 has no such allowlist.
    flushOperator: string;
    mode: "preflight" | "execute" | "emit-unsigned";
    cutover: boolean;
    reopen: boolean;
    executed: Record<string, string>;
    adminCap: string | null;
    sessionsAdminCap: string | null;
    manifest: string;
    pubfile: string | null;
    workspace: string | null;
    state: string;
}

export interface InFlight {
    label: string;
    digest: string;
    startedAt: string;
}

export interface PackageRecord {
    packageId: string;
    originalId: string;
    version: string;
    upgradeCap: string;
    transaction: string;
}

interface CapPair {
    originalId: string;
    publishedAt: string;
    version: string;
    upgradeCap: string;
    adminCap: string;
}

export interface Baseline {
    predict: CapPair;
    sessions: CapPair;
    protocolConfig: string;
    poolVault: string;
    sessionsConfig: string;
    versionWatermark: string;
    sessionsVersionWatermark: string;
    checkedAt: string;
}

export interface QueueRecord {
    marketId: string;
    expiryMs: string;
    queueId: string;
    createTx: string | null;
}

export interface EmittedTransaction {
    digest: string;
    path: string;
    emittedAt: string;
}

interface Verification {
    verifiedAt: string;
    predictPackage: string;
    predictVersion: string;
    predictMathPackage: string;
    predictOrdersPackage: string;
    orderDesk: string;
    predictUpgradeCheckpoint: string;
    ordersPublishCheckpoint: string;
    flushOperator: string;
    sessionsPackage: string | null;
    sessionsVersion: string | null;
    orderFlowEnabled: boolean;
    liveMarketQueues: QueueRecord[];
    versionWatermark: string;
    sessionsVersionWatermark: string;
    tradingPaused: boolean;
}

export interface UpgradeJournal {
    schemaVersion: 1;
    workflow: "predict-v4-upgrade";
    network: UpgradeNetwork;
    chainId: string;
    buildEnvironment: string;
    sender: string;
    flushOperator: string;
    signing: "keystore" | "unsigned";
    status:
        | "pending"
        | "running"
        | "awaiting-execution"
        | "awaiting-cutover"
        | "awaiting-reopen"
        | "partial"
        | "ambiguous"
        | "complete";
    sourceCommit: string | null;
    bindings: ExecutionBindings | null;
    startedAt: string | null;
    updatedAt: string | null;
    completedAt: string | null;
    lastError: string | null;
    baseline: Baseline | null;
    packages: Partial<Record<UpgradePackage, PackageRecord>>;
    orderDesk: string | null;
    // The indexer's first checkpoint: the Predict upgrade's, so it records every v4 event.
    predictUpgradeCheckpoint: string | null;
    ordersPublishCheckpoint: string | null;
    transactions: Record<string, string>;
    failedTransactions: Record<string, { digest: string; error: string; recordedAt: string }>;
    inFlight: InFlight | null;
    emitted: Record<string, EmittedTransaction>;
    queues: QueueRecord[];
    verification: Verification | null;
}

export interface ExecutionBindings {
    suiVersion: string;
    suiBinaryPath: string;
    suiBinaryDigest: string;
    rpcUrl: string;
    clientConfigDigest: string;
    packageGasBudget: string;
    transactionGasBudget: string;
}

interface ClientSnapshot {
    directory: string;
    configPath: string;
    envAlias: string;
    rpcUrl: string;
    keystorePath: string;
    activeAddress: string;
    configDigest: string;
}

export interface Runtime {
    opts: UpgradeOptions;
    journal: UpgradeJournal;
    client: SuiGrpcClient;
    snapshot: ClientSnapshot;
    signer: Ed25519Keypair | null;
    toolchain: string;
    packageMetadataCache: Map<string, PublishedPackageMetadata>;
}

// A transaction was emitted for the multisig; the run stops until it lands.
export class AwaitingExecution extends Error {
    constructor(
        readonly label: string,
        readonly digest: string,
        readonly path: string,
    ) {
        super(`${label} is waiting for external execution of ${digest} (${path})`);
    }
}

class DryRunFailure extends Error {
    constructor(label: string, detail: string) {
        super(`${label} dry run failed: ${detail}`);
    }
}

// === Arguments ===

export function parseUpgradeArgs(args: readonly string[]): UpgradeOptions {
    let network: string | undefined;
    let sender: string | undefined;
    let flushOperator: string | undefined;
    let execute = false;
    let emit = false;
    let cutover = false;
    let reopen = false;
    const executed: Record<string, string> = {};
    let adminCap: string | null = null;
    let sessionsAdminCap: string | null = null;
    let manifest: string | null = null;
    let pubfile: string | null = null;
    let workspace: string | null = null;
    let state: string | null = null;
    const remaining = [...args];
    const value = (flag: string): string => {
        const next = remaining.shift();
        if (!next || next.startsWith("--")) throw new Error(`${flag} requires a value`);
        return next;
    };
    while (remaining.length) {
        const arg = remaining.shift()!;
        if (arg === "--network" && network === undefined) network = value(arg);
        else if (arg === "--sender" && sender === undefined) sender = value(arg);
        else if (arg === "--flush-operator" && flushOperator === undefined) flushOperator = value(arg);
        else if (arg === "--execute" && !execute) execute = true;
        else if (arg === "--emit-unsigned" && !emit) emit = true;
        else if (arg === "--cutover" && !cutover) cutover = true;
        else if (arg === "--reopen" && !reopen) reopen = true;
        else if (arg === "--admin-cap" && adminCap === null)
            adminCap = requiredObjectId(value(arg), "--admin-cap");
        else if (arg === "--sessions-admin-cap" && sessionsAdminCap === null)
            sessionsAdminCap = requiredObjectId(value(arg), "--sessions-admin-cap");
        else if (arg === "--manifest" && manifest === null) manifest = resolve(value(arg));
        else if (arg === "--pubfile" && pubfile === null) pubfile = resolve(value(arg));
        else if (arg === "--workspace" && workspace === null) workspace = resolve(value(arg));
        else if (arg === "--state" && state === null) state = resolve(value(arg));
        else if (arg === "--executed") {
            const [label, digest] = value(arg).split("=");
            if (!label || !digest || executed[label] || !/^[1-9A-HJ-NP-Za-km-z]{43,44}$/.test(digest))
                throw new Error("--executed takes <label>=<transaction digest>, once per label");
            executed[label] = digest;
        } else throw new Error(`unknown or repeated upgrade argument: ${arg}`);
    }
    if (network !== "localnet" && network !== "testnet" && network !== "mainnet")
        throw new Error("explicit --network localnet|testnet|mainnet is required");
    const expectedSender = requiredObjectId(sender, "explicit --sender address");
    if (BigInt(expectedSender) === 0n) throw new Error("--sender must be nonzero");
    const operator = requiredObjectId(flushOperator, "explicit --flush-operator (the market keeper's signer)");
    if (BigInt(operator) === 0n) throw new Error("--flush-operator must be nonzero");
    if (execute && emit) throw new Error("--execute and --emit-unsigned are exclusive");
    if (network === "mainnet" && execute)
        throw new Error("Mainnet is never signed here; use --emit-unsigned for the multisig");
    if ((cutover || reopen) && !execute && !emit)
        throw new Error("--cutover and --reopen need --execute or --emit-unsigned");
    if (Object.keys(executed).length > 0 && !emit)
        throw new Error("--executed records multisig execution and needs --emit-unsigned");
    const localPaths = [manifest, pubfile, workspace];
    if (network === "localnet") {
        if (localPaths.some((path) => path === null))
            throw new Error("localnet needs --manifest, --pubfile, and --workspace");
    } else if (localPaths.some((path) => path !== null)) {
        throw new Error(
            "--manifest, --pubfile, and --workspace are localnet-only; Testnet and Mainnet read the committed records",
        );
    }
    const defaultState =
        network === "localnet"
            ? resolve(dirname(pubfile!), "deployment.localnet.upgrade-v4.state.json")
            : resolve(HERE, `deployment.${network}.upgrade-v4.state.json`);
    return {
        network,
        sender: expectedSender,
        flushOperator: operator,
        mode: execute ? "execute" : emit ? "emit-unsigned" : "preflight",
        cutover,
        reopen,
        executed,
        adminCap,
        sessionsAdminCap,
        manifest: manifest ?? resolve(HERE, `deployment.${network}.json`),
        pubfile,
        workspace,
        state: state ?? defaultState,
    };
}

// === Journal ===

export function createUpgradeJournal(opts: UpgradeOptions, chainId: string): UpgradeJournal {
    return {
        schemaVersion: 1,
        workflow: "predict-v4-upgrade",
        network: opts.network,
        chainId,
        buildEnvironment: NETWORK_PROFILES[opts.network].buildEnv,
        sender: opts.sender,
        flushOperator: opts.flushOperator,
        signing: opts.network === "mainnet" || opts.mode === "emit-unsigned" ? "unsigned" : "keystore",
        status: "pending",
        sourceCommit: null,
        bindings: null,
        startedAt: null,
        updatedAt: null,
        completedAt: null,
        lastError: null,
        baseline: null,
        packages: {},
        orderDesk: null,
        predictUpgradeCheckpoint: null,
        ordersPublishCheckpoint: null,
        transactions: {},
        failedTransactions: {},
        inFlight: null,
        emitted: {},
        queues: [],
        verification: null,
    };
}

// The journal binds one network, chain, sender, and signing mode for the whole rollout. A
// preflight never fixes the signing mode, so an emit-only run may follow it.
export function assertJournalBinding(journal: UpgradeJournal, opts: UpgradeOptions, chainId: string): void {
    if (
        journal.schemaVersion !== 1 ||
        journal.workflow !== "predict-v4-upgrade" ||
        journal.network !== opts.network ||
        journal.chainId !== chainId ||
        journal.buildEnvironment !== NETWORK_PROFILES[opts.network].buildEnv ||
        normalizeId(journal.sender) !== opts.sender
    ) {
        throw new Error(
            `the upgrade journal is bound to ${journal.network}/${journal.chainId}/${journal.sender}, not ${opts.network}/${chainId}/${opts.sender}`,
        );
    }
    if (normalizeId(journal.flushOperator) !== opts.flushOperator)
        throw new Error(`the upgrade journal grants flush operator ${journal.flushOperator}, not ${opts.flushOperator}`);
    const signing = opts.network === "mainnet" || opts.mode === "emit-unsigned" ? "unsigned" : "keystore";
    if (opts.mode !== "preflight" && journal.startedAt && journal.signing !== signing) {
        throw new Error(`the upgrade journal signs with ${journal.signing}; this run asks for ${signing}`);
    }
}

export function assertExecutionBindings(recorded: ExecutionBindings, actual: ExecutionBindings): void {
    if (JSON.stringify(recorded) !== JSON.stringify(actual)) {
        throw new Error(
            `upgrade execution bindings changed: recorded=${JSON.stringify(recorded)} actual=${JSON.stringify(actual)}`,
        );
    }
}

function loadJournal(path: string): UpgradeJournal | null {
    return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as UpgradeJournal) : null;
}

function writeJournal(path: string, journal: UpgradeJournal): void {
    journal.updatedAt = new Date().toISOString();
    const temporary = `${path}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(journal, null, 4)}\n`, { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, path);
}

function persist(runtime: Runtime): void {
    writeJournal(runtime.opts.state, runtime.journal);
}

// === Publication records ===

interface PublicationRecord {
    chainId: string;
    publishedAt: string;
    originalId: string;
    version: string;
    upgradeCap: string;
}

function tomlField(section: string, field: string): string | null {
    const match = section.match(new RegExp(`^${field}\\s*=\\s*"?([^"\\n]+)"?\\s*$`, "m"));
    return match ? match[1].trim() : null;
}

function recordFromSection(section: string, chainId: string | null, label: string): PublicationRecord {
    const field = (name: string) => {
        const found = tomlField(section, name);
        if (!found) throw new Error(`${label} is missing '${name}'`);
        return found;
    };
    return {
        chainId: chainId ?? field("chain-id"),
        publishedAt: normalizeId(field("published-at")),
        originalId: normalizeId(field("original-id")),
        version: decimalString(field("version"), `${label} version`),
        upgradeCap: normalizeId(field("upgrade-capability")),
    };
}

function publishedSectionPattern(network: string): RegExp {
    return new RegExp(`\\[published\\.${network}\\]([\\s\\S]*?)(?=\\n\\[|$)`);
}

// `Published.toml`'s `[published.<network>]` section, or null when the package has none.
export function readPublishedRecord(text: string, network: string): PublicationRecord | null {
    const section = text.match(publishedSectionPattern(network))?.[1];
    return section ? recordFromSection(section, null, `[published.${network}]`) : null;
}

export function publishedSectionText(
    network: string,
    chainId: string,
    record: Omit<PublicationRecord, "chainId">,
    toolchain: string,
): string {
    return `[published.${network}]
chain-id = "${chainId}"
published-at = "${normalizeId(record.publishedAt)}"
original-id = "${normalizeId(record.originalId)}"
version = ${record.version}
toolchain-version = "${toolchain}"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${normalizeId(record.upgradeCap)}"
`;
}

// Replace this network's section and keep every other network's history.
export function mergePublishedSection(existing: string, network: string, section: string): string {
    const pattern = publishedSectionPattern(network);
    if (pattern.test(existing)) return `${existing.replace(pattern, section.trimEnd()).trimEnd()}\n`;
    const header = existing.trim()
        ? existing.trimEnd()
        : "# Generated by Move\n# This file contains metadata about published versions of this package in different environments\n# This file SHOULD be committed to source control";
    return `${header}\n\n${section.trimEnd()}\n`;
}

function pubfileBlocks(text: string): { header: string; blocks: string[] } {
    const parts = text.split(/^\[\[published\]\]\s*$/m);
    return { header: parts[0]!, blocks: parts.slice(1) };
}

function blockSource(block: string): string | null {
    return block.match(/^source\s*=\s*\{\s*local\s*=\s*"([^"]+)"\s*\}/m)?.[1] ?? null;
}

// The ephemeral publication file's entry for the package at `path`, or null.
export function readPubfileRecord(text: string, path: string): PublicationRecord | null {
    const block = pubfileBlocks(text).blocks.find((candidate) => blockSource(candidate) === path);
    const chainId = text.match(/^chain-id\s*=\s*"([^"]+)"/m)?.[1] ?? null;
    return block ? recordFromSection(block, chainId, `ephemeral record ${path}`) : null;
}

// Add or replace the ephemeral entry for `path`, in the CLI's own `[[published]]` layout.
export function mergePubfileRecord(
    text: string,
    path: string,
    record: Omit<PublicationRecord, "chainId">,
    toolchain: string,
): string {
    const block = `
source = { local = "${path}" }
published-at = "${normalizeId(record.publishedAt)}"
original-id = "${normalizeId(record.originalId)}"
version = ${record.version}
toolchain-version = "${toolchain}"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${normalizeId(record.upgradeCap)}"

`;
    const { header, blocks } = pubfileBlocks(text);
    const index = blocks.findIndex((candidate) => blockSource(candidate) === path);
    if (index >= 0) blocks[index] = block;
    else blocks.push(block);
    return `${header.trimEnd()}\n\n${blocks.map((entry) => `[[published]]${entry.trimEnd()}\n`).join("\n")}`;
}

function packageDirectory(runtime: Runtime, pkg: UpgradePackage): string {
    return runtime.opts.network === "localnet"
        ? resolve(runtime.opts.workspace!, "packages", pkg)
        : resolve(REPO_ROOT, "packages", pkg);
}

function readRecord(runtime: Runtime, pkg: UpgradePackage): PublicationRecord | null {
    if (runtime.opts.network === "localnet") {
        return readPubfileRecord(readFileSync(runtime.opts.pubfile!, "utf8"), packageDirectory(runtime, pkg));
    }
    const path = resolve(packageDirectory(runtime, pkg), "Published.toml");
    return existsSync(path) ? readPublishedRecord(readFileSync(path, "utf8"), runtime.opts.network) : null;
}

function writeRecord(runtime: Runtime, pkg: UpgradePackage, record: PackageRecord): void {
    const entry = {
        publishedAt: record.packageId,
        originalId: record.originalId,
        version: record.version,
        upgradeCap: record.upgradeCap,
    };
    const path =
        runtime.opts.network === "localnet"
            ? runtime.opts.pubfile!
            : resolve(packageDirectory(runtime, pkg), "Published.toml");
    const existing = existsSync(path) ? readFileSync(path, "utf8") : "";
    const next =
        runtime.opts.network === "localnet"
            ? mergePubfileRecord(existing, packageDirectory(runtime, pkg), entry, runtime.toolchain)
            : mergePublishedSection(
                  existing,
                  runtime.opts.network,
                  publishedSectionText(runtime.opts.network, runtime.journal.chainId, entry, runtime.toolchain),
              );
    const temporary = `${path}.upgrade.tmp`;
    writeFileSync(temporary, next, { mode: 0o644 });
    renameSync(temporary, path);
    const written = readRecord(runtime, pkg);
    if (
        !written ||
        written.publishedAt !== record.packageId ||
        written.originalId !== record.originalId ||
        written.version !== record.version ||
        written.upgradeCap !== record.upgradeCap
    ) {
        throw new Error(`${pkg} publication record did not read back as ${JSON.stringify(record)}`);
    }
}

// === CLI ===

function command(executable: string, args: string[], cwd = REPO_ROOT): string {
    return execFileSync(executable, args, {
        cwd,
        encoding: "utf8",
        maxBuffer: 256 * 1024 * 1024,
        stdio: ["ignore", "pipe", "pipe"],
    }).trim();
}

function git(args: string[]): string {
    return command("git", args);
}

function suiClient(runtime: Runtime, args: string[]): string {
    return command(SUI, [
        "client",
        "--client.config",
        runtime.snapshot.configPath,
        "--client.env",
        runtime.snapshot.envAlias,
        ...args,
    ]);
}

export function assertSuiRelease(version: string): string {
    const match = version.match(/^sui (\d+\.\d+\.\d+)-\S+$/);
    if (!match || match[1] !== SUI_RELEASE) {
        throw new Error(`Sui CLI must be release ${SUI_RELEASE}, got '${version}'`);
    }
    return match[1];
}

function suiBinaryIdentity(): { path: string; digest: string } {
    const path = realpathSync(isAbsolute(SUI) ? SUI : command("which", [SUI]));
    return { path, digest: sha256(readFileSync(path)) };
}

function snapshotClientConfig(opts: UpgradeOptions): ClientSnapshot {
    const source = process.env.SUI_CLIENT_CONFIG ?? resolve(homedir(), ".sui", "sui_config", "client.yaml");
    if (!existsSync(source)) throw new Error(`Sui client config does not exist: ${source}`);
    const yaml = readFileSync(source, "utf8");
    const activeAddress = yaml.match(/^active_address:\s*(.+)$/m)?.[1];
    if (!activeAddress) throw new Error("Sui client config has no active address");
    const envAlias = opts.network;
    const environmentBlock = yaml.match(
        new RegExp(`^\\s*- alias:\\s*${envAlias}\\s*$([\\s\\S]*?)(?=^\\s*- alias:|^active_env:)`, "m"),
    )?.[1];
    const rpc = environmentBlock?.match(/^\s*rpc:\s*(.+)$/m)?.[1];
    if (!rpc) throw new Error(`Sui client config has no '${envAlias}' environment`);
    assertNoKeystoreOverride(process.env.SUI_KEYSTORE_PATH);
    const configuredKeystore = yaml.match(/keystore:\s*\n\s*File:\s*(.+)$/m)?.[1];
    const keystorePath = configuredKeystore
        ? stripYamlScalar(configuredKeystore)
        : resolve(homedir(), ".sui", "sui_config", "sui.keystore");
    const directory = mkdtempSync(join(tmpdir(), `predict-${opts.network}-upgrade-`));
    const configPath = resolve(directory, "client.yaml");
    // Select only in the private snapshot; leave the operator's active environment untouched.
    const snapshotYaml = yaml.replace(/^active_env:.*$/m, `active_env: ${envAlias}`);
    writeFileSync(configPath, snapshotYaml, { mode: 0o600 });
    return {
        directory,
        configPath,
        envAlias,
        rpcUrl: stripYamlScalar(rpc),
        keystorePath,
        activeAddress: normalizeId(stripYamlScalar(activeAddress)),
        configDigest: sha256(snapshotYaml),
    };
}

function keystoreSigner(keystorePath: string, address: string): Ed25519Keypair {
    if (!existsSync(keystorePath)) throw new Error(`Sui keystore does not exist: ${keystorePath}`);
    const entries = JSON.parse(readFileSync(keystorePath, "utf8")) as unknown;
    if (!Array.isArray(entries)) throw new Error(`invalid Sui keystore: ${keystorePath}`);
    for (const entry of entries) {
        if (typeof entry !== "string") continue;
        const raw = fromBase64(entry);
        if (raw.length !== 33 || raw[0] !== 0) continue;
        const signer = Ed25519Keypair.fromSecretKey(raw.slice(1));
        if (normalizeId(signer.getPublicKey().toSuiAddress()) === address) return signer;
    }
    throw new Error(`Ed25519 keypair for ${address} was not found in the configured keystore`);
}

// Testnet and Mainnet compile a staged copy of the committed sources, so the build leaves the
// worktree untouched and the CLI never rewrites a publication record. A localnet compiles in
// its disposable workspace, whose paths key the ephemeral publication file.
function withPackageSource<T>(runtime: Runtime, pkg: UpgradePackage, operation: (directory: string) => T): T {
    if (runtime.opts.network === "localnet") return operation(packageDirectory(runtime, pkg));
    const directory = mkdtempSync(join(tmpdir(), `predict-${runtime.opts.network}-upgrade-${pkg}-`));
    try {
        for (const root of ["packages", "vendor"]) {
            cpSync(resolve(REPO_ROOT, root), resolve(directory, root), {
                recursive: true,
                filter: (source) => !["build", "target", "node_modules"].includes(basename(source)),
            });
        }
        return operation(resolve(directory, "packages", pkg));
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
}

// The `TransactionKind` inside a serialized `TransactionData::V1`. The CLI's gas data and
// expiration are dropped: the SDK sets them for the transaction that is signed or emitted.
export function transactionKindFromData(data: Uint8Array): Uint8Array {
    if (data[0] !== 0) throw new Error(`unexpected TransactionData variant ${data[0]}`);
    return bcs.TransactionKind.serialize(bcs.TransactionKind.parse(data.slice(1))).toBytes();
}

export function unsignedBytesFromCliOutput(output: string): Uint8Array {
    const line = output
        .split("\n")
        .map((candidate) => candidate.trim())
        .filter((candidate) => /^[A-Za-z0-9+/]{64,}={0,2}$/.test(candidate))
        .at(-1);
    if (!line) throw new Error("the Sui CLI printed no serialized transaction");
    return fromBase64(line);
}

export interface PackagePlan {
    kind: "publish" | "upgrade";
    // The package being upgraded and the UpgradeCap that authorizes it.
    currentPackage?: string;
    upgradeCap?: string;
}

// The package transaction must be exactly what the step means: a publish whose UpgradeCap goes
// to the sender, or an upgrade of the recorded package through the recorded cap.
export function assertPackageProgram(tx: Transaction, plan: PackagePlan, sender: string): void {
    const data = tx.getData();
    const kinds = data.commands.map((entry) => entry.$kind);
    const pure = (argument: unknown): Uint8Array => {
        const index = asRecord(argument).Input;
        const input = typeof index === "number" ? data.inputs[index] : undefined;
        if (!input?.Pure) throw new Error("expected a pure input");
        return fromBase64(input.Pure.bytes);
    };
    if (plan.kind === "publish") {
        if (JSON.stringify(kinds) !== JSON.stringify(["Publish", "TransferObjects"]))
            throw new Error(`publish transaction has commands ${kinds.join(", ")}`);
        const recipient = normalizeId(`0x${toHex(pure(data.commands[1]!.TransferObjects!.address))}`);
        if (recipient !== sender) throw new Error(`publish sends its UpgradeCap to ${recipient}, not ${sender}`);
        return;
    }
    if (JSON.stringify(kinds) !== JSON.stringify(["MoveCall", "Upgrade", "MoveCall"]))
        throw new Error(`upgrade transaction has commands ${kinds.join(", ")}`);
    const [authorize, upgrade, commit] = data.commands;
    const framework = normalizeId("0x2");
    if (
        normalizeId(authorize!.MoveCall!.package) !== framework ||
        authorize!.MoveCall!.module !== "package" ||
        authorize!.MoveCall!.function !== "authorize_upgrade" ||
        normalizeId(commit!.MoveCall!.package) !== framework ||
        commit!.MoveCall!.function !== "commit_upgrade"
    ) {
        throw new Error("upgrade transaction does not authorize and commit through 0x2::package");
    }
    const capInput = data.inputs[asRecord(authorize!.MoveCall!.arguments[0]).Input as number];
    const capId = capInput?.Object?.ImmOrOwnedObject?.objectId;
    if (!capId || normalizeId(capId) !== plan.upgradeCap)
        throw new Error(`upgrade authorizes cap ${capId}, expected ${plan.upgradeCap}`);
    if (normalizeId(upgrade!.Upgrade!.package) !== plan.currentPackage)
        throw new Error(`upgrade replaces ${upgrade!.Upgrade!.package}, expected ${plan.currentPackage}`);
}

// The CLI command and flags of one package transaction. Testnet and Mainnet build for the client
// environment they publish to (the CLI refuses `--build-env` there). A localnet compiles the Testnet
// graph with its addresses in the ephemeral publication file. Upgrades skip the CLI's local
// compatibility check: release 1.80.1 cannot read a chain past protocol version 137, and the dry
// run every transaction gets on the target chain runs the authoritative check anyway.
export function packageCommand(
    network: UpgradeNetwork,
    plan: PackagePlan,
    paths: { pubfile: string | null; directory: string; sender: string },
): string[] {
    const local = network === "localnet";
    return [
        local ? `test-${plan.kind}` : plan.kind,
        ...(local ? ["--pubfile-path", paths.pubfile!, "--build-env", NETWORK_PROFILES.localnet.buildEnv] : []),
        "--warnings-are-errors",
        "--force",
        ...(plan.kind === "upgrade" ? ["--upgrade-capability", plan.upgradeCap!, "--skip-verify-compatibility"] : []),
        "--sender",
        paths.sender,
        "--gas-budget",
        CLI_SERIALIZATION_GAS_BUDGET,
        "--serialize-unsigned-transaction",
        paths.directory,
    ];
}

function packageTransaction(runtime: Runtime, pkg: UpgradePackage, plan: PackagePlan): Transaction {
    const output = withPackageSource(runtime, pkg, (directory) =>
        suiClient(
            runtime,
            packageCommand(runtime.opts.network, plan, { pubfile: runtime.opts.pubfile, directory, sender: runtime.opts.sender }),
        ),
    );
    const tx = Transaction.fromKind(transactionKindFromData(unsignedBytesFromCliOutput(output)));
    assertPackageProgram(tx, plan, runtime.opts.sender);
    return tx;
}

function transactionCheckpoint(runtime: Runtime, digest: string): string {
    const response = asRecord(JSON.parse(suiClient(runtime, ["tx-block", digest, "--json"])));
    return decimalString(String(response.checkpoint), `transaction ${digest} checkpoint`);
}

function packageMetadata(runtime: Runtime, id: string): PublishedPackageMetadata {
    const cached = runtime.packageMetadataCache.get(id);
    if (cached) return cached;
    const metadata = parsePackageMetadata(JSON.parse(suiClient(runtime, ["object", id, "--json"])));
    runtime.packageMetadataCache.set(id, metadata);
    return metadata;
}

// === Chain reads ===

async function shortChainId(client: SuiGrpcClient): Promise<string> {
    const { chainIdentifier } = await client.core.getChainIdentifier();
    return toHex(fromBase58(chainIdentifier).slice(0, 4));
}

interface ObjectRead {
    type: string;
    owner: string;
    json: Record<string, unknown>;
}

async function readObject(runtime: Runtime, id: string): Promise<ObjectRead> {
    const { object } = await runtime.client.getObject({ objectId: normalizeId(id), include: { json: true } });
    return { type: object.type, owner: ownerLabel(object.owner), json: asRecord(object.json) };
}

async function objectExists(runtime: Runtime, id: string): Promise<boolean> {
    try {
        await runtime.client.getObject({ objectId: normalizeId(id) });
        return true;
    } catch (error) {
        if (isObjectNotFound(error)) return false;
        throw error;
    }
}

async function inspect(runtime: Runtime, label: string, tx: Transaction): Promise<unknown> {
    tx.setSender(runtime.opts.sender);
    const response = await runtime.client.simulateTransaction({
        transaction: tx,
        checksEnabled: false,
        include: { commandResults: true, effects: true },
    });
    const error = effectsError(coreReceipt(response).effects);
    if (error) throw new Error(`${label} simulation failed: ${error}`);
    return response;
}

function field(fields: Record<string, unknown>, name: string, label: string): string {
    const value = fields[name];
    if (typeof value !== "string" && typeof value !== "number" && typeof value !== "boolean")
        throw new Error(`${label}.${name} is missing`);
    return String(value);
}

// An UpgradeCap owned by the sender that authorizes `version` of `packageId`.
async function assertUpgradeCap(
    runtime: Runtime,
    capId: string,
    packageId: string,
    version: string,
    label: string,
): Promise<void> {
    const cap = await readObject(runtime, capId);
    if (![`0x2::package::UpgradeCap`, `${normalizeId("0x2")}::package::UpgradeCap`].includes(cap.type))
        throw new Error(`${label} UpgradeCap ${capId} has type ${cap.type}`);
    if (cap.owner !== runtime.opts.sender)
        throw new Error(`${label} UpgradeCap ${capId} is owned by ${cap.owner}, not ${runtime.opts.sender}`);
    const capPackage = normalizeId(field(cap.json, "package", `${label} UpgradeCap`));
    const capVersion = field(cap.json, "version", `${label} UpgradeCap`);
    if (capPackage !== packageId || capVersion !== version)
        throw new Error(
            `${label} UpgradeCap records ${capPackage} v${capVersion}, expected ${packageId} v${version}`,
        );
    if (field(cap.json, "policy", `${label} UpgradeCap`) !== "0")
        throw new Error(`${label} UpgradeCap no longer allows compatible upgrades`);
}

// The sender's one object of `type`, or the operator's explicit choice, checked for owner and type.
async function ownedCap(runtime: Runtime, type: string, explicit: string | null, label: string): Promise<string> {
    if (explicit) {
        const cap = await readObject(runtime, explicit);
        if (cap.type !== type || cap.owner !== runtime.opts.sender)
            throw new Error(`${label} ${explicit} is ${cap.type} owned by ${cap.owner}`);
        return explicit;
    }
    const found = await runtime.client.listOwnedObjects({ owner: runtime.opts.sender, type });
    if (found.objects.length !== 1 || found.hasNextPage)
        throw new Error(
            `${runtime.opts.sender} owns ${found.objects.length} ${label} objects; pass the one to use explicitly`,
        );
    return normalizeId(found.objects[0]!.objectId);
}

interface ProtocolState {
    versionWatermark: string;
    tradingPaused: boolean;
    frozen: boolean;
}

async function readProtocolState(runtime: Runtime, protocolConfig: string): Promise<ProtocolState> {
    const config = await readObject(runtime, protocolConfig);
    return {
        versionWatermark: field(config.json, "version_watermark", "ProtocolConfig"),
        tradingPaused: field(config.json, "trading_paused", "ProtocolConfig") === "true",
        frozen: field(config.json, "frozen", "ProtocolConfig") === "true",
    };
}

async function readSessionsWatermark(runtime: Runtime, sessionsConfig: string): Promise<string> {
    return field((await readObject(runtime, sessionsConfig)).json, "version_watermark", "SessionsConfig");
}

function predictPackage(journal: UpgradeJournal): string {
    return journal.packages.predict?.packageId ?? journal.baseline!.predict.publishedAt;
}

export interface LiveMarket {
    id: string;
    expiryMs: string;
}

// The pool's active markets that have not expired. Expired markets settle through the legacy
// path and never take queued orders, so they need no queue.
async function liveMarkets(runtime: Runtime): Promise<LiveMarket[]> {
    const pkg = predictPackage(runtime.journal);
    const list = new Transaction();
    list.moveCall({
        target: `${pkg}::plp::active_expiry_markets`,
        arguments: [list.object(runtime.journal.baseline!.poolVault)],
    });
    const ids = parseIdVector(returnBytes(await inspect(runtime, "active_expiry_markets", list)));
    if (ids.length === 0) return [];
    const read = new Transaction();
    read.moveCall({ target: "0x2::clock::timestamp_ms", arguments: [read.object(CLOCK_ID)] });
    for (const id of ids) {
        read.moveCall({ target: `${pkg}::expiry_market::expiry`, arguments: [read.object(id)] });
    }
    const response = await inspect(runtime, "market_expiries", read);
    const now = parseU64(returnBytes(response, 0));
    return ids
        .map((id, index) => ({ id, expiryMs: parseU64(returnBytes(response, index + 1)).toString() }))
        .filter((market) => BigInt(market.expiryMs) > now);
}

// === Transactions ===

export interface AdminIds {
    predictPackage: string;
    protocolConfig: string;
    adminCap: string;
}

// Allowlist the companion's `OrderFlow` witness, then re-state the desk's launch order fee: the
// desk's `init` emits no `DelayedExecutionPolicyUpdated`, so this call is what records the launch
// policy and the desk ID for the indexer. Both are idempotent. Then add the market keeper's
// signer as a flush operator, unless it already is one, since re-adding aborts.
export function enableOrderFlowTransaction(
    ids: AdminIds & { ordersPackage: string; orderDesk: string },
    launchOrderFee: string,
    flushOperator: string | null,
): Transaction {
    const tx = new Transaction();
    const config = tx.object(ids.protocolConfig);
    const adminCap = tx.object(ids.adminCap);
    tx.moveCall({
        target: `${ids.predictPackage}::protocol_config::set_order_flow`,
        typeArguments: [`${ids.ordersPackage}::order_flow::OrderFlow`],
        arguments: [config, adminCap, tx.pure.bool(true), tx.object(CLOCK_ID)],
    });
    tx.moveCall({
        target: `${ids.ordersPackage}::desk::set_order_fee`,
        arguments: [tx.object(ids.orderDesk), adminCap, config, tx.pure.u64(BigInt(launchOrderFee)), tx.object(CLOCK_ID)],
    });
    if (flushOperator) {
        tx.moveCall({
            target: `${ids.predictPackage}::protocol_config::add_flush_operator`,
            arguments: [config, adminCap, tx.pure.address(flushOperator), tx.object(CLOCK_ID)],
        });
    }
    return tx;
}

// `queue::create_and_share(desk, market)` for each market. Each market is read by reference, so
// several queues fit one transaction.
export function marketQueuesTransaction(
    ids: { ordersPackage: string; orderDesk: string },
    marketIds: readonly string[],
): Transaction {
    if (marketIds.length === 0 || marketIds.length > QUEUE_BATCH)
        throw new Error(`a queue transaction creates 1 to ${QUEUE_BATCH} queues, got ${marketIds.length}`);
    const tx = new Transaction();
    const desk = tx.object(ids.orderDesk);
    for (const market of marketIds) {
        tx.moveCall({ target: `${ids.ordersPackage}::queue::create_and_share`, arguments: [desk, tx.object(market)] });
    }
    return tx;
}

// The cutover: Predict's floor to its `current_version!()` (4) and Sessions' to its own (3). A
// floor already there is left out, since a bump that does not advance aborts.
export function bumpWatermarksTransaction(
    ids: AdminIds & { sessionsPackage: string; sessionsConfig: string; sessionsAdminCap: string },
    bump: { predict: boolean; sessions: boolean },
): Transaction {
    if (!bump.predict && !bump.sessions) throw new Error("no watermark to bump");
    const tx = new Transaction();
    if (bump.predict) {
        tx.moveCall({
            target: `${ids.predictPackage}::protocol_config::bump_version_watermark`,
            arguments: [tx.object(ids.protocolConfig), tx.object(ids.adminCap)],
        });
    }
    if (bump.sessions) {
        tx.moveCall({
            target: `${ids.sessionsPackage}::session_config::bump_version_watermark`,
            arguments: [tx.object(ids.sessionsConfig), tx.object(ids.sessionsAdminCap)],
        });
    }
    return tx;
}

export function unpauseTransaction(ids: AdminIds): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: `${ids.predictPackage}::protocol_config::set_trading_paused`,
        arguments: [tx.object(ids.protocolConfig), tx.object(ids.adminCap), tx.pure.bool(false)],
    });
    return tx;
}

// The `enable_order_flow` receipt must allowlist this companion's witness and record the launch
// policy under this desk.
export function assertOrderFlowReceipt(
    receipt: Receipt,
    ids: { ordersPackage: string; orderDesk: string },
): void {
    const witness = `${ids.ordersPackage.slice(2)}::order_flow::OrderFlow`;
    const allowlisted = (receipt.events ?? []).find((event) => {
        const json = asRecord(event.parsedJson);
        const name = asRecord(json.order_flow).name ?? json.order_flow;
        return (
            typeof event.type === "string" &&
            event.type.endsWith("::config_events::OrderFlowUpdated") &&
            json.enabled === true &&
            typeof name === "string" &&
            name.replace(/^0x/, "") === witness
        );
    });
    if (!allowlisted) throw new Error("enable_order_flow emitted no enabling OrderFlowUpdated for the companion");
    const updates = (receipt.events ?? []).filter(
        (event) => event.type === `${ids.ordersPackage}::queue_events::DelayedExecutionPolicyUpdated`,
    );
    if (updates.length !== 1)
        throw new Error(`enable_order_flow emitted ${updates.length} DelayedExecutionPolicyUpdated events, expected 1`);
    const event = asRecord(updates[0]!.parsedJson);
    if (normalizeId(String(event.desk_id)) !== ids.orderDesk)
        throw new Error(`DelayedExecutionPolicyUpdated names desk ${String(event.desk_id)}, expected ${ids.orderDesk}`);
    if (JSON.stringify(delayedExecutionPolicyRecord(event.policy)) !== JSON.stringify(EXPECTED_ORDER_DESK.policy))
        throw new Error(`DelayedExecutionPolicyUpdated records an unexpected policy: ${JSON.stringify(event.policy)}`);
}

// === Submission ===

// A program with each argument resolved to its input value and each object input reduced to its
// ID, so a transaction rebuilt elsewhere (other gas, other object versions, other input order)
// compares equal to the one emitted when it does the same thing.
export function normalizedProgram(data: { inputs: unknown[]; commands: unknown[] }): string {
    const inputValue = (input: unknown): unknown => {
        const record = asRecord(input);
        if (record.Pure) return { pure: asRecord(record.Pure).bytes };
        const object = asRecord(record.Object);
        const ref = asRecord(object.ImmOrOwnedObject ?? object.SharedObject ?? object.Receiving);
        if (typeof ref.objectId === "string") return { object: normalizeId(ref.objectId) };
        throw new Error(`unsupported transaction input ${JSON.stringify(input)}`);
    };
    const resolveValue = (value: unknown): unknown => {
        if (Array.isArray(value)) return value.map(resolveValue);
        if (typeof value !== "object" || value === null) return value;
        const record = value as Record<string, unknown>;
        if (typeof record.Input === "number" && Object.keys(record).filter((key) => key !== "$kind" && key !== "type").length === 1)
            return inputValue(data.inputs[record.Input]);
        return Object.fromEntries(
            Object.entries(record)
                .filter(([key]) => key !== "$kind" && key !== "type")
                .sort(([left], [right]) => left.localeCompare(right))
                .map(([key, entry]) => [key, key === "package" && typeof entry === "string" ? normalizeId(entry) : resolveValue(entry)]),
        );
    };
    return JSON.stringify(data.commands.map(resolveValue));
}

async function gasPayment(runtime: Runtime, tx: Transaction, budget: bigint): Promise<void> {
    const { balance } = await runtime.client.getBalance({ owner: runtime.opts.sender });
    // Let the SDK select gas coins when they cover the budget; otherwise pay from the address
    // balance, as the Testnet signer and Mainnet's deployment do.
    if (BigInt(balance.coinBalance) >= budget) return;
    if (BigInt(balance.addressBalance) >= budget) {
        tx.setGasPayment([]);
        return;
    }
    throw new Error(
        `${runtime.opts.sender} has ${balance.coinBalance} MIST in coins and ${balance.addressBalance} MIST in its address balance, below the ${budget} MIST budget`,
    );
}

interface DryRun {
    status: string;
    gasUsed: unknown;
}

async function dryRun(runtime: Runtime, label: string, bytes: Uint8Array): Promise<DryRun> {
    const response = await runtime.client.simulateTransaction({
        transaction: bytes,
        checksEnabled: true,
        include: { effects: true },
    });
    const effects = coreReceipt(response).effects;
    const error = effectsError(effects);
    if (error) throw new DryRunFailure(label, error);
    return { status: "success", gasUsed: asRecord(effects).gasUsed ?? null };
}

function describeCommand(data: ReturnType<Transaction["getData"]>, entry: unknown): string {
    const command = asRecord(entry);
    if (command.MoveCall) {
        const call = asRecord(command.MoveCall);
        const types = Array.isArray(call.typeArguments) && call.typeArguments.length ? `<${call.typeArguments.join(", ")}>` : "";
        return `${call.package}::${call.module}::${call.function}${types}`;
    }
    if (command.Publish) {
        const publish = asRecord(command.Publish);
        return `publish ${(publish.modules as unknown[]).length} modules, dependencies ${(publish.dependencies as string[]).join(", ")}`;
    }
    if (command.Upgrade) {
        const upgrade = asRecord(command.Upgrade);
        return `upgrade ${upgrade.package} with ${(upgrade.modules as unknown[]).length} modules, dependencies ${(upgrade.dependencies as string[]).join(", ")}`;
    }
    if (command.TransferObjects) return `transfer to the sender`;
    return Object.keys(command).filter((key) => key !== "$kind").join(",");
}

function emitTransaction(
    runtime: Runtime,
    label: string,
    bytes: Uint8Array,
    tx: Transaction,
    digest: string,
    simulated: DryRun,
): string {
    const directory = runtime.opts.state.replace(/\.state\.json$/, "");
    mkdirSync(directory, { recursive: true });
    const index = String(Object.keys(runtime.journal.emitted).length + 1).padStart(2, "0");
    const path = resolve(directory, `${index}-${label}.json`);
    const data = tx.getData();
    writeFileSync(
        path,
        `${JSON.stringify(
            {
                label,
                network: runtime.opts.network,
                chainId: runtime.journal.chainId,
                sender: runtime.opts.sender,
                digest,
                transactionBytes: toBase64(bytes),
                // Gas-independent: what a multisig builder wraps with its own gas data.
                transactionKindBytes: toBase64(transactionKindFromData(bytes)),
                gasBudget: data.gasData.budget?.toString() ?? null,
                commands: data.commands.map((entry) => describeCommand(data, entry)),
                program: JSON.parse(normalizedProgram(data)),
                dryRun: simulated,
                emittedAt: new Date().toISOString(),
            },
            null,
            4,
        )}\n`,
        { mode: 0o644 },
    );
    return path;
}

// Reconcile an emitted transaction: it landed as emitted, or the operator names the digest the
// multisig executed, which must run the same program from the same sender.
async function reconcileEmitted(runtime: Runtime, label: string): Promise<Receipt | null> {
    const emitted = runtime.journal.emitted[label]!;
    const digest = runtime.opts.executed[label] ?? emitted.digest;
    let receipt: Receipt;
    try {
        receipt = await settledReceipt(runtime.client, digest, 4);
    } catch {
        if (runtime.opts.executed[label]) throw new Error(`${label}/${digest} is not visible on ${runtime.opts.network}`);
        return null;
    }
    if (digest !== emitted.digest) {
        const response = await runtime.client.getTransaction({ digest, include: { transaction: true } });
        const executed = asRecord(asRecord(response).Transaction ?? asRecord(response).FailedTransaction);
        const transaction = asRecord(executed.transaction);
        if (normalizeId(String(transaction.sender)) !== runtime.opts.sender)
            throw new Error(`${label}/${digest} was sent by ${String(transaction.sender)}, not ${runtime.opts.sender}`);
        const file = JSON.parse(readFileSync(emitted.path, "utf8")) as { program: unknown };
        const program = normalizedProgram({
            inputs: transaction.inputs as unknown[],
            commands: transaction.commands as unknown[],
        });
        if (program !== JSON.stringify(file.program))
            throw new Error(`${label}/${digest} does not run the program emitted in ${emitted.path}`);
    }
    const failure = effectsError(receipt.effects);
    if (failure) {
        runtime.journal.failedTransactions[label] = { digest, error: failure, recordedAt: new Date().toISOString() };
        delete runtime.journal.emitted[label];
        persist(runtime);
        throw new Error(`${label}/${digest} failed: ${failure}; the step will be emitted again`);
    }
    runtime.journal.transactions[label] = digest;
    persist(runtime);
    console.log(`[upgrade] recorded ${label}: ${digest}`);
    return receipt;
}

async function reconcileInFlight(runtime: Runtime): Promise<void> {
    const inFlight = runtime.journal.inFlight;
    if (!inFlight) return;
    let receipt: Receipt;
    try {
        receipt = await settledReceipt(runtime.client, inFlight.digest, 4);
    } catch {
        throw new Error(
            `${inFlight.label}/${inFlight.digest} is not visible on ${runtime.opts.network}. Fail closed; do not retry with new transaction bytes`,
        );
    }
    const failure = effectsError(receipt.effects);
    if (failure) {
        runtime.journal.failedTransactions[inFlight.label] = {
            digest: inFlight.digest,
            error: failure,
            recordedAt: new Date().toISOString(),
        };
    } else {
        runtime.journal.transactions[inFlight.label] = inFlight.digest;
    }
    runtime.journal.inFlight = null;
    persist(runtime);
    console.log(`[upgrade] reconciled ${inFlight.label}: ${inFlight.digest}${failure ? ` (failed: ${failure})` : ""}`);
}

// Submit one journaled transaction, or return its recorded receipt. Execute mode persists the
// digest before signing, and an unanswered submission is ambiguous, never retried with new bytes.
// Emit mode writes the unsigned bytes and stops the run until they land.
export async function submit(
    runtime: Runtime,
    label: string,
    build: () => Transaction | Promise<Transaction>,
    budget: bigint,
): Promise<Receipt> {
    const recorded = runtime.journal.transactions[label];
    if (recorded) {
        const receipt = await settledReceipt(runtime.client, recorded);
        const failure = effectsError(receipt.effects);
        if (failure) throw new Error(`${label}/${recorded} was recorded but failed: ${failure}`);
        return receipt;
    }
    if (runtime.journal.emitted[label]) {
        const receipt = await reconcileEmitted(runtime, label);
        if (receipt) return receipt;
        const emitted = runtime.journal.emitted[label]!;
        throw new AwaitingExecution(label, emitted.digest, emitted.path);
    }
    if (runtime.journal.inFlight) throw new Error(`cannot start ${label}; ${runtime.journal.inFlight.label} is in flight`);
    if (runtime.opts.mode === "preflight") throw new Error(`${label} needs --execute or --emit-unsigned`);
    const tx = await build();
    tx.setSender(runtime.opts.sender);
    tx.setGasBudget(budget);
    await gasPayment(runtime, tx, budget);
    const bytes = await tx.build({ client: runtime.client });
    const digest = TransactionDataBuilder.getDigestFromBytes(bytes);
    const simulated = await dryRun(runtime, label, bytes);
    if (runtime.opts.mode === "emit-unsigned") {
        const path = emitTransaction(runtime, label, bytes, tx, digest, simulated);
        runtime.journal.emitted[label] = { digest, path, emittedAt: new Date().toISOString() };
        persist(runtime);
        throw new AwaitingExecution(label, digest, path);
    }
    runtime.journal.inFlight = { label, digest, startedAt: new Date().toISOString() };
    persist(runtime);
    let receipt: Receipt;
    try {
        const { signature } = await runtime.signer!.signTransaction(bytes);
        receipt = coreReceipt(
            await runtime.client.executeTransaction({
                transaction: bytes,
                signatures: [signature],
                include: { effects: true, events: true, objectTypes: true },
            }),
        );
    } catch (submitError) {
        try {
            receipt = await settledReceipt(runtime.client, digest, 8);
        } catch {
            throw new Error(`${label} submission is ambiguous at ${digest}: ${String(submitError)}`);
        }
    }
    if (receipt.digest !== digest) throw new Error(`${label} returned digest ${receipt.digest}, expected ${digest}`);
    const failure = effectsError(receipt.effects);
    if (failure) {
        runtime.journal.failedTransactions[label] = { digest, error: failure, recordedAt: new Date().toISOString() };
        runtime.journal.inFlight = null;
        persist(runtime);
        throw new Error(`${label} failed at ${digest}: ${failure}`);
    }
    receipt = await settledReceipt(runtime.client, digest);
    runtime.journal.transactions[label] = digest;
    runtime.journal.inFlight = null;
    persist(runtime);
    console.log(`[upgrade] ${label}: ${digest}`);
    return receipt;
}

// === Steps ===

function publishedPackageId(receipt: Receipt, label: string): string {
    const published = (receipt.objectChanges ?? []).filter((change) => change.type === "published");
    if (published.length !== 1 || !published[0]!.packageId)
        throw new Error(`${label} receipt does not create exactly one package`);
    return normalizeId(published[0]!.packageId);
}

function createdObjects(receipt: Receipt, typeSuffix: string): Array<{ id: string; owner: unknown }> {
    return (receipt.objectChanges ?? [])
        .filter(
            (change) =>
                change.type === "created" &&
                typeof change.objectType === "string" &&
                change.objectType.endsWith(typeSuffix) &&
                change.objectId,
        )
        .map((change) => ({ id: normalizeId(change.objectId!), owner: change.owner }));
}

// The linkage a published package must carry for each dependency this rollout changes.
function assertLinks(
    metadata: PublishedPackageMetadata,
    expected: Array<{ originalId: string; upgradedId: string; version: string }>,
    label: string,
): void {
    for (const link of expected) {
        const found = metadata.linkage.find((entry) => entry.originalId === link.originalId);
        if (!found || found.upgradedId !== link.upgradedId || found.upgradedVersion !== link.version) {
            throw new Error(
                `${label} links ${link.originalId} at ${found ? `${found.upgradedId} v${found.upgradedVersion}` : "nothing"}, expected ${link.upgradedId} v${link.version}`,
            );
        }
    }
}

function expectedLinks(runtime: Runtime, pkg: UpgradePackage): Array<{ originalId: string; upgradedId: string; version: string }> {
    const record = (name: UpgradePackage) => {
        const entry = runtime.journal.packages[name];
        if (!entry) throw new Error(`${pkg} needs ${name} first`);
        return { originalId: entry.originalId, upgradedId: entry.packageId, version: entry.version };
    };
    switch (pkg) {
        case "predict_math":
            return [];
        case "predict":
            return [record("predict_math")];
        case "predict_orders":
            return [record("predict_math"), record("predict")];
        case "sessions":
            return [record("predict"), record("predict_orders")];
    }
}

async function verifyPackageRecord(runtime: Runtime, pkg: UpgradePackage): Promise<void> {
    const record = runtime.journal.packages[pkg]!;
    const metadata = packageMetadata(runtime, record.packageId);
    if (metadata.packageVersion !== record.version)
        throw new Error(`${pkg} ${record.packageId} is package version ${metadata.packageVersion}, expected ${record.version}`);
    assertLinks(metadata, expectedLinks(runtime, pkg), pkg);
    await assertUpgradeCap(runtime, record.upgradeCap, record.packageId, record.version, pkg);
    const onDisk = readRecord(runtime, pkg);
    if (!onDisk || onDisk.publishedAt !== record.packageId || onDisk.version !== record.version)
        throw new Error(`${pkg} publication record does not name ${record.packageId} v${record.version}`);
}

async function ensurePublished(runtime: Runtime, pkg: "predict_math" | "predict_orders"): Promise<void> {
    const label = `publish_${pkg}`;
    const journal = runtime.journal;
    if (!journal.packages[pkg]) {
        if (!journal.transactions[label] && !journal.emitted[label] && readRecord(runtime, pkg))
            throw new Error(`${pkg} already has a ${runtime.opts.network} publication record the journal does not explain`);
        const receipt = await submit(
            runtime,
            label,
            () => packageTransaction(runtime, pkg, { kind: "publish" }),
            BigInt(PACKAGE_GAS_BUDGET),
        );
        const packageId = publishedPackageId(receipt, label);
        const caps = createdObjects(receipt, "::package::UpgradeCap").filter(
            (cap) => addressOwner(cap.owner) === runtime.opts.sender,
        );
        if (caps.length !== 1) throw new Error(`${label} created ${caps.length} UpgradeCaps for the sender`);
        if (pkg === "predict_orders") {
            const desks = createdObjects(receipt, `${packageId}::desk::OrderDesk`);
            if (desks.length !== 1 || !("Shared" in asRecord(desks[0]!.owner)))
                throw new Error(`${label} did not share exactly one OrderDesk`);
            journal.orderDesk = desks[0]!.id;
            journal.ordersPublishCheckpoint = transactionCheckpoint(runtime, receipt.digest!);
        }
        journal.packages[pkg] = {
            packageId,
            originalId: packageId,
            version: "1",
            upgradeCap: caps[0]!.id,
            transaction: receipt.digest!,
        };
        persist(runtime);
    }
    writeRecord(runtime, pkg, journal.packages[pkg]!);
    await verifyPackageRecord(runtime, pkg);
    if (pkg === "predict_orders") await readLaunchOrderFee(runtime);
}

async function ensureUpgraded(runtime: Runtime, pkg: "predict" | "sessions"): Promise<void> {
    const label = `upgrade_${pkg}`;
    const journal = runtime.journal;
    const base = journal.baseline![pkg];
    if (!journal.packages[pkg]) {
        const receipt = await submit(
            runtime,
            label,
            () => packageTransaction(runtime, pkg, { kind: "upgrade", currentPackage: base.publishedAt, upgradeCap: base.upgradeCap }),
            BigInt(PACKAGE_GAS_BUDGET),
        );
        journal.packages[pkg] = {
            packageId: publishedPackageId(receipt, label),
            originalId: base.originalId,
            version: String(BigInt(base.version) + 1n),
            upgradeCap: base.upgradeCap,
            transaction: receipt.digest!,
        };
        if (pkg === "predict") journal.predictUpgradeCheckpoint = transactionCheckpoint(runtime, receipt.digest!);
        persist(runtime);
    }
    writeRecord(runtime, pkg, journal.packages[pkg]!);
    await verifyPackageRecord(runtime, pkg);
}

// The desk as its `init` shared it: the launch policy and the companion's floor of 1.
async function readLaunchOrderFee(runtime: Runtime): Promise<string> {
    const journal = runtime.journal;
    const desk = await readObject(runtime, journal.orderDesk!);
    if (desk.type !== `${journal.packages.predict_orders!.packageId}::desk::OrderDesk` || desk.owner !== "shared")
        throw new Error(`OrderDesk ${journal.orderDesk} is ${desk.type} owned by ${desk.owner}`);
    const record = {
        versionWatermark: field(desk.json, "version_watermark", "OrderDesk"),
        policy: delayedExecutionPolicyRecord(desk.json.policy),
    };
    if (JSON.stringify(record) !== JSON.stringify(EXPECTED_ORDER_DESK))
        throw new Error(`OrderDesk policy or floor is not the launch value: ${JSON.stringify(record)}`);
    return record.policy.orderFee;
}

function adminIds(runtime: Runtime): AdminIds {
    const baseline = runtime.journal.baseline!;
    return { predictPackage: predictPackage(runtime.journal), protocolConfig: baseline.protocolConfig, adminCap: baseline.predict.adminCap };
}

async function isOrderFlowEnabled(runtime: Runtime): Promise<boolean> {
    const tx = new Transaction();
    tx.moveCall({
        target: `${predictPackage(runtime.journal)}::protocol_config::is_order_flow`,
        typeArguments: [`${runtime.journal.packages.predict_orders!.packageId}::order_flow::OrderFlow`],
        arguments: [tx.object(runtime.journal.baseline!.protocolConfig)],
    });
    return returnBytes(await inspect(runtime, "is_order_flow", tx))[0] === 1;
}

async function isFlushOperator(runtime: Runtime, operator: string): Promise<boolean> {
    const tx = new Transaction();
    tx.moveCall({
        target: `${predictPackage(runtime.journal)}::protocol_config::is_flush_operator`,
        arguments: [tx.object(runtime.journal.baseline!.protocolConfig), tx.pure.address(operator)],
    });
    return returnBytes(await inspect(runtime, "is_flush_operator", tx))[0] === 1;
}

async function ensureOrderFlow(runtime: Runtime): Promise<void> {
    const journal = runtime.journal;
    const ids = { ordersPackage: journal.packages.predict_orders!.packageId, orderDesk: journal.orderDesk! };
    const launchFee = await readLaunchOrderFee(runtime);
    const receipt = await submit(
        runtime,
        "enable_order_flow",
        async () =>
            enableOrderFlowTransaction(
                { ...adminIds(runtime), ...ids },
                launchFee,
                (await isFlushOperator(runtime, journal.flushOperator)) ? null : journal.flushOperator,
            ),
        BigInt(TRANSACTION_GAS_BUDGET),
    );
    assertOrderFlowReceipt(receipt, ids);
    if (!(await isOrderFlowEnabled(runtime))) throw new Error("the order-flow companion did not read back as allowlisted");
    if (!(await isFlushOperator(runtime, journal.flushOperator)))
        throw new Error(`flush operator ${journal.flushOperator} did not read back`);
}

export interface QueueOperations {
    liveMarkets: (runtime: Runtime) => Promise<LiveMarket[]>;
    objectExists: (runtime: Runtime, id: string) => Promise<boolean>;
    submit: typeof submit;
    persist: (runtime: Runtime) => void;
}

const queueOperations: QueueOperations = { liveMarkets, objectExists, submit, persist };

// Create the queue of every live market at the ID derived from the desk and the market. Creation
// is permissionless and claims that ID, so a queue that already exists, from an earlier run, the
// market keeper, or anyone else, is recorded rather than created again. Markets created while the
// rollout waits are picked up by the next run, and again before the cutover.
export async function ensureMarketQueues(runtime: Runtime, ops: QueueOperations = queueOperations): Promise<void> {
    const journal = runtime.journal;
    const ids = { ordersPackage: journal.packages.predict_orders!.packageId, orderDesk: journal.orderDesk! };
    const markets = await ops.liveMarkets(runtime);
    const missing: LiveMarket[] = [];
    for (const market of markets) {
        const queueId = marketQueueId(ids.orderDesk, market.id);
        if (!(await ops.objectExists(runtime, queueId))) missing.push(market);
        else if (!journal.queues.some((queue) => queue.marketId === market.id))
            journal.queues.push({ marketId: market.id, expiryMs: market.expiryMs, queueId, createTx: null });
    }
    ops.persist(runtime);
    for (let start = 0; start < missing.length; start += QUEUE_BATCH) {
        const batch = missing.slice(start, start + QUEUE_BATCH);
        let sequence = 0;
        while (journal.transactions[`create_market_queues_${sequence}`] || journal.emitted[`create_market_queues_${sequence}`])
            sequence++;
        const label = `create_market_queues_${sequence}`;
        const receipt = await ops.submit(
            runtime,
            label,
            () => marketQueuesTransaction(ids, batch.map((market) => market.id)),
            BigInt(TRANSACTION_GAS_BUDGET),
        );
        const created = new Set(createdObjects(receipt, `${ids.ordersPackage}::queue::MarketQueue`).map((queue) => queue.id));
        for (const market of batch) {
            const queueId = marketQueueId(ids.orderDesk, market.id);
            if (!created.has(queueId)) throw new Error(`${label} did not create queue ${queueId} for market ${market.id}`);
            journal.queues.push({ marketId: market.id, expiryMs: market.expiryMs, queueId, createTx: receipt.digest! });
        }
        ops.persist(runtime);
    }
}

async function ensureWatermarks(runtime: Runtime): Promise<void> {
    const journal = runtime.journal;
    const baseline = journal.baseline!;
    const label = "bump_version_watermarks";
    if (!journal.transactions[label] && !journal.emitted[label]) {
        const predict = (await readProtocolState(runtime, baseline.protocolConfig)).versionWatermark;
        const sessions = await readSessionsWatermark(runtime, baseline.sessionsConfig);
        const bump = { predict: predict !== PREDICT_CURRENT_VERSION, sessions: sessions !== SESSIONS_CURRENT_VERSION };
        if (!bump.predict && !bump.sessions) return;
        await submit(
            runtime,
            label,
            () =>
                bumpWatermarksTransaction(
                    {
                        ...adminIds(runtime),
                        sessionsPackage: journal.packages.sessions!.packageId,
                        sessionsConfig: baseline.sessionsConfig,
                        sessionsAdminCap: baseline.sessions.adminCap,
                    },
                    bump,
                ),
            BigInt(TRANSACTION_GAS_BUDGET),
        );
    } else {
        await submit(runtime, label, () => new Transaction(), BigInt(TRANSACTION_GAS_BUDGET));
    }
}

async function ensureUnpaused(runtime: Runtime): Promise<void> {
    const label = "unpause_trading";
    if (!runtime.journal.transactions[label] && !runtime.journal.emitted[label]) {
        if (!(await readProtocolState(runtime, runtime.journal.baseline!.protocolConfig)).tradingPaused) return;
    }
    await submit(runtime, label, () => unpauseTransaction(adminIds(runtime)), BigInt(TRANSACTION_GAS_BUDGET));
}

// === Checks ===

// The deployment as it stands before step 1: trading paused, not frozen, before the cutover, and
// Predict and Sessions at the expected package versions with every cap the rollout uses held by
// the sender.
async function precheck(runtime: Runtime): Promise<Baseline> {
    const { opts } = runtime;
    const profile = NETWORK_PROFILES[opts.network];
    const manifest = asRecord(JSON.parse(readFileSync(opts.manifest, "utf8")));
    if (manifest.network !== opts.network || manifest.chainId !== runtime.journal.chainId)
        throw new Error(`${opts.manifest} is ${String(manifest.network)}/${String(manifest.chainId)}, not ${opts.network}/${runtime.journal.chainId}`);
    const packages = asRecord(manifest.packages);
    const objects = asRecord(manifest.objects);
    const pair = async (pkg: "predict" | "sessions", expectedVersion: string, adminType: string, explicit: string | null): Promise<CapPair> => {
        const originalId = requiredObjectId(packages[pkg], `manifest packages.${pkg}`);
        const record = readRecord(runtime, pkg);
        if (!record) throw new Error(`${pkg} has no ${opts.network} publication record`);
        if (record.chainId !== runtime.journal.chainId || record.originalId !== originalId)
            throw new Error(`${pkg} record is ${record.chainId}/${record.originalId}, expected ${runtime.journal.chainId}/${originalId}`);
        if (record.version !== expectedVersion)
            throw new Error(`${pkg} record is package version ${record.version}, expected ${expectedVersion}`);
        const live = packageMetadata(runtime, record.publishedAt);
        if (live.packageVersion !== expectedVersion)
            throw new Error(`${pkg} ${record.publishedAt} is package version ${live.packageVersion} on chain`);
        await assertUpgradeCap(runtime, record.upgradeCap, record.publishedAt, expectedVersion, pkg);
        return {
            originalId,
            publishedAt: record.publishedAt,
            version: record.version,
            upgradeCap: record.upgradeCap,
            adminCap: await ownedCap(runtime, `${originalId}::${adminType}`, explicit, `${pkg} admin cap`),
        };
    };
    const predict = await pair("predict", profile.predictVersion, "admin::AdminCap", opts.adminCap);
    const sessions = await pair("sessions", profile.sessionsVersion, "session_config::SessionsAdminCap", opts.sessionsAdminCap);
    for (const pkg of ["predict_math", "predict_orders"] as const) {
        if (readRecord(runtime, pkg)) throw new Error(`${pkg} already has a ${opts.network} publication record`);
    }
    const protocolConfig = requiredObjectId(objects.protocolConfig, "manifest objects.protocolConfig");
    const poolVault = requiredObjectId(objects.poolVault, "manifest objects.poolVault");
    const sessionsConfig = requiredObjectId(objects.sessionsConfig, "manifest objects.sessionsConfig");
    for (const [id, type] of [
        [protocolConfig, `${predict.originalId}::protocol_config::ProtocolConfig`],
        [poolVault, `${predict.originalId}::plp::PoolVault`],
        [sessionsConfig, `${sessions.originalId}::session_config::SessionsConfig`],
    ] as const) {
        const object = await readObject(runtime, id);
        if (object.type !== type || object.owner !== "shared") throw new Error(`${id} is ${object.type} owned by ${object.owner}`);
    }
    const state = await readProtocolState(runtime, protocolConfig);
    const sessionsWatermark = await readSessionsWatermark(runtime, sessionsConfig);
    assertPrecheckState(state, sessionsWatermark);
    return {
        predict,
        sessions,
        protocolConfig,
        poolVault,
        sessionsConfig,
        versionWatermark: state.versionWatermark,
        sessionsVersionWatermark: sessionsWatermark,
        checkedAt: new Date().toISOString(),
    };
}

export function assertPrecheckState(state: ProtocolState, sessionsWatermark: string): void {
    if (!state.tradingPaused) throw new Error("trading is not paused; pause it before the rollout starts");
    if (state.frozen) throw new Error("Predict is frozen");
    if (BigInt(state.versionWatermark) >= BigInt(PREDICT_CURRENT_VERSION))
        throw new Error(`Predict's watermark is already ${state.versionWatermark}`);
    if (BigInt(sessionsWatermark) >= BigInt(SESSIONS_CURRENT_VERSION))
        throw new Error(`Sessions' watermark is already ${sessionsWatermark}`);
}

// Trading stays paused until the reopen step, which an emitted reopen the multisig already
// executed counts as, since this run records it later. Nothing may freeze Predict mid-rollout.
export function assertRolloutState(state: ProtocolState, journal: Pick<UpgradeJournal, "transactions" | "emitted" | "status">): void {
    if (state.frozen) throw new Error("Predict is frozen");
    const reopened = journal.transactions.unpause_trading || journal.emitted.unpause_trading || journal.status === "complete";
    if (!state.tradingPaused && !reopened) throw new Error("trading reopened before the rollout's reopen step");
}

// Every later run re-reads what the rollout depends on: trading stays paused until the reopen
// step, nothing froze Predict, and the caps are still the sender's.
async function recheck(runtime: Runtime): Promise<void> {
    const baseline = runtime.journal.baseline!;
    assertRolloutState(await readProtocolState(runtime, baseline.protocolConfig), runtime.journal);
    for (const [id, owner] of [
        [baseline.predict.adminCap, runtime.opts.sender],
        [baseline.sessions.adminCap, runtime.opts.sender],
    ] as const) {
        const cap = await readObject(runtime, id);
        if (cap.owner !== owner) throw new Error(`${id} is owned by ${cap.owner}, not ${owner}`);
    }
}

async function assertGasFunding(runtime: Runtime): Promise<void> {
    if (runtime.opts.mode !== "execute") return;
    const remainingPackages = (["predict_math", "predict", "predict_orders", "sessions"] as const).filter(
        (pkg) => !runtime.journal.packages[pkg],
    ).length;
    const required =
        BigInt(PACKAGE_GAS_BUDGET) * BigInt(remainingPackages) + BigInt(TRANSACTION_GAS_BUDGET) * 4n;
    const { balance } = await runtime.client.getBalance({ owner: runtime.opts.sender });
    if (BigInt(balance.balance) < required)
        throw new Error(`${runtime.opts.sender} has ${balance.balance} MIST, below the ${required} MIST the remaining steps reserve`);
}

// Read back everything the completed steps promise.
async function verifyUpgrade(runtime: Runtime): Promise<Verification> {
    const journal = runtime.journal;
    const baseline = journal.baseline!;
    for (const pkg of ["predict_math", "predict", "predict_orders", "sessions"] as const) {
        if (journal.packages[pkg]) await verifyPackageRecord(runtime, pkg);
    }
    await readLaunchOrderFee(runtime);
    const enabled = await isOrderFlowEnabled(runtime);
    if (!enabled) throw new Error("the companion's OrderFlow witness is not allowlisted");
    if (!(await isFlushOperator(runtime, journal.flushOperator)))
        throw new Error(`${journal.flushOperator} is not a flush operator`);
    assertOrderFlowReceipt(await settledReceipt(runtime.client, journal.transactions.enable_order_flow!), {
        ordersPackage: journal.packages.predict_orders!.packageId,
        orderDesk: journal.orderDesk!,
    });
    const live = await liveMarkets(runtime);
    const queues: QueueRecord[] = [];
    for (const market of live) {
        const queueId = marketQueueId(journal.orderDesk!, market.id);
        const queue = await readObject(runtime, queueId);
        if (
            queue.type !== `${journal.packages.predict_orders!.packageId}::queue::MarketQueue` ||
            queue.owner !== "shared" ||
            normalizeId(field(queue.json, "desk_id", "MarketQueue")) !== journal.orderDesk ||
            normalizeId(field(queue.json, "expiry_market_id", "MarketQueue")) !== market.id
        )
            throw new Error(`queue ${queueId} is not ${market.id}'s shared queue on the desk`);
        queues.push(journal.queues.find((entry) => entry.marketId === market.id) ?? { ...market, marketId: market.id, queueId, createTx: null });
    }
    const state = await readProtocolState(runtime, baseline.protocolConfig);
    const sessionsWatermark = await readSessionsWatermark(runtime, baseline.sessionsConfig);
    const cutover = Boolean(journal.transactions.bump_version_watermarks) || state.versionWatermark === PREDICT_CURRENT_VERSION;
    if (cutover && (state.versionWatermark !== PREDICT_CURRENT_VERSION || sessionsWatermark !== SESSIONS_CURRENT_VERSION))
        throw new Error(`watermarks are ${state.versionWatermark}/${sessionsWatermark}, expected ${PREDICT_CURRENT_VERSION}/${SESSIONS_CURRENT_VERSION}`);
    if (journal.transactions.unpause_trading && state.tradingPaused) throw new Error("trading is still paused");
    return {
        verifiedAt: new Date().toISOString(),
        predictPackage: journal.packages.predict!.packageId,
        predictVersion: journal.packages.predict!.version,
        predictMathPackage: journal.packages.predict_math!.packageId,
        predictOrdersPackage: journal.packages.predict_orders!.packageId,
        orderDesk: journal.orderDesk!,
        predictUpgradeCheckpoint: journal.predictUpgradeCheckpoint!,
        ordersPublishCheckpoint: journal.ordersPublishCheckpoint!,
        flushOperator: journal.flushOperator,
        sessionsPackage: journal.packages.sessions?.packageId ?? null,
        sessionsVersion: journal.packages.sessions?.version ?? null,
        orderFlowEnabled: enabled,
        liveMarketQueues: queues,
        versionWatermark: state.versionWatermark,
        sessionsVersionWatermark: sessionsWatermark,
        tradingPaused: state.tradingPaused,
    };
}

// === Orchestration ===

export interface UpgradeOperations {
    ensurePublished: typeof ensurePublished;
    ensureUpgraded: typeof ensureUpgraded;
    ensureOrderFlow: typeof ensureOrderFlow;
    ensureMarketQueues: (runtime: Runtime) => Promise<void>;
    ensureWatermarks: typeof ensureWatermarks;
    ensureUnpaused: typeof ensureUnpaused;
    verifyUpgrade: typeof verifyUpgrade;
    persist: typeof persist;
}

const upgradeOperations: UpgradeOperations = {
    ensurePublished,
    ensureUpgraded,
    ensureOrderFlow,
    ensureMarketQueues: (runtime) => ensureMarketQueues(runtime),
    ensureWatermarks,
    ensureUnpaused,
    verifyUpgrade,
    persist,
};

// The steps this run may reach. The cutover waits for `--cutover`, once the services have moved
// to the new IDs; reopening waits for `--reopen`, and only after the cutover.
export function permittedSteps(opts: Pick<UpgradeOptions, "cutover" | "reopen">): UpgradeStep[] {
    return UPGRADE_STEPS.filter(
        (step) =>
            (step !== "bump_version_watermarks" || opts.cutover) && (step !== "unpause_trading" || opts.reopen),
    );
}

export async function executeUpgrade(runtime: Runtime, ops: UpgradeOperations = upgradeOperations): Promise<void> {
    const journal = runtime.journal;
    const steps = permittedSteps(runtime.opts);
    journal.status = "running";
    journal.lastError = null;
    ops.persist(runtime);
    try {
        await ops.ensurePublished(runtime, "predict_math");
        await ops.ensureUpgraded(runtime, "predict");
        await ops.ensurePublished(runtime, "predict_orders");
        await ops.ensureOrderFlow(runtime);
        await ops.ensureMarketQueues(runtime);
        await ops.ensureUpgraded(runtime, "sessions");
        const cutoverDone = () =>
            Boolean(journal.transactions.bump_version_watermarks) ||
            journal.verification?.versionWatermark === PREDICT_CURRENT_VERSION;
        if (steps.includes("bump_version_watermarks")) {
            // Markets created while the rollout waited get their queue before the cutover.
            await ops.ensureMarketQueues(runtime);
            await ops.ensureWatermarks(runtime);
        } else if (cutoverDone() && !steps.includes("unpause_trading")) {
            throw new Error("the cutover is recorded; resume with --cutover or --reopen");
        }
        if (steps.includes("unpause_trading")) {
            if (!steps.includes("bump_version_watermarks") && !cutoverDone())
                throw new Error("trading reopens only after the cutover; add --cutover");
            await ops.ensureUnpaused(runtime);
        }
        journal.verification = await ops.verifyUpgrade(runtime);
        if (!cutoverDone() && !steps.includes("bump_version_watermarks")) journal.status = "awaiting-cutover";
        else if (!steps.includes("unpause_trading")) journal.status = "awaiting-reopen";
        else {
            journal.status = "complete";
            journal.completedAt = new Date().toISOString();
        }
        ops.persist(runtime);
    } catch (error) {
        if (error instanceof AwaitingExecution) {
            journal.status = "awaiting-execution";
            ops.persist(runtime);
            throw error;
        }
        journal.status = journal.inFlight ? "ambiguous" : "partial";
        journal.lastError = error instanceof Error ? error.message : String(error);
        ops.persist(runtime);
        throw error;
    }
}

// === Worktree and lock ===

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

// The only files the rollout writes in the repository are the four packages' publication records.
export const GENERATED_RECORDS = ["predict_math", "predict", "predict_orders", "sessions"].map(
    (pkg) => `packages/${pkg}/Published.toml`,
);

export function unexpectedPaths(paths: readonly string[]): string[] {
    return paths.filter((path) => !GENERATED_RECORDS.includes(path));
}

// Testnet and Mainnet build the committed source. A resumed run may follow commits that only
// record publications; anything else needs a fresh rollout.
function assertSource(runtime: Pick<Runtime, "opts" | "journal">): string {
    const head = git(["rev-parse", "HEAD"]);
    if (runtime.opts.network === "localnet") return head;
    const unexpected = unexpectedPaths(changedPaths());
    if (unexpected.length) throw new Error(`the source tree is dirty outside publication records: ${unexpected.join(", ")}`);
    const recorded = runtime.journal.sourceCommit;
    if (recorded && recorded !== head) {
        const changed = git(["diff", "--name-only", recorded, head]).split("\n").filter(Boolean);
        if (unexpectedPaths(changed).length)
            throw new Error(`the rollout started at ${recorded}; HEAD ${head} changes more than publication records`);
    }
    return head;
}

function acquireLock(chainId: string): string {
    const commonDirRaw = git(["rev-parse", "--git-common-dir"]);
    const commonDir = isAbsolute(commonDirRaw) ? commonDirRaw : resolve(REPO_ROOT, commonDirRaw);
    // Shared with deploy.ts: one process at a time publishes or wires a chain's deployment.
    const path = resolve(commonDir, `predict-${chainId}-deployment.lock`);
    let descriptor: number;
    try {
        descriptor = openSync(path, "wx", 0o600);
    } catch {
        const detail = existsSync(path) ? readFileSync(path, "utf8").trim() : "";
        throw new Error(`deployment lock already exists at ${path}. Fail closed: inspect it first. lock=${detail}`);
    }
    writeFileSync(descriptor, `${JSON.stringify({ token: randomUUID(), pid: process.pid, startedAt: new Date().toISOString(), worktree: REPO_ROOT, workflow: "upgrade_v4" })}\n`);
    closeSync(descriptor);
    return path;
}

// === Entry point ===

function printPlan(runtime: Runtime): void {
    const { opts, journal } = runtime;
    const baseline = journal.baseline!;
    console.log(`[upgrade] network: ${opts.network} (${journal.chainId}), build env ${journal.buildEnvironment}`);
    console.log(`[upgrade] sender: ${opts.sender} (${journal.signing === "unsigned" || opts.mode === "emit-unsigned" ? "unsigned bytes for the multisig" : "keystore signer"})`);
    console.log(`[upgrade] source: ${journal.sourceCommit}`);
    console.log(`[upgrade] Predict ${baseline.predict.originalId}: v${baseline.predict.version} at ${baseline.predict.publishedAt}, UpgradeCap ${baseline.predict.upgradeCap}, AdminCap ${baseline.predict.adminCap}`);
    console.log(`[upgrade] Sessions ${baseline.sessions.originalId}: v${baseline.sessions.version} at ${baseline.sessions.publishedAt}, UpgradeCap ${baseline.sessions.upgradeCap}, SessionsAdminCap ${baseline.sessions.adminCap}`);
    console.log(`[upgrade] watermarks before: Predict ${baseline.versionWatermark}, Sessions ${baseline.sessionsVersionWatermark}; trading paused`);
    console.log(`[upgrade] flush operator to grant: ${journal.flushOperator}`);
    const done = (step: UpgradeStep): boolean =>
        step === "create_market_queues"
            ? Object.keys(journal.transactions).some((label) => label.startsWith("create_market_queues_"))
            : Boolean(journal.transactions[step]);
    const permitted = permittedSteps(opts);
    for (const step of UPGRADE_STEPS) {
        console.log(`[upgrade]   ${done(step) ? "done   " : permitted.includes(step) ? "pending" : "gated  "} ${step}`);
    }
}

function printOutcome(runtime: Runtime): void {
    const journal = runtime.journal;
    const packages = journal.packages;
    console.log(`[upgrade] status: ${journal.status}`);
    if (packages.predict_math) console.log(`[upgrade] predict_math: ${packages.predict_math.packageId}`);
    if (packages.predict)
        console.log(`[upgrade] predict v${packages.predict.version}: ${packages.predict.packageId}; upgrade checkpoint ${journal.predictUpgradeCheckpoint} (the indexer's first checkpoint)`);
    if (packages.predict_orders)
        console.log(`[upgrade] predict_orders: ${packages.predict_orders.packageId}; OrderDesk ${journal.orderDesk}; publish checkpoint ${journal.ordersPublishCheckpoint}`);
    if (packages.sessions) console.log(`[upgrade] sessions v${packages.sessions.version}: ${packages.sessions.packageId}`);
    if (journal.status === "awaiting-cutover")
        console.log("[upgrade] move the keepers, indexer, servers, and SDK to these IDs, then rerun with --cutover");
    if (journal.status === "awaiting-reopen") console.log("[upgrade] rerun with --reopen to unpause trading");
}

export async function main(args = process.argv.slice(2)): Promise<void> {
    const opts = parseUpgradeArgs(args);
    const profile = NETWORK_PROFILES[opts.network];
    const suiVersion = command(SUI, ["--version"]);
    const toolchain = assertSuiRelease(suiVersion);
    const snapshot = snapshotClientConfig(opts);
    let lock: string | null = null;
    try {
        const client = new SuiGrpcClient({ baseUrl: snapshot.rpcUrl, network: opts.network });
        const chainId = await shortChainId(client);
        const expectedChain =
            profile.chainId ?? String(asRecord(JSON.parse(readFileSync(opts.manifest, "utf8"))).chainId);
        if (chainId !== expectedChain) throw new Error(`RPC ${snapshot.rpcUrl} is chain ${chainId}, expected ${expectedChain}`);
        if (opts.mode === "execute" && snapshot.activeAddress !== opts.sender)
            throw new Error(`the active keystore address is ${snapshot.activeAddress}, not --sender ${opts.sender}`);
        lock = acquireLock(chainId);
        const journal = loadJournal(opts.state) ?? createUpgradeJournal(opts, chainId);
        assertJournalBinding(journal, opts, chainId);
        const runtime: Runtime = {
            opts,
            journal,
            client,
            snapshot,
            signer: opts.mode === "execute" ? keystoreSigner(snapshot.keystorePath, opts.sender) : null,
            toolchain,
            packageMetadataCache: new Map(),
        };
        const head = assertSource(runtime);
        const binary = suiBinaryIdentity();
        const bindings: ExecutionBindings = {
            suiVersion,
            suiBinaryPath: binary.path,
            suiBinaryDigest: binary.digest,
            rpcUrl: snapshot.rpcUrl,
            clientConfigDigest: snapshot.configDigest,
            packageGasBudget: PACKAGE_GAS_BUDGET,
            transactionGasBudget: TRANSACTION_GAS_BUDGET,
        };
        if (journal.bindings) assertExecutionBindings(journal.bindings, bindings);
        if (journal.baseline) await recheck(runtime);
        else journal.baseline = await precheck(runtime);
        journal.sourceCommit ??= head;
        if (opts.mode !== "preflight") {
            journal.bindings ??= bindings;
            journal.startedAt ??= new Date().toISOString();
            journal.signing = opts.network === "mainnet" || opts.mode === "emit-unsigned" ? "unsigned" : "keystore";
            persist(runtime);
            await reconcileInFlight(runtime);
            await assertGasFunding(runtime);
        }
        printPlan(runtime);
        if (opts.mode === "preflight") {
            console.log("[upgrade] preflight complete; no transactions built (pass --execute, or --emit-unsigned for Mainnet)");
            return;
        }
        try {
            await executeUpgrade(runtime);
        } catch (error) {
            if (!(error instanceof AwaitingExecution)) throw error;
            console.log(`[upgrade] emitted ${error.label}: digest ${error.digest}`);
            console.log(`[upgrade]   unsigned transaction and summary: ${error.path}`);
            console.log(`[upgrade]   execute it from ${opts.sender}, then rerun this command; if the multisig rebuilt it, add --executed ${error.label}=<digest>`);
        }
        printOutcome(runtime);
    } finally {
        if (lock) rmSync(lock, { force: true });
        rmSync(snapshot.directory, { recursive: true, force: true });
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch((error) => {
        console.error(error);
        process.exitCode = 1;
    });
}
