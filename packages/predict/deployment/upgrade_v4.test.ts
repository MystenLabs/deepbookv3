// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Transaction } from "@mysten/sui/transactions";
import { toBase58, toBase64 } from "@mysten/sui/utils";
import { marketQueueId, type Receipt } from "./deploy.ts";
import {
    AwaitingExecution,
    GENERATED_RECORDS,
    NETWORK_PROFILES,
    PREDICT_CURRENT_VERSION,
    QUEUE_BATCH,
    SESSIONS_CURRENT_VERSION,
    SUI_RELEASE,
    UPGRADE_STEPS,
    assertExecutionBindings,
    assertJournalBinding,
    assertOrderFlowReceipt,
    assertPackageProgram,
    assertPrecheckState,
    assertRolloutState,
    assertSuiRelease,
    bumpWatermarksTransaction,
    createUpgradeJournal,
    enableOrderFlowTransaction,
    ensureMarketQueues,
    executeUpgrade,
    marketQueuesTransaction,
    mergePubfileRecord,
    mergePublishedSection,
    normalizedProgram,
    parseUpgradeArgs,
    permittedSteps,
    publishedSectionText,
    readPubfileRecord,
    readPublishedRecord,
    transactionKindFromData,
    unexpectedPaths,
    unpauseTransaction,
    unsignedBytesFromCliOutput,
    type ExecutionBindings,
    type QueueOperations,
    type Runtime,
    type UpgradeOperations,
} from "./upgrade_v4.ts";

const id = (digit: string) => `0x${digit.repeat(64)}`;
const digest = (byte: number) => toBase58(new Uint8Array(32).fill(byte));
const testnetArgs = ["--network", "testnet", "--sender", id("a"), "--flush-operator", id("f")];

function moveCalls(tx: Transaction) {
    return tx
        .getData()
        .commands.filter((command) => command.MoveCall)
        .map((command) => command.MoveCall!);
}

function pureBytes(tx: Transaction, argument: unknown): number[] {
    const index = (argument as { Input: number }).Input;
    return [...Buffer.from(tx.getData().inputs[index]!.Pure!.bytes, "base64")];
}

function runtimeFor(args: readonly string[] = testnetArgs): Runtime {
    const opts = parseUpgradeArgs(args);
    return { opts, journal: createUpgradeJournal(opts, "4c78adac") } as unknown as Runtime;
}

test("targets, signing modes, and the localnet inputs are explicit", () => {
    assert.throws(() => parseUpgradeArgs(["--sender", id("a"), "--flush-operator", id("f")]), /--network/);
    assert.throws(() => parseUpgradeArgs(["--network", "testnet", "--flush-operator", id("f")]), /--sender/);
    assert.throws(() => parseUpgradeArgs(["--network", "testnet", "--sender", id("a")]), /--flush-operator/);
    assert.throws(() => parseUpgradeArgs([...testnetArgs.slice(0, 4), "--flush-operator", id("0")]), /nonzero/);
    assert.throws(() => parseUpgradeArgs(["--network", "devnet", "--sender", id("a"), "--flush-operator", id("f")]), /localnet\|testnet\|mainnet/);

    const preflight = parseUpgradeArgs(testnetArgs);
    assert.equal(preflight.mode, "preflight");
    assert.equal(preflight.cutover, false);
    assert.equal(preflight.reopen, false);
    assert.match(preflight.manifest, /deployment\/deployment\.testnet\.json$/);
    assert.match(preflight.state, /deployment\/deployment\.testnet\.upgrade-v4\.state\.json$/);
    assert.equal(parseUpgradeArgs([...testnetArgs, "--execute"]).mode, "execute");
    assert.equal(parseUpgradeArgs([...testnetArgs, "--emit-unsigned"]).mode, "emit-unsigned");
    assert.throws(() => parseUpgradeArgs([...testnetArgs, "--execute", "--emit-unsigned"]), /exclusive/);
    assert.throws(() => parseUpgradeArgs([...testnetArgs, "--execute", "--execute"]), /repeated/);
    assert.throws(() => parseUpgradeArgs([...testnetArgs, "--cutover"]), /need --execute or --emit-unsigned/);

    // Mainnet is never signed here.
    const mainnet = ["--network", "mainnet", "--sender", id("b"), "--flush-operator", id("f")];
    assert.throws(() => parseUpgradeArgs([...mainnet, "--execute"]), /never signed here/);
    const emit = parseUpgradeArgs([...mainnet, "--emit-unsigned", "--executed", `upgrade_predict=${digest(7)}`]);
    assert.deepEqual(emit.executed, { upgrade_predict: digest(7) });
    assert.throws(() => parseUpgradeArgs([...mainnet, "--executed", `upgrade_predict=${digest(7)}`]), /needs --emit-unsigned/);
    assert.throws(() => parseUpgradeArgs([...mainnet, "--emit-unsigned", "--executed", "upgrade_predict"]), /--executed takes/);

    // A localnet names its manifest, its ephemeral publication file, and its staged workspace;
    // Testnet and Mainnet read the committed records only.
    assert.throws(() => parseUpgradeArgs(["--network", "localnet", "--sender", id("a"), "--flush-operator", id("f")]), /localnet needs/);
    assert.throws(() => parseUpgradeArgs([...testnetArgs, "--pubfile", "/tmp/Pub.sim.toml"]), /localnet-only/);
    const local = parseUpgradeArgs([
        "--network", "localnet", "--sender", id("a"), "--flush-operator", id("f"),
        "--manifest", "/tmp/i/deployment.localnet.json", "--pubfile", "/tmp/i/Pub.sim.toml", "--workspace", "/tmp/i/workspace",
    ]);
    assert.equal(local.state, "/tmp/i/deployment.localnet.upgrade-v4.state.json");
    assert.equal(local.workspace, "/tmp/i/workspace");
});

test("the package versions published today and the target versions are pinned per network", () => {
    // Testnet runs Predict package version 4 and Mainnet version 3; both run Sessions version 2.
    // A v3-source localnet publishes each at version 1 and compiles the Testnet graph.
    assert.deepEqual(NETWORK_PROFILES, {
        localnet: { chainId: null, buildEnv: "testnet", predictVersion: "1", sessionsVersion: "1" },
        testnet: { chainId: "4c78adac", buildEnv: "testnet", predictVersion: "4", sessionsVersion: "2" },
        mainnet: { chainId: "35834a8a", buildEnv: "mainnet", predictVersion: "3", sessionsVersion: "2" },
    });
    // `constants::current_version!()` and `session_config::current_version!()` after the upgrade.
    const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
    assert.match(source("../sources/constants.move"), new RegExp(`current_version\\(\\): u64 \\{ ${PREDICT_CURRENT_VERSION} \\}`));
    assert.match(source("../../sessions/sources/session_config.move"), new RegExp(`current_version\\(\\): u64 \\{ ${SESSIONS_CURRENT_VERSION} \\}`));
    assert.equal(SUI_RELEASE, "1.80.1");
    assert.equal(assertSuiRelease("sui 1.80.1-homebrew"), "1.80.1");
    assert.equal(assertSuiRelease("sui 1.80.1-722ac4fcf484"), "1.80.1");
    assert.throws(() => assertSuiRelease("sui 1.78.1-722ac4fcf484"), /release 1\.80\.1/);
});

test("the rollout plan is ordered, and the cutover and reopen wait for their flags", () => {
    assert.deepEqual(UPGRADE_STEPS, [
        "publish_predict_math",
        "upgrade_predict",
        "publish_predict_orders",
        "enable_order_flow",
        "create_market_queues",
        "upgrade_sessions",
        "bump_version_watermarks",
        "unpause_trading",
    ]);
    assert.deepEqual(permittedSteps({ cutover: false, reopen: false }), UPGRADE_STEPS.slice(0, 6));
    assert.deepEqual(permittedSteps({ cutover: true, reopen: false }), UPGRADE_STEPS.slice(0, 7));
    assert.deepEqual(permittedSteps({ cutover: true, reopen: true }), [...UPGRADE_STEPS]);
    // Reopening alone never bumps; the run refuses it until a cutover is recorded.
    assert.deepEqual(permittedSteps({ cutover: false, reopen: true }), [...UPGRADE_STEPS.slice(0, 6), "unpause_trading"]);
});

test("the precheck requires paused trading, no freeze, and both floors below the cutover", () => {
    const state = { versionWatermark: "1", tradingPaused: true, frozen: false };
    assert.doesNotThrow(() => assertPrecheckState(state, "1"));
    assert.doesNotThrow(() => assertPrecheckState({ ...state, versionWatermark: "3" }, "2"));
    assert.throws(() => assertPrecheckState({ ...state, tradingPaused: false }, "1"), /not paused/);
    assert.throws(() => assertPrecheckState({ ...state, frozen: true }, "1"), /frozen/);
    assert.throws(() => assertPrecheckState({ ...state, versionWatermark: "4" }, "1"), /already 4/);
    assert.throws(() => assertPrecheckState(state, "3"), /Sessions' watermark is already 3/);

    // Later runs: trading stays paused until the reopen step, recorded or emitted and executed.
    const journal = { transactions: {} as Record<string, string>, emitted: {} as Record<string, never>, status: "running" as const };
    assert.doesNotThrow(() => assertRolloutState(state, journal));
    assert.throws(() => assertRolloutState({ ...state, tradingPaused: false }, journal), /reopened before/);
    assert.throws(() => assertRolloutState({ ...state, frozen: true }, journal), /frozen/);
    assert.doesNotThrow(() => assertRolloutState({ ...state, tradingPaused: false }, { ...journal, transactions: { unpause_trading: "d" } }));
    assert.doesNotThrow(() =>
        assertRolloutState({ ...state, tradingPaused: false }, { ...journal, emitted: { unpause_trading: { digest: "d", path: "p", emittedAt: "t" } as never } }),
    );
});

test("the journal binds the network, chain, sender, flush operator, signing mode, and toolchain", () => {
    const opts = parseUpgradeArgs([...testnetArgs, "--execute"]);
    const journal = createUpgradeJournal(opts, "4c78adac");
    assert.equal(journal.signing, "keystore");
    assert.equal(journal.buildEnvironment, "testnet");
    assert.doesNotThrow(() => assertJournalBinding(journal, opts, "4c78adac"));
    assert.throws(() => assertJournalBinding(journal, opts, "35834a8a"), /bound to/);
    assert.throws(
        () => assertJournalBinding(journal, parseUpgradeArgs(["--network", "testnet", "--sender", id("b"), "--flush-operator", id("f")]), "4c78adac"),
        /bound to/,
    );
    assert.throws(
        () => assertJournalBinding(journal, parseUpgradeArgs(["--network", "testnet", "--sender", id("a"), "--flush-operator", id("e")]), "4c78adac"),
        /flush operator/,
    );
    // Once started, a keystore rollout cannot switch to emitted bytes, or back.
    journal.startedAt = "2026-10-08T00:00:00.000Z";
    assert.throws(() => assertJournalBinding(journal, parseUpgradeArgs([...testnetArgs, "--emit-unsigned"]), "4c78adac"), /signs with keystore/);
    assert.doesNotThrow(() => assertJournalBinding(journal, parseUpgradeArgs(testnetArgs), "4c78adac"));
    const mainnet = parseUpgradeArgs(["--network", "mainnet", "--sender", id("b"), "--flush-operator", id("f"), "--emit-unsigned"]);
    assert.equal(createUpgradeJournal(mainnet, "35834a8a").signing, "unsigned");

    const bindings: ExecutionBindings = {
        suiVersion: "sui 1.80.1-homebrew",
        suiBinaryPath: "/opt/homebrew/bin/sui",
        suiBinaryDigest: "d",
        rpcUrl: "https://fullnode.testnet.sui.io:443",
        clientConfigDigest: "c",
        packageGasBudget: "5000000000",
        transactionGasBudget: "1000000000",
    };
    assert.doesNotThrow(() => assertExecutionBindings(bindings, { ...bindings }));
    assert.throws(() => assertExecutionBindings(bindings, { ...bindings, rpcUrl: "https://other" }), /bindings changed/);
});

test("Testnet and Mainnet records keep other networks' history; a localnet record uses the CLI's layout", () => {
    const existing = `# Generated by Move
# This file contains metadata about published versions of this package in different environments
# This file SHOULD be committed to source control

[published.mainnet]
chain-id = "35834a8a"
published-at = "${id("1")}"
original-id = "${id("1")}"
version = 3
toolchain-version = "1.80.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${id("2")}"

[published.testnet]
chain-id = "4c78adac"
published-at = "${id("3")}"
original-id = "${id("4")}"
version = 4
toolchain-version = "1.80.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${id("5")}"
`;
    assert.deepEqual(readPublishedRecord(existing, "testnet"), {
        chainId: "4c78adac",
        publishedAt: id("3"),
        originalId: id("4"),
        version: "4",
        upgradeCap: id("5"),
    });
    const upgraded = mergePublishedSection(
        existing,
        "testnet",
        publishedSectionText("testnet", "4c78adac", { publishedAt: id("6"), originalId: id("4"), version: "5", upgradeCap: id("5") }, "1.80.1"),
    );
    assert.deepEqual(readPublishedRecord(upgraded, "testnet"), {
        chainId: "4c78adac",
        publishedAt: id("6"),
        originalId: id("4"),
        version: "5",
        upgradeCap: id("5"),
    });
    assert.deepEqual(readPublishedRecord(upgraded, "mainnet"), readPublishedRecord(existing, "mainnet"));
    assert.equal(upgraded.split("[published.").length, 3);

    // A package published for the first time gets the generated header and one section.
    const fresh = mergePublishedSection(
        "",
        "mainnet",
        publishedSectionText("mainnet", "35834a8a", { publishedAt: id("7"), originalId: id("7"), version: "1", upgradeCap: id("8") }, "1.80.1"),
    );
    assert.match(fresh, /^# Generated by Move\n/);
    assert.equal(readPublishedRecord(fresh, "mainnet")!.version, "1");
    assert.equal(readPublishedRecord(fresh, "testnet"), null);

    const pubfile = `# generated by Move
# this file contains metadata from ephemeral publications
# this file should not be committed to source control

build-env = "testnet"
chain-id = "41cf3b37"

[[published]]
source = { local = "/w/packages/token" }
published-at = "${id("1")}"
original-id = "${id("1")}"
version = 1
toolchain-version = "1.80.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${id("2")}"

[[published]]
source = { local = "/w/packages/predict" }
published-at = "${id("3")}"
original-id = "${id("3")}"
version = 1
toolchain-version = "1.80.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${id("4")}"
`;
    const withMath = mergePubfileRecord(pubfile, "/w/packages/predict_math", { publishedAt: id("5"), originalId: id("5"), version: "1", upgradeCap: id("6") }, "1.80.1");
    const upgradedPredict = mergePubfileRecord(withMath, "/w/packages/predict", { publishedAt: id("7"), originalId: id("3"), version: "2", upgradeCap: id("4") }, "1.80.1");
    assert.match(upgradedPredict, /^# generated by Move\n[\s\S]*build-env = "testnet"\nchain-id = "41cf3b37"\n\n\[\[published\]\]\n/);
    assert.equal(upgradedPredict.split("[[published]]").length, 4);
    assert.deepEqual(readPubfileRecord(upgradedPredict, "/w/packages/predict"), {
        chainId: "41cf3b37",
        publishedAt: id("7"),
        originalId: id("3"),
        version: "2",
        upgradeCap: id("4"),
    });
    assert.equal(readPubfileRecord(upgradedPredict, "/w/packages/predict_math")!.publishedAt, id("5"));
    assert.deepEqual(readPubfileRecord(upgradedPredict, "/w/packages/token"), readPubfileRecord(pubfile, "/w/packages/token"));
    assert.equal(readPubfileRecord(upgradedPredict, "/w/packages/predict_orders"), null);
});

test("the CLI's unsigned bytes reduce to their programmable transaction, whatever its gas and expiration", async () => {
    const tx = new Transaction();
    tx.moveCall({ target: `${id("9")}::m::f`, arguments: [tx.pure.u64(5n)] });
    const kind = await tx.build({ onlyTransactionKind: true });
    // TransactionData::V1 = kind, sender, gas data, then an expiration variant newer than the SDK.
    const data = Uint8Array.from([0, ...kind, ...new Uint8Array(32).fill(0xaa), 0, 1, 2, 3, 9, 9]);
    assert.deepEqual([...transactionKindFromData(data)], [...kind]);
    assert.throws(() => transactionKindFromData(Uint8Array.from([1, ...kind])), /variant 1/);
    const output = `INCLUDING DEPENDENCY MoveStdlib\nINCLUDING DEPENDENCY Sui\nBUILDING deepbook_predict_math\n${toBase64(data)}\n`;
    assert.deepEqual([...unsignedBytesFromCliOutput(output)], [...data]);
    assert.throws(() => unsignedBytesFromCliOutput("BUILDING deepbook_predict_math\n"), /no serialized transaction/);
});

test("a package transaction is exactly a publish to the sender or an upgrade through the recorded cap", () => {
    const sender = id("a");
    const publish = new Transaction();
    const cap = publish.publish({ modules: ["AA=="], dependencies: [id("1"), id("2")] });
    publish.transferObjects([cap], publish.pure.address(sender));
    assert.doesNotThrow(() => assertPackageProgram(publish, { kind: "publish" }, sender));
    assert.throws(() => assertPackageProgram(publish, { kind: "publish" }, id("b")), /UpgradeCap to/);

    const upgrade = (capId: string, packageId: string, extra = false) => {
        const tx = new Transaction();
        const ticket = tx.moveCall({
            target: "0x2::package::authorize_upgrade",
            arguments: [tx.objectRef({ objectId: capId, version: "3", digest: digest(1) }), tx.pure.u8(0), tx.pure.vector("u8", [1, 2])],
        });
        const receipt = tx.upgrade({ modules: ["AA=="], dependencies: [id("1")], package: packageId, ticket });
        tx.moveCall({ target: "0x2::package::commit_upgrade", arguments: [tx.objectRef({ objectId: capId, version: "3", digest: digest(1) }), receipt] });
        if (extra) tx.transferObjects([tx.gas], tx.pure.address(id("e")));
        return tx;
    };
    const plan = { kind: "upgrade" as const, currentPackage: id("c"), upgradeCap: id("d") };
    assert.doesNotThrow(() => assertPackageProgram(upgrade(id("d"), id("c")), plan, sender));
    assert.throws(() => assertPackageProgram(upgrade(id("e"), id("c")), plan, sender), /authorizes cap/);
    assert.throws(() => assertPackageProgram(upgrade(id("d"), id("f")), plan, sender), /replaces/);
    assert.throws(() => assertPackageProgram(upgrade(id("d"), id("c"), true), plan, sender), /has commands/);
    assert.throws(() => assertPackageProgram(publish, plan, sender), /has commands/);
});

test("the admin transaction allowlists the witness, re-states the launch fee, and grants the flush operator", () => {
    const ids = { predictPackage: id("4"), protocolConfig: id("5"), adminCap: id("6"), ordersPackage: id("9"), orderDesk: id("8") };
    const tx = enableOrderFlowTransaction(ids, "20000", id("f"));
    const calls = moveCalls(tx);
    assert.deepEqual(
        calls.map((call) => [call.package, call.module, call.function]),
        [
            [id("4"), "protocol_config", "set_order_flow"],
            [id("9"), "desk", "set_order_fee"],
            [id("4"), "protocol_config", "add_flush_operator"],
        ],
    );
    assert.deepEqual(calls[0]!.typeArguments, [`${id("9")}::order_flow::OrderFlow`]);
    // set_order_flow(config, admin_cap, true, clock)
    assert.equal(calls[0]!.arguments.length, 4);
    assert.deepEqual(pureBytes(tx, calls[0]!.arguments[2]), [1]);
    // set_order_fee(desk, admin_cap, config, 20_000, clock) on the same cap and config inputs.
    assert.equal(calls[1]!.arguments.length, 5);
    assert.deepEqual(calls[1]!.arguments[1], calls[0]!.arguments[1]);
    assert.deepEqual(calls[1]!.arguments[2], calls[0]!.arguments[0]);
    assert.deepEqual(pureBytes(tx, calls[1]!.arguments[3]), [0x20, 0x4e, 0, 0, 0, 0, 0, 0]);
    // add_flush_operator(config, admin_cap, operator, clock)
    assert.equal(calls[2]!.arguments.length, 4);
    assert.deepEqual(calls[2]!.arguments[0], calls[0]!.arguments[0]);
    assert.deepEqual(calls[2]!.arguments[1], calls[0]!.arguments[1]);
    assert.deepEqual(pureBytes(tx, calls[2]!.arguments[2]), Array(32).fill(0xff));
    // An address already allowed is left out, since re-adding aborts.
    assert.deepEqual(
        moveCalls(enableOrderFlowTransaction(ids, "20000", null)).map((call) => call.function),
        ["set_order_flow", "set_order_fee"],
    );
});

test("the cutover bumps only the floors below their target, and the reopen unpauses", () => {
    const ids = {
        predictPackage: id("4"), protocolConfig: id("5"), adminCap: id("6"),
        sessionsPackage: id("7"), sessionsConfig: id("8"), sessionsAdminCap: id("9"),
    };
    const both = bumpWatermarksTransaction(ids, { predict: true, sessions: true });
    assert.deepEqual(
        moveCalls(both).map((call) => [call.package, call.module, call.function, call.arguments.length]),
        [
            [id("4"), "protocol_config", "bump_version_watermark", 2],
            [id("7"), "session_config", "bump_version_watermark", 2],
        ],
    );
    assert.deepEqual(moveCalls(bumpWatermarksTransaction(ids, { predict: false, sessions: true })).map((call) => call.module), ["session_config"]);
    assert.deepEqual(moveCalls(bumpWatermarksTransaction(ids, { predict: true, sessions: false })).map((call) => call.module), ["protocol_config"]);
    assert.throws(() => bumpWatermarksTransaction(ids, { predict: false, sessions: false }), /no watermark/);

    const unpause = unpauseTransaction(ids);
    const [call] = moveCalls(unpause);
    assert.deepEqual([call!.package, call!.module, call!.function], [id("4"), "protocol_config", "set_trading_paused"]);
    assert.deepEqual(pureBytes(unpause, call!.arguments[2]), [0]);
});

test("the order-flow receipt must allowlist this companion and record the launch policy under its desk", () => {
    const launchPolicy = {
        delay_ms: "800",
        stall_timeout_ms: "5000",
        stuck_threshold_ms: "1500",
        gap_wait_ms: "2000",
        pyth_price_buffer_ms: "0",
        pyth_channel: 3,
        svi_max_age_ms: "60000",
        mint_capacity: "100",
        sell_capacity: "100",
        per_account_cap: "5",
        order_fee: "20000",
        min_sell_quantity: "10000",
        settle_refund_batch: "450",
        settle_payout_batch: "900",
    };
    const ids = { ordersPackage: id("9"), orderDesk: id("8") };
    const receipt = (options: { witness?: string; enabled?: boolean; desk?: string; policy?: object } = {}): Receipt => ({
        digest: "d",
        events: [
            {
                type: `${id("4")}::config_events::OrderFlowUpdated`,
                parsedJson: { order_flow: { name: options.witness ?? `${"9".repeat(64)}::order_flow::OrderFlow` }, enabled: options.enabled ?? true, onchain_timestamp_ms: "1" },
            },
            {
                type: `${id("9")}::queue_events::DelayedExecutionPolicyUpdated`,
                parsedJson: { desk_id: options.desk ?? id("8"), policy: options.policy ?? launchPolicy, onchain_timestamp_ms: "1" },
            },
        ],
    });
    assert.doesNotThrow(() => assertOrderFlowReceipt(receipt(), ids));
    assert.throws(() => assertOrderFlowReceipt(receipt({ enabled: false }), ids), /no enabling OrderFlowUpdated/);
    assert.throws(() => assertOrderFlowReceipt(receipt({ witness: `${"7".repeat(64)}::order_flow::OrderFlow` }), ids), /no enabling OrderFlowUpdated/);
    assert.throws(() => assertOrderFlowReceipt(receipt({ desk: id("a") }), ids), /names desk/);
    assert.throws(() => assertOrderFlowReceipt(receipt({ policy: { ...launchPolicy, order_fee: "30000" } }), ids), /unexpected policy/);
    const withoutPolicy = receipt();
    withoutPolicy.events = withoutPolicy.events!.slice(0, 1);
    assert.throws(() => assertOrderFlowReceipt(withoutPolicy, ids), /0 DelayedExecutionPolicyUpdated/);
});

test("queues are created for live markets only once, in batches, recording queues others created", async () => {
    const runtime = runtimeFor([...testnetArgs, "--execute"]);
    const desk = id("d");
    runtime.journal.packages.predict_orders = { packageId: id("9"), originalId: id("9"), version: "1", upgradeCap: id("c"), transaction: "t" };
    runtime.journal.orderDesk = desk;
    const markets = Array.from({ length: QUEUE_BATCH + 2 }, (_, index) => ({
        id: `0x${(index + 1).toString(16).padStart(64, "0")}`,
        expiryMs: String(60_000 * (index + 1)),
    }));
    // The market keeper already created the first market's queue.
    const existing = new Set([marketQueueId(desk, markets[0]!.id)]);
    const submitted: Array<{ label: string; markets: number }> = [];
    let lostResponse = true;
    const ops: QueueOperations = {
        liveMarkets: async () => markets,
        objectExists: async (_runtime, queueId) => existing.has(queueId),
        persist() {},
        submit: async (rt, label, build) => {
            const tx = await build();
            const calls = moveCalls(tx);
            assert.ok(calls.every((call) => call.package === id("9") && `${call.module}::${call.function}` === "queue::create_and_share"));
            // Every call borrows the one desk input.
            assert.equal(new Set(calls.map((call) => JSON.stringify(call.arguments[0]))).size, 1);
            const marketIds = calls.map((call) => {
                const input = tx.getData().inputs[(call.arguments[1] as { Input: number }).Input]!;
                return input.UnresolvedObject!.objectId;
            });
            submitted.push({ label, markets: marketIds.length });
            rt.journal.transactions[label] = `tx-${label}`;
            for (const market of marketIds) existing.add(marketQueueId(desk, market));
            if (lostResponse) {
                lostResponse = false;
                throw new Error("lost response");
            }
            return {
                digest: `tx-${label}`,
                objectChanges: marketIds.map((market) => ({
                    type: "created",
                    objectId: marketQueueId(desk, market),
                    objectType: `${id("9")}::queue::MarketQueue`,
                })),
            };
        },
    };
    // The first batch lands but its response is lost; the rerun finds those queues and creates
    // only the rest, and a third run creates nothing.
    await assert.rejects(ensureMarketQueues(runtime, ops), /lost response/);
    await ensureMarketQueues(runtime, ops);
    await ensureMarketQueues(runtime, ops);
    assert.deepEqual(submitted, [
        { label: "create_market_queues_0", markets: QUEUE_BATCH },
        { label: "create_market_queues_1", markets: 1 },
    ]);
    assert.deepEqual(
        runtime.journal.queues.map((queue) => queue.marketId).sort(),
        markets.map((market) => market.id).sort(),
    );
    const byMarket = new Map(runtime.journal.queues.map((queue) => [queue.marketId, queue]));
    assert.equal(byMarket.get(markets[0]!.id)!.createTx, null);
    assert.equal(byMarket.get(markets[QUEUE_BATCH + 1]!.id)!.createTx, "tx-create_market_queues_1");
    assert.ok(runtime.journal.queues.every((queue) => queue.queueId === marketQueueId(desk, queue.marketId)));

    assert.throws(() => marketQueuesTransaction({ ordersPackage: id("9"), orderDesk: desk }, []), /1 to 50/);
    assert.throws(
        () => marketQueuesTransaction({ ordersPackage: id("9"), orderDesk: desk }, markets.map((market) => market.id)),
        /1 to 50/,
    );
});

test("the rollout resumes without repeating steps and stops at each gate", async () => {
    const calls: string[] = [];
    const ops = (failAt: string | null = null): UpgradeOperations => {
        const step = (name: string) => async () => {
            calls.push(name);
            if (name === failAt) throw new Error(`${name} failed`);
        };
        return {
            ensurePublished: async (_runtime, pkg) => step(`publish ${pkg}`)(),
            ensureUpgraded: async (_runtime, pkg) => step(`upgrade ${pkg}`)(),
            ensureOrderFlow: step("order flow"),
            ensureMarketQueues: step("queues"),
            ensureWatermarks: async (runtime) => {
                await step("watermarks")();
                runtime.journal.transactions.bump_version_watermarks = "bump";
            },
            ensureUnpaused: step("unpause"),
            verifyUpgrade: async () => {
                calls.push("verify");
                return null as never;
            },
            persist() {},
        };
    };
    const runtime = runtimeFor([...testnetArgs, "--execute"]);
    await assert.rejects(executeUpgrade(runtime, ops("order flow")), /order flow failed/);
    assert.equal(runtime.journal.status, "partial");
    assert.equal(runtime.journal.lastError, "order flow failed");

    calls.length = 0;
    await executeUpgrade(runtime, ops());
    assert.deepEqual(calls, [
        "publish predict_math",
        "upgrade predict",
        "publish predict_orders",
        "order flow",
        "queues",
        "upgrade sessions",
        "verify",
    ]);
    assert.equal(runtime.journal.status, "awaiting-cutover");
    assert.equal(runtime.journal.lastError, null);

    // The cutover backfills queues for markets created while the rollout waited, first.
    calls.length = 0;
    runtime.opts.cutover = true;
    await executeUpgrade(runtime, ops());
    assert.deepEqual(calls.slice(-4), ["upgrade sessions", "queues", "watermarks", "verify"]);
    assert.equal(runtime.journal.status, "awaiting-reopen");

    // A run without --cutover or --reopen after the cutover would report the wrong stage.
    runtime.opts.cutover = false;
    await assert.rejects(executeUpgrade(runtime, ops()), /resume with --cutover or --reopen/);

    calls.length = 0;
    runtime.opts.reopen = true;
    await executeUpgrade(runtime, ops());
    assert.deepEqual(calls.slice(-3), ["upgrade sessions", "unpause", "verify"]);
    assert.equal(runtime.journal.status, "complete");
    assert.ok(runtime.journal.completedAt);

    // Reopening refuses to run before any cutover.
    const early = runtimeFor([...testnetArgs, "--execute", "--reopen"]);
    calls.length = 0;
    await assert.rejects(executeUpgrade(early, ops()), /only after the cutover/);
    assert.equal(calls.includes("unpause"), false);

    // A transaction emitted for the multisig parks the run until it lands.
    const emitted = runtimeFor(["--network", "mainnet", "--sender", id("b"), "--flush-operator", id("f"), "--emit-unsigned"]);
    const parked = ops();
    parked.ensureUpgraded = async () => {
        throw new AwaitingExecution("upgrade_predict", "digest", "/tmp/02-upgrade_predict.json");
    };
    await assert.rejects(executeUpgrade(emitted, parked), AwaitingExecution);
    assert.equal(emitted.journal.status, "awaiting-execution");
    assert.equal(emitted.journal.lastError, null);
});

test("a transaction the multisig rebuilt matches the emitted program despite new gas, versions, and input order", () => {
    const build = (order: "capFirst" | "feeFirst", version: string, fee = 20_000n) => {
        const tx = new Transaction();
        const cap = () => tx.objectRef({ objectId: id("6"), version, digest: digest(2) });
        const amount = () => tx.pure.u64(fee);
        const [first, second] = order === "capFirst" ? [cap(), amount()] : [amount(), cap()].reverse();
        tx.moveCall({ target: `${id("9")}::desk::set_order_fee`, arguments: [tx.sharedObjectRef({ objectId: id("8"), initialSharedVersion: "1", mutable: true }), first!, second!] });
        return tx.getData();
    };
    const emitted = normalizedProgram(build("capFirst", "3"));
    assert.equal(normalizedProgram(build("feeFirst", "9")), emitted);
    assert.notEqual(normalizedProgram(build("capFirst", "3", 30_000n)), emitted);
});

test("only the four packages' publication records may change during a rollout", () => {
    assert.deepEqual(GENERATED_RECORDS, [
        "packages/predict_math/Published.toml",
        "packages/predict/Published.toml",
        "packages/predict_orders/Published.toml",
        "packages/sessions/Published.toml",
    ]);
    assert.deepEqual(unexpectedPaths(["packages/predict/Published.toml", "packages/sessions/Published.toml"]), []);
    assert.deepEqual(
        unexpectedPaths(["packages/predict/Published.toml", "packages/predict/sources/constants.move", "packages/account/Published.toml"]),
        ["packages/predict/sources/constants.move", "packages/account/Published.toml"],
    );
    // The journal and emitted bytes are ignored by git, so they never dirty the tree.
    const ignore = readFileSync(new URL("../../../.gitignore", import.meta.url), "utf8");
    assert.match(ignore, /^packages\/predict\/deployment\/deployment\.\*\.state\.json$/m);
    assert.match(ignore, /^packages\/predict\/deployment\/deployment\.\*\.upgrade-v4\/$/m);
});
