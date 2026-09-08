// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    readdirSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
    CADENCES,
    configureDeployment,
    assertGasFunding,
    availableGasBalance,
    parseTargetArgs,
    MAINNET_USDC,
    lockedCapitalTransaction,
    ensureLockedCapital,
    validateLockedCapitalReceipt,
    resolvedModuleAddress,
    mergePublishedMetadata,
    EXPECTED_PROTOCOL_CONFIG,
    MANIFEST_RELATIVE,
    STATE_RELATIVE,
    assertScriptRecovery,
    assertRecordedScriptBinding,
    PENDING_CURRENCY_OWNER,
    objectEvidence as readObjectEvidence,
    assertDeploymentTarget,
    assertExactPackageGraph,
    assertExecutionBindings,
    assertNoKeystoreOverride,
    assertIntegrationManifest,
    assertCapsIssuanceReady,
    capIssuanceTransaction,
    issueOperationalCaps,
    executeDeployment,
    ensureMarkets,
    assertPackagePlan,
    assertRecoverableInFlight,
    assertSourceBinding,
    assertSuiCliVersion,
    buildIntegrationManifest,
    checkpointRecoveredTransaction,
    createDeploymentState,
    irreversibleDeploymentSteps,
    irreversibleStepDigest,
    isUnderlyingNotRegisteredError,
    maximumTransactionCountPerRun,
    parseDeploymentArgs,
    parseOptionBlockScholesStorePair,
    parsePackageMetadata,
    plannedTransactionCount,
    plannedTransactionSteps,
    publishedMetadataText,
    reconcileJournaledInFlight,
    recordVerifiedTransactionFailure,
    removeRecoveryTemporaries,
    runBroadcastBoundary,
    sameObjectReference,
    unexpectedDeploymentPaths,
    validateBootstrapReceipt,
    withFreshPackageStage,
    type IntegrationManifest,
    type Receipt,
} from "./deploy.ts";

const id = (digit: string) => `0x${digit.repeat(64)}`;
configureDeployment("testnet", id("a"));

test("vendored Pyth sources match the pinned upstream inventory and hashes", () => {
    const root = new URL("../../../vendor/pyth_lazer/", import.meta.url);
    const provenance = JSON.parse(readFileSync(new URL("provenance.json", root), "utf8"));
    const inventory = [
        "LICENSE",
        "Move.toml",
        ...["sources", "tests"].flatMap((dir) =>
            readdirSync(new URL(`${dir}/`, root)).map((file) => `${dir}/${file}`),
        ),
    ];
    assert.deepEqual(inventory.sort(), Object.keys(provenance.files).sort());
    for (const file of inventory) {
        let content = readFileSync(new URL(file, root));
        if (file === "Move.toml") {
            const text = content.toString();
            assert.equal(text.split(provenance.manifestReplacement.to).length, 2);
            content = Buffer.from(
                text.replace(
                    provenance.manifestReplacement.to,
                    provenance.manifestReplacement.from,
                ),
            );
        }
        assert.equal(
            createHash("sha256").update(content).digest("hex"),
            provenance.files[file],
            file,
        );
    }
});

test("Mainnet Pyth differs from its pinned source only by declared publication inputs", () => {
    const root = new URL("../../../vendor/pyth_lazer_mainnet/", import.meta.url);
    const provenance = JSON.parse(readFileSync(new URL("provenance.json", root), "utf8"));
    const inventory = [
        "LICENSE",
        "Move.toml",
        "Published.toml",
        ...readdirSync(new URL("sources/", root)).map((file) => `sources/${file}`),
    ];
    assert.deepEqual(inventory.sort(), Object.keys(provenance.files).sort());
    assert.deepEqual(provenance.replacements.map((r: { path: string }) => r.path).sort(), [
        "Move.toml",
        "sources/meta.move",
    ]);
    for (const file of inventory) {
        let content = readFileSync(new URL(file, root));
        for (const replacement of provenance.replacements.filter(
            (r: { path: string }) => r.path === file,
        )) {
            const text = content.toString();
            assert.equal(text.split(replacement.to).length, 2, file);
            content = Buffer.from(text.replace(replacement.to, replacement.from));
        }
        assert.equal(
            createHash("sha256").update(content).digest("hex"),
            provenance.files[file],
            file,
        );
    }
});

test("fresh publication staging preserves the vendored dependency outside packages", () => {
    let stagedRoot = "";
    withFreshPackageStage("predict", (directory) => {
        stagedRoot = resolve(directory, "../..");
        const manifest = readFileSync(join(directory, "Move.toml"), "utf8");
        const local = manifest.match(/^pyth_lazer = \{ local = "([^"]+)" \}/m)?.[1];
        assert.ok(local);
        const pyth = resolve(directory, local);
        assert.equal(pyth, join(stagedRoot, "vendor", "pyth_lazer"));
        assert.equal(
            readFileSync(join(pyth, "sources", "update.move"), "utf8"),
            readFileSync(
                new URL("../../../vendor/pyth_lazer/sources/update.move", import.meta.url),
                "utf8",
            ),
        );
        assert.match(readFileSync(join(pyth, "Published.toml"), "utf8"), /\[published.testnet\]/);
        assert.equal(existsSync(join(directory, "Published.toml")), false);
        const mainnetPyth = join(stagedRoot, "vendor", "pyth_lazer_mainnet");
        assert.match(
            readFileSync(join(mainnetPyth, "sources", "meta.move"), "utf8"),
            /fun version\(\): u64 \{\s+2\s+\}/,
        );
        assert.match(
            readFileSync(join(mainnetPyth, "Published.toml"), "utf8"),
            /\[published.mainnet\]/,
        );
    });
    assert.equal(existsSync(stagedRoot), false);
});

test("bootstrap receipt validation uses the deployed USDC supply event schema", () => {
    const vault = id("1");
    const account = id("2");
    const wrapper = id("3");
    // Field names follow vault_events.move; amounts represent the approved 250,000 USDC supply.
    const requested = {
        pool_vault_id: vault,
        account_id: account,
        recipient: wrapper,
        index: "0",
        amount: "250000000000",
        min_plp_out: "0",
        requests_pending_after: "1",
    };
    const filled = {
        pool_vault_id: vault,
        account_id: account,
        recipient: wrapper,
        index: "0",
        usdc_amount: "250000000000",
        shares_minted: "250000000000",
        fee_usdc: "0",
        usdc_remaining: "0",
        requests_pending_after: "0",
    };
    const receipt: Receipt = {
        digest: "bootstrap-tx",
        events: [
            { type: `${id("4")}::vault_events::SupplyRequested`, parsedJson: requested },
            { type: `${id("4")}::vault_events::SupplyFilled`, parsedJson: filled },
        ],
    };
    assert.deepEqual(validateBootstrapReceipt(receipt, vault, account, wrapper), {
        requestIndex: "0",
        sharesMinted: "250000000000",
    });
    for (const [field, badValue] of [
        ["usdc_amount", "249999999999"],
        ["usdc_remaining", "1"],
        ["shares_minted", "249999999999"],
        ["requests_pending_after", "1"],
        ["index", "1"],
        ["account_id", id("5")],
        ["recipient", id("5")],
        ["pool_vault_id", id("5")],
    ]) {
        const invalid = structuredClone(receipt);
        (invalid.events![1].parsedJson as Record<string, unknown>)[field] = badValue;
        assert.throws(() => validateBootstrapReceipt(invalid, vault, account, wrapper));
    }
    const legacy = structuredClone(receipt);
    const fields = legacy.events![1].parsedJson as Record<string, unknown>;
    fields.dusdc_amount = fields.usdc_amount;
    fields.dusdc_remaining = fields.usdc_remaining;
    delete fields.usdc_amount;
    delete fields.usdc_remaining;
    assert.throws(() => validateBootstrapReceipt(legacy, vault, account, wrapper), /not numeric/);
});

test("explicit script-only recovery preserves the published source and fails closed", () => {
    const state = completeStateFixture();
    state.packages = {
        fixed_math: id("1"),
        usdc: id("2"),
        account: id("3"),
        propbook: id("4"),
        predict: id("5"),
        deepbook_core_account: id("6"),
        sessions: id("7"),
    };
    state.publishTx = {
        fixed_math: "math-tx",
        usdc: "usdc-tx",
        account: "account-tx",
        propbook: "propbook-tx",
        predict: "predict-tx",
        deepbook_core_account: "wrapper-tx",
        sessions: "sessions-tx",
    };
    const anchor = state.sourceCommit!;
    assert.throws(() => assertScriptRecovery(state, anchor, []), /interrupted/);
    state.status = "partial";
    assert.doesNotThrow(() =>
        assertScriptRecovery(state, anchor, ["packages/predict/deployment/deploy.ts"]),
    );
    for (const path of [
        "packages/predict/sources/plp.move",
        "packages/usdc/Move.toml",
        "packages/predict/package-lock.json",
        "packages/predict/deployment/other.ts",
    ]) {
        assert.throws(() => assertScriptRecovery(state, anchor, [path]), /cannot change/);
    }
    assert.throws(() => assertScriptRecovery(state, "b".repeat(40), []), /original source anchor/);
    state.inFlight = {
        kind: "transaction",
        label: "bootstrap_pool",
        digest: null,
        package: null,
        startedAt: "2026-09-08T00:00:00Z",
    };
    const correction = "c".repeat(40);
    state.scriptCommits = [correction];
    assert.doesNotThrow(() => assertRecordedScriptBinding(state, correction));
    assert.throws(() => assertRecordedScriptBinding(state, anchor), /source commit changed/);
    assert.throws(
        () => assertRecordedScriptBinding(state, "d".repeat(40)),
        /source commit changed/,
    );
    assert.throws(() => assertScriptRecovery(state, anchor, []), /reconciled/);
    state.inFlight = null;
    delete state.publishTx.sessions;
    assert.throws(() => assertScriptRecovery(state, anchor, []), /all packages/);
    assert.deepEqual(parseDeploymentArgs(["--resume-script-from", anchor]), {
        command: "deploy",
        execute: false,
        resumeScriptFrom: anchor,
    });
    assert.throws(
        () => parseDeploymentArgs(["--resume-script-from", "short"]),
        /full original source/,
    );
});

test("pending currency registration requires address ownership by the coin registry", async () => {
    const object = {
        type: "0x2::coin_registry::Currency<0x1::usdc::USDC>",
        owner: { AddressOwner: "0xc" },
        version: "1",
        digest: "currency-digest",
    };
    const runtime = { client: { getObject: async () => ({ object }) } } as unknown as Parameters<
        typeof readObjectEvidence
    >[0];
    const evidence = await readObjectEvidence(
        runtime,
        id("1"),
        "coin_registry::Currency<0x1::usdc::USDC>",
        PENDING_CURRENCY_OWNER,
    );
    assert.equal(evidence.owner, `0x${"0".repeat(63)}c`);
    object.owner.AddressOwner = "0xd";
    await assert.rejects(
        readObjectEvidence(
            runtime,
            id("1"),
            "coin_registry::Currency<0x1::usdc::USDC>",
            PENDING_CURRENCY_OWNER,
        ),
        /is owned by/,
    );
});

function manifestFixture(): IntegrationManifest {
    const predict = id("4");
    const usdc = id("2");
    return {
        schemaVersion: 8,
        deployment: "deepbook-predict-testnet",
        network: "testnet",
        chainId: "4c78adac",
        sourceCommit: "a".repeat(40),
        packages: {
            fixedMath: id("1"),
            usdc,
            account: id("2"),
            propbook: id("3"),
            predict,
            deepbookCoreAccount: id("5"),
            sessions: id("6"),
        },
        coinTypes: {
            usdc: `${usdc}::usdc::USDC`,
            deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP",
            plp: `${predict}::plp::PLP`,
        },
        objects: {
            usdcCurrency: id("d"),
            plpCurrency: id("e"),
            accountRegistry: id("7"),
            oracleRegistry: id("8"),
            protocolConfig: id("9"),
            poolVault: id("a"),
            registry: id("b"),
            sessionsConfig: id("c"),
            deepbookRegistry: "0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1",
            accumulatorRoot: "0x0000000000000000000000000000000000000000000000000000000000000acc",
            clock: "0x0000000000000000000000000000000000000000000000000000000000000006",
        },
        underlyings: {
            BTC: {
                symbol: "BTC",
                name: "BTC_USD",
                propbookUnderlyingId: 1,
                pythLazerFeedId: 1,
                blockScholesSourceId: 1,
                pythFeed: id("d"),
                blockScholesValueStore: id("e"),
                blockScholesSviStore: id("f"),
            },
        },
        oracleDependencies: {
            pythLazerPackage: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
            pythLazerState: "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
            blockScholesOraclePackage:
                "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
            blockScholesSignerRegistry:
                "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
        },
        externalAuthorizations: {
            deepbookCoreAccount: {
                authorized: true,
                appType: `${id("5")}::account_data::DeepbookCoreAccountApp`,
                registry: "0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1",
            },
        },
        indexing: { startCheckpoint: "1" },
        initialConfiguration: {
            verifiedAfterCheckpoint: "2",
            stateAnchors: {
                protocolConfig: { objectVersion: "1", digest: "protocol" },
                registry: { objectVersion: "1", digest: "registry" },
                oracleRegistry: { objectVersion: "1", digest: "oracle" },
                sessionsConfig: { objectVersion: "1", digest: "sessions" },
                deepbookRegistry: { objectVersion: "1", digest: "deepbook" },
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
                    usePythSpotForForward: EXPECTED_PROTOCOL_CONFIG.usePythSpotForForward,
                    pythSpotFreshnessMs: EXPECTED_PROTOCOL_CONFIG.pythSpotFreshnessMs,
                    blockScholesPriceFreshnessMs:
                        EXPECTED_PROTOCOL_CONFIG.blockScholesPriceFreshnessMs,
                    blockScholesSviFreshnessMs: EXPECTED_PROTOCOL_CONFIG.blockScholesSviFreshnessMs,
                },
                ewmaPenalty: {
                    alpha: EXPECTED_PROTOCOL_CONFIG.ewmaAlpha,
                    zScoreThreshold: EXPECTED_PROTOCOL_CONFIG.ewmaZScoreThreshold,
                    penaltyRate: EXPECTED_PROTOCOL_CONFIG.ewmaPenaltyRate,
                    enabled: EXPECTED_PROTOCOL_CONFIG.ewmaEnabled,
                },
                protocolReserveProfitShare: EXPECTED_PROTOCOL_CONFIG.protocolReserveProfitShare,
                referralFeeRate: EXPECTED_PROTOCOL_CONFIG.referralFeeRate,
                plpSupplyFeeRate: EXPECTED_PROTOCOL_CONFIG.plpSupplyFeeRate,
                plpWithdrawFeeRate: EXPECTED_PROTOCOL_CONFIG.plpWithdrawFeeRate,
                lpRequestLimitFlushAttempts: EXPECTED_PROTOCOL_CONFIG.lpRequestLimitFlushAttempts,
                maxLpPoolValue: EXPECTED_PROTOCOL_CONFIG.maxLpPoolValue,
                maxValuationWindowMs: EXPECTED_PROTOCOL_CONFIG.maxValuationWindowMs,
                noTradeWindowMs: "2000",
            },
            futureMarketTemplate: {
                backingBufferLambda: EXPECTED_PROTOCOL_CONFIG.backingBufferLambda,
                inventoryImpactMaxRate: EXPECTED_PROTOCOL_CONFIG.inventoryImpactMaxRate,
                baseFee: EXPECTED_PROTOCOL_CONFIG.baseFee,
                minFee: EXPECTED_PROTOCOL_CONFIG.minFee,
                minEntryProbability: EXPECTED_PROTOCOL_CONFIG.minEntryProbability,
                maxEntryProbability: EXPECTED_PROTOCOL_CONFIG.maxEntryProbability,
                expiryFeeWindowMs: EXPECTED_PROTOCOL_CONFIG.expiryFeeWindowMs,
                expiryFeeMaxMultiplier: EXPECTED_PROTOCOL_CONFIG.expiryFeeMaxMultiplier,
            },
            cadences: {
                BTC: CADENCES.map((cadence) => ({
                    id: cadence.id,
                    name: cadence.name,
                    periodMs: cadence.periodMs.toString(),
                    enabled: cadence.windowSize > 0n,
                    tickSize: cadence.tickSize.toString(),
                    admissionTickSize: cadence.admissionTickSize.toString(),
                    maxExpiryAllocation: cadence.maxExpiryAllocation.toString(),
                    initialExpiryCash: cadence.initialExpiryCash.toString(),
                    windowSize: cadence.windowSize.toString(),
                })),
            },
        },
    };
}

function objectEvidence(objectId: string, version = "1", digest = `digest-${objectId}`) {
    return {
        objectId,
        type: "fixture",
        owner: "shared",
        version,
        digest,
        previousTransaction: null,
    };
}

function completeStateFixture() {
    const manifest = manifestFixture();
    const state = createDeploymentState();
    state.status = "complete";
    state.sourceCommit = manifest.sourceCommit;
    state.completedAt = "2026-08-21T00:00:00.000Z";
    state.verification = {
        verifiedAt: state.completedAt,
        chainId: manifest.chainId,
        indexingStartCheckpoint: manifest.indexing.startCheckpoint,
        verifiedAfterCheckpoint: manifest.initialConfiguration.verifiedAfterCheckpoint,
        packages: {
            fixed_math: objectEvidence(manifest.packages.fixedMath),
            usdc: objectEvidence(manifest.packages.usdc),
            account: objectEvidence(manifest.packages.account),
            propbook: objectEvidence(manifest.packages.propbook),
            predict: objectEvidence(manifest.packages.predict),
            deepbook_core_account: objectEvidence(manifest.packages.deepbookCoreAccount),
            sessions: objectEvidence(manifest.packages.sessions),
        },
        linkedPackages: {
            deepbook: objectEvidence(
                "0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24",
            ),
            deep: objectEvidence(manifest.coinTypes.deep.split("::")[0]),
            pyth_lazer: objectEvidence(manifest.oracleDependencies.pythLazerPackage),
            wormhole: objectEvidence(
                "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
            ),
            bs_oracle: objectEvidence(manifest.oracleDependencies.blockScholesOraclePackage),
            bs_sid: objectEvidence(
                "0x6a54299d593fca24edf6b17bf8c3aff0b7ba8bc8f4276e9c1065689c50223bba",
            ),
        },
        linkedObjects: {
            clock: objectEvidence(manifest.objects.clock),
            accumulatorRoot: objectEvidence(manifest.objects.accumulatorRoot),
            pythLazerState: objectEvidence(manifest.oracleDependencies.pythLazerState),
            wormholeState: objectEvidence(
                "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
            ),
            blockScholesSignerRegistry: objectEvidence(
                manifest.oracleDependencies.blockScholesSignerRegistry,
            ),
            deepbookRegistry: objectEvidence(
                manifest.objects.deepbookRegistry,
                manifest.initialConfiguration.stateAnchors.deepbookRegistry.objectVersion,
                manifest.initialConfiguration.stateAnchors.deepbookRegistry.digest,
            ),
        },
        sharedObjects: {
            account: {
                "account_registry::AccountRegistry": objectEvidence(
                    manifest.objects.accountRegistry,
                ),
            },
            propbook: {
                "registry::OracleRegistry": objectEvidence(
                    manifest.objects.oracleRegistry,
                    manifest.initialConfiguration.stateAnchors.oracleRegistry.objectVersion,
                    manifest.initialConfiguration.stateAnchors.oracleRegistry.digest,
                ),
            },
            predict: {
                "protocol_config::ProtocolConfig": objectEvidence(
                    manifest.objects.protocolConfig,
                    manifest.initialConfiguration.stateAnchors.protocolConfig.objectVersion,
                    manifest.initialConfiguration.stateAnchors.protocolConfig.digest,
                ),
                "plp::PoolVault": objectEvidence(manifest.objects.poolVault),
                "registry::Registry": objectEvidence(
                    manifest.objects.registry,
                    manifest.initialConfiguration.stateAnchors.registry.objectVersion,
                    manifest.initialConfiguration.stateAnchors.registry.digest,
                ),
            },
            sessions: {
                "session_config::SessionsConfig": objectEvidence(
                    manifest.objects.sessionsConfig,
                    manifest.initialConfiguration.stateAnchors.sessionsConfig.objectVersion,
                    manifest.initialConfiguration.stateAnchors.sessionsConfig.digest,
                ),
            },
        },
        ownedCaps: {},
        oracleObjects: {
            pythFeed: objectEvidence(manifest.underlyings.BTC.pythFeed),
            blockScholesValueStore: objectEvidence(manifest.underlyings.BTC.blockScholesValueStore),
            blockScholesSviStore: objectEvidence(manifest.underlyings.BTC.blockScholesSviStore),
        },
        account: {
            predictAppAuthorized: true,
            deepbookCoreAppAuthorized: true,
            sessionsAppAuthorized: true,
            deepbookCoreAuthorized: true,
            accountWrapper: objectEvidence(id("a")),
        },
        currencies: {
            usdc: objectEvidence(manifest.objects.usdcCurrency!),
            plp: objectEvidence(manifest.objects.plpCurrency),
            mintedAmount: "100000000000000",
            deployerBalance: "99749990000000",
        },
        lifecycleCap: objectEvidence(id("1")),
        valuationCap: objectEvidence(id("2")),
        cadences: CADENCES.map((cadence) => ({
            id: cadence.id,
            name: cadence.name,
            tickSize: cadence.tickSize.toString(),
            admissionTickSize: cadence.admissionTickSize.toString(),
            maxExpiryAllocation: cadence.maxExpiryAllocation.toString(),
            initialExpiryCash: cadence.initialExpiryCash.toString(),
            windowSize: cadence.windowSize.toString(),
            setTx: null,
        })),
        protocolConfig: { ...EXPECTED_PROTOCOL_CONFIG },
        pool: {
            totalSupply: "0",
            idleBalance: "0",
            supplyRequestsPending: "0",
            withdrawRequestsPending: "0",
            activeMarketIds: [],
            activeMarketCash: "0",
            deployerAccountPlpBalance: "0",
        },
        markets: [],
    };
    return state;
}

test("the default invocation is non-broadcasting", async () => {
    assert.deepEqual(parseDeploymentArgs([]), { command: "deploy", execute: false });
    assert.deepEqual(parseDeploymentArgs(["--execute"]), {
        execute: true,
        command: "deploy",
    });
    assert.throws(() => parseDeploymentArgs(["--sessions"]), /unknown deployment argument/);
    assert.throws(() => parseDeploymentArgs(["--smoke"]), /unknown deployment argument/);
    let broadcasts = 0;
    assert.equal(
        await runBroadcastBoundary(false, async () => {
            broadcasts++;
        }),
        false,
    );
    assert.equal(broadcasts, 0);
});

test("operator state and integration manifest are separate artifacts", () => {
    assert.notEqual(STATE_RELATIVE, MANIFEST_RELATIVE);
    assert.match(STATE_RELATIVE, /\.state\.json$/);
    assert.equal(MANIFEST_RELATIVE.endsWith(".state.json"), false);
    const gitignore = readFileSync(new URL("../../../.gitignore", import.meta.url), "utf8");
    assert.ok(gitignore.includes("packages/predict/deployment/deployment.*.state.json\n"));
    assert.ok(gitignore.includes("packages/predict/deployment/deployment.*.json.tmp\n"));
});

test("the deployment policy pins approved defaults and cadence windows", () => {
    assert.equal(EXPECTED_PROTOCOL_CONFIG.baseFee, "100000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.minFee, "22000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.backingBufferLambda, "310000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.protocolReserveProfitShare, "100000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.pythSpotFreshnessMs, "2000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.blockScholesPriceFreshnessMs, "2000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.maxLpPoolValue, "500000000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.maxValuationWindowMs, "300000");
    assert.deepEqual(
        CADENCES.map(
            ({
                name,
                tickSize,
                admissionTickSize,
                maxExpiryAllocation,
                initialExpiryCash,
                windowSize,
            }) => ({
                name,
                tickSize: tickSize.toString(),
                admissionTickSize: admissionTickSize.toString(),
                maxExpiryAllocation: maxExpiryAllocation.toString(),
                initialExpiryCash: initialExpiryCash.toString(),
                windowSize: windowSize.toString(),
            }),
        ),
        [
            {
                name: "1m",
                tickSize: "10000000",
                admissionTickSize: "1000000000",
                maxExpiryAllocation: "10000000000",
                initialExpiryCash: "2000000000",
                windowSize: "2",
            },
            {
                name: "5m",
                tickSize: "10000000",
                admissionTickSize: "1000000000",
                maxExpiryAllocation: "10000000000",
                initialExpiryCash: "2000000000",
                windowSize: "2",
            },
            {
                name: "1h",
                tickSize: "0",
                admissionTickSize: "0",
                maxExpiryAllocation: "0",
                initialExpiryCash: "0",
                windowSize: "0",
            },
            {
                name: "1d",
                tickSize: "0",
                admissionTickSize: "0",
                maxExpiryAllocation: "0",
                initialExpiryCash: "0",
                windowSize: "0",
            },
            {
                name: "1w",
                tickSize: "0",
                admissionTickSize: "0",
                maxExpiryAllocation: "0",
                initialExpiryCash: "0",
                windowSize: "0",
            },
            {
                name: "1mo",
                tickSize: "0",
                admissionTickSize: "0",
                maxExpiryAllocation: "0",
                initialExpiryCash: "0",
                windowSize: "0",
            },
        ],
    );
    const state = createDeploymentState();
    assert.equal(state.wiring.bootstrap.lockCapitalAmount, "10000000");
    assert.equal(state.wiring.bootstrap.supplyAmount, "250000000000");
    assert.equal(state.wiring.currencies.usdc.mintedAmount, "100000000000000");
    assert.equal(EXPECTED_PROTOCOL_CONFIG.noTradeWindowMs, "2000");
    assert.deepEqual(state.issuedCaps, {});
});

test("the package plan is complete and topological", () => {
    assert.doesNotThrow(() => assertPackagePlan());
    assert.throws(
        () =>
            assertPackagePlan([
                "sessions",
                "deepbook_core_account",
                "predict",
                "propbook",
                "account",
                "usdc",
                "fixed_math",
            ]),
        /planned before local dependency/,
    );
});

test("gas funding derives the complete fresh transaction plan", () => {
    assert.equal(plannedTransactionCount(), 19);
    assert.equal(maximumTransactionCountPerRun(), 19);
    assert.equal(irreversibleDeploymentSteps().length, 26);
});

test("target, toolchain, source, and worktree bindings fail closed", () => {
    assert.doesNotThrow(() => assertDeploymentTarget("testnet", "4c78adac", id("a")));
    assert.throws(
        () => assertDeploymentTarget("mainnet", "4c78adac", id("a")),
        /deployment target/,
    );
    assert.throws(() => assertDeploymentTarget("testnet", "bad", id("a")), /deployment target/);
    assert.doesNotThrow(() => assertSuiCliVersion("sui 1.78.1-722ac4fcf484"));
    assert.throws(() => assertSuiCliVersion("sui 1.78.0"), /Sui CLI must be/);
    assert.doesNotThrow(() => assertNoKeystoreOverride(undefined));
    assert.throws(() => assertNoKeystoreOverride("/tmp/alternate.keystore"), /unsupported/);
    assert.doesNotThrow(() => assertSourceBinding("a".repeat(40), "a".repeat(40)));
    assert.throws(
        () => assertSourceBinding("a".repeat(40), "b".repeat(40)),
        /source commit changed/,
    );
    assert.deepEqual(
        unexpectedDeploymentPaths(
            [STATE_RELATIVE, "packages/account/Published.toml", "packages/predict/sources/x.move"],
            ["account"],
        ),
        ["packages/predict/sources/x.move"],
    );
    assert.deepEqual(unexpectedDeploymentPaths([MANIFEST_RELATIVE], [], true), []);
    const state = createDeploymentState();
    const bindings = {
        suiVersion: "sui 1.78.1-722ac4fcf484",
        suiBinaryPath: "/opt/sui",
        suiBinaryDigest: "binary",
        rpcUrl: "https://example.testnet.invalid",
        clientConfigDigest: "config",
        packageGasBudget: "5000000000",
        transactionGasBudget: "1000000000",
    };
    state.suiVersion = bindings.suiVersion;
    state.suiBinaryPath = bindings.suiBinaryPath;
    state.suiBinaryDigest = bindings.suiBinaryDigest;
    state.rpcUrl = bindings.rpcUrl;
    state.clientConfigDigest = bindings.clientConfigDigest;
    state.packageGasBudget = bindings.packageGasBudget;
    state.transactionGasBudget = bindings.transactionGasBudget;
    assert.doesNotThrow(() => assertExecutionBindings(state, bindings));
    assert.throws(
        () => assertExecutionBindings(state, { ...bindings, suiBinaryDigest: "changed" }),
        /execution bindings changed/,
    );
});

test("publish recovery can reconstruct the generated Testnet metadata", () => {
    const packageId = id("a");
    const upgradeCapability = id("b");
    assert.equal(
        publishedMetadataText(packageId, upgradeCapability),
        `# Generated by Move
# This file contains metadata about published versions of this package in different environments
# This file SHOULD be committed to source control

[published.testnet]
chain-id = "4c78adac"
published-at = "${packageId}"
original-id = "${packageId}"
version = 1
toolchain-version = "1.78.1"
build-config = { flavor = "sui", edition = "2024" }
upgrade-capability = "${upgradeCapability}"
`,
    );
});

test("known-digest recovery checkpoints once and unknown outcomes fail closed", () => {
    const state = createDeploymentState();
    state.inFlight = {
        kind: "transaction",
        label: "mint_lifecycle_cap",
        package: null,
        startedAt: "2026-08-21T00:00:00.000Z",
        digest: "known-digest",
    };
    assert.doesNotThrow(() => assertRecoverableInFlight(state.inFlight!, true));
    checkpointRecoveredTransaction(state);
    checkpointRecoveredTransaction(state);
    assert.equal(state.transactions.mint_lifecycle_cap, "known-digest");
    assert.equal(state.inFlight, null);
    assert.throws(
        () =>
            assertRecoverableInFlight(
                {
                    kind: "publish",
                    label: "publish_predict",
                    package: "predict",
                    startedAt: "2026-08-21T00:00:00.000Z",
                    digest: null,
                },
                false,
            ),
        /no known digest; fail closed/,
    );
    assert.throws(
        () =>
            assertRecoverableInFlight(
                {
                    kind: "transaction",
                    label: "bootstrap_pool",
                    package: null,
                    startedAt: "2026-08-21T00:00:00.000Z",
                    digest: "missing-digest",
                },
                false,
            ),
        /not visible; fail closed/,
    );
});

test("every irreversible publish and transaction boundary resumes without rebroadcast", async () => {
    const transactionLabels = plannedTransactionSteps();
    const cases = [
        ...(
            [
                "fixed_math",
                "usdc",
                "account",
                "propbook",
                "predict",
                "deepbook_core_account",
                "sessions",
            ] as const
        ).map((pkg) => ({ kind: "publish" as const, label: `publish_${pkg}`, pkg })),
        ...transactionLabels.map((label) => ({
            kind: "transaction" as const,
            label,
            pkg: null,
        })),
    ];
    for (const boundary of cases) {
        const state = createDeploymentState();
        const digest = `success-${boundary.label}`;
        state.inFlight = {
            kind: boundary.kind,
            label: boundary.label,
            package: boundary.pkg,
            startedAt: "2026-08-21T00:00:00.000Z",
            digest,
        };
        let receiptReads = 0;
        let publishRecoveries = 0;
        let persists = 0;
        await reconcileJournaledInFlight(state, {
            loadReceipt: async (requestedDigest) => {
                receiptReads++;
                assert.equal(requestedDigest, digest);
                return { digest, effects: { status: { success: true } } };
            },
            recoverPublish: async (pkg) => {
                publishRecoveries++;
                state.packages[pkg] = id(`${cases.indexOf(boundary) + 1}`);
                state.publishTx[pkg] = digest;
            },
            persist: () => persists++,
        });
        assert.equal(receiptReads, 1);
        assert.equal(publishRecoveries, boundary.kind === "publish" ? 1 : 0);
        assert.equal(persists, 1);
        assert.equal(state.inFlight, null);
        assert.equal(
            irreversibleStepDigest(state, boundary.kind, boundary.label, boundary.pkg),
            digest,
        );
        assert.equal(
            await reconcileJournaledInFlight(state, {
                loadReceipt: async () =>
                    assert.fail("a completed step must not be reconciled twice"),
                recoverPublish: async () =>
                    assert.fail("a completed publish must not be recovered twice"),
                persist: () => assert.fail("a completed step must not be rewritten"),
            }),
            null,
        );
    }
});

test("manifest validation requires all seven fresh packages and mutable-state anchors", () => {
    const manifest = manifestFixture();
    assert.doesNotThrow(() => assertIntegrationManifest(manifest));
    const missingSessions = structuredClone(manifest) as unknown as Record<string, unknown>;
    delete (missingSessions.packages as Record<string, unknown>).sessions;
    assert.throws(() => assertIntegrationManifest(missingSessions), /packages keys/);
    const operatorField = structuredClone(manifest) as unknown as Record<string, unknown>;
    operatorField.deployer = id("a");
    assert.throws(() => assertIntegrationManifest(operatorField), /integration manifest keys/);
    const unauthorized = structuredClone(manifest);
    unauthorized.externalAuthorizations.deepbookCoreAccount.authorized = false;
    assert.doesNotThrow(() => assertIntegrationManifest(unauthorized));
});

test("a complete audited state generates the independent schema-8 fixture", () => {
    assert.deepEqual(buildIntegrationManifest(completeStateFixture()), manifestFixture());
});

test("a manifest cannot be generated before the chain audit completes", () => {
    assert.throws(() => buildIntegrationManifest(createDeploymentState()), /complete, verified/);
});

test("deployment completion reports pending external authorization and the no-trade window", () => {
    const state = completeStateFixture();
    state.verification!.account.deepbookCoreAuthorized = false;
    const manifest = buildIntegrationManifest(state);
    assert.equal(manifest.externalAuthorizations.deepbookCoreAccount.authorized, false);
    assert.equal(manifest.initialConfiguration.liveProtocol.noTradeWindowMs, "2000");
    assert.equal("writers" in manifest, false);
    state.verification!.protocolConfig.noTradeWindowMs = "0";
    assert.throws(() => buildIntegrationManifest(state), /ProtocolConfig/);
});

function testRuntime(result = createDeploymentState()) {
    return { result, sourceCommit: "a".repeat(40) } as Parameters<typeof executeDeployment>[0];
}

const testBindings = {
    suiVersion: "sui 1.78.1-722ac4fcf484",
    suiBinaryPath: "/test/sui",
    suiBinaryDigest: "binary",
    rpcUrl: "http://test.invalid",
    clientConfigDigest: "config",
    packageGasBudget: "5000000000",
    transactionGasBudget: "1000000000",
};

function orchestrationFixture(failAfter?: string) {
    const runtime = testRuntime();
    const mutations: string[] = [];
    const calls: string[] = [];
    const manifests: IntegrationManifest[] = [];
    let failed = false;
    let auditFails = false;
    let audits = 0;
    const persist = () => {};
    const step = async (label: string) => {
        calls.push(label);
        if (!runtime.result.transactions[label]) {
            runtime.result.transactions[label] = `tx-${label}`;
            mutations.push(label);
            if (!failed && label === failAfter) {
                failed = true;
                throw new Error(`interrupted ${label}`);
            }
        }
    };
    const ops: NonNullable<Parameters<typeof executeDeployment>[2]> = {
        writeState: persist,
        publishPackage: async (_runtime, pkg) => {
            runtime.result.packages[pkg] = id("1");
            runtime.result.publishTx[pkg] = `publish-${pkg}`;
            await step(`publish_${pkg}`);
        },
        verifyPublishedPackageCheckpoint: async (_runtime, pkg) => {
            assert.ok(runtime.result.publishTx[pkg]);
            calls.push(`verify_${pkg}`);
        },
        ensureCurrencyRegistration: async (_runtime, currency) => {
            await step(`currency_${currency}`);
            return id("1");
        },
        ensureDeployerUsdcMint: () => step("mint_usdc"),
        ensureAccountAppsAuthorized: () => step("authorize_apps"),
        ensureDeepbookCoreAppAuthorized: async () => {
            runtime.result.wiring.deepbook.coreAppAuthorized = false;
        },
        ensureLifecycleCap: async () => {
            await step("lifecycle_cap");
            return id("1");
        },
        ensureValuationCap: async () => {
            await step("valuation_cap");
            return id("2");
        },
        ensureOracleObjects: () => step("wire_empty_oracle_objects"),
        ensureUnderlyingRegistered: () => step("underlying"),
        ensureCadences: () => step("cadences"),
        ensureAccountWrapper: async () => {
            await step("account");
            return id("3");
        },
        ensureBootstrap: () => step("capitalization"),
        ensureMarkets: async () => {
            assert.ok(
                runtime.result.transactions.capitalization,
                "capitalization precedes market creation",
            );
            await step("markets");
        },
        verifyDeployment: async () => {
            audits++;
            if (auditFails) throw new Error("fresh audit rejected changed config");
            const verification = completeStateFixture().verification!;
            verification.account.deepbookCoreAuthorized = false;
            return verification;
        },
        writeIntegrationManifest: (manifest) => manifests.push(manifest),
    };
    return {
        runtime,
        ops,
        mutations,
        calls,
        manifests,
        get audits() {
            return audits;
        },
        failAudit() {
            auditFails = true;
        },
    };
}

test("the deployment orchestration completes without prices, references, authorization, or cap handoff", async () => {
    const fixture = orchestrationFixture();
    await executeDeployment(fixture.runtime, testBindings, fixture.ops);
    assert.equal(fixture.runtime.result.status, "complete");
    assert.equal(fixture.manifests.length, 1);
    assert.equal(fixture.manifests[0].externalAuthorizations.deepbookCoreAccount.authorized, false);
    assert.deepEqual(fixture.runtime.result.issuedCaps, {});
    assert.ok(fixture.calls.indexOf("capitalization") < fixture.calls.indexOf("markets"));
    assert.equal(fixture.audits, 1);
});

test("the full orchestration re-enters after every stage without repeating completed mutations", async () => {
    for (const boundary of [
        "publish_fixed_math",
        "publish_usdc",
        "publish_account",
        "publish_propbook",
        "publish_predict",
        "publish_deepbook_core_account",
        "publish_sessions",
        "currency_usdc",
        "currency_plp",
        "mint_usdc",
        "authorize_apps",
        "lifecycle_cap",
        "valuation_cap",
        "wire_empty_oracle_objects",
        "underlying",
        "cadences",
        "account",
        "capitalization",
        "markets",
    ]) {
        const fixture = orchestrationFixture(boundary);
        await assert.rejects(
            executeDeployment(fixture.runtime, testBindings, fixture.ops),
            /interrupted/,
        );
        assert.equal(fixture.manifests.length, 0, boundary);
        await executeDeployment(fixture.runtime, testBindings, fixture.ops);
        assert.equal(fixture.runtime.result.status, "complete", boundary);
        assert.equal(fixture.mutations.length, new Set(fixture.mutations).size, boundary);
        assert.equal(fixture.manifests.length, 1, boundary);
        fixture.failAudit();
        await assert.rejects(
            executeDeployment(fixture.runtime, testBindings, fixture.ops),
            /fresh audit/,
        );
        assert.equal(
            fixture.manifests.length,
            1,
            "failed re-audit must not replace the prior manifest",
        );
        assert.equal(fixture.runtime.result.verification, null);
        assert.equal(fixture.audits, 2);
    }
});

test("initial market creation needs no observations and does not recreate expired markets on resume", async () => {
    const runtime = testRuntime();
    runtime.result.packages.predict = id("4");
    runtime.result.sharedObjects.predict = {
        "registry::Registry": id("5"),
        "plp::PoolVault": id("6"),
        "protocol_config::ProtocolConfig": id("7"),
    };
    runtime.result.sharedObjects.propbook = { "registry::OracleRegistry": id("8") };
    let now = 301_000n;
    let submitted = 0;
    let interrupted = false;
    const receipts = new Map<string, Receipt>();
    const ops: NonNullable<Parameters<typeof ensureMarkets>[2]> = {
        currentClockMs: async () => now,
        discoverMarkets: async () => {},
        executeTransaction: async (_runtime, label, tx) => {
            const targets = tx
                .getData()
                .commands.map((command) => command.MoveCall?.function)
                .filter(Boolean);
            assert.deepEqual(targets, ["create_and_share_expiry_market"]);
            if (!receipts.has(label)) {
                submitted++;
                const cadence = label.includes("_5m_") ? 300_000n : 60_000n;
                receipts.set(label, {
                    digest: `tx-${label}`,
                    events: [
                        {
                            type: `${id("4")}::events::MarketCreated`,
                            parsedJson: {
                                expiry_market_id: id(String(submitted)),
                                expiry: String((now / cadence + 1n) * cadence),
                            },
                        },
                    ],
                });
                if (!interrupted) {
                    interrupted = true;
                    throw new Error("lost response");
                }
            }
            const receipt = receipts.get(label)!;
            runtime.result.transactions[label] = receipt.digest!;
            return receipt;
        },
        writeState() {},
    };
    await assert.rejects(ensureMarkets(runtime, id("9"), ops), /lost response/);
    now += 3_600_000n;
    await ensureMarkets(runtime, id("9"), ops);
    assert.equal(submitted, 4);
    assert.equal(runtime.result.wiring.markets.length, 4);
    now += 86_400_000n;
    await ensureMarkets(runtime, id("9"), ops);
    assert.equal(submitted, 4);
});

test("cap issuance requires an explicit recipient and is non-broadcasting by default", async () => {
    assert.deepEqual(parseDeploymentArgs(["issue-caps", "--recipient", id("a")]), {
        command: "issue-caps",
        execute: false,
        recipient: id("a"),
    });
    for (const args of [
        ["issue-caps"],
        ["issue-caps", "--recipient", id("0")],
        ["issue-caps", "--recipient", "bad"],
        ["--recipient", id("a")],
    ]) {
        assert.throws(() => parseDeploymentArgs(args));
    }
    assert.throws(() => assertCapsIssuanceReady(createDeploymentState(), id("a")), /completed/);
    const state = completeStateFixture();
    state.inFlight = {
        kind: "transaction",
        label: `issue_operational_caps_${id("b")}`,
        digest: "pending",
        package: null,
        startedAt: "now",
    };
    assert.throws(() => assertCapsIssuanceReady(state, id("a")), /change recipient/);
});

test("cap issuance mints and party-transfers both capabilities atomically and recovers the receipt", async () => {
    const state = completeStateFixture();
    state.packages.predict = id("4");
    state.sharedObjects.predict = {
        "registry::Registry": id("5"),
        "protocol_config::ProtocolConfig": id("6"),
    };
    state.ownedCaps.predict = { "admin::AdminCap": id("7") };
    const recipient = id("a");
    const tx = capIssuanceTransaction(state, recipient);
    assert.deepEqual(
        tx.getData().commands.map((command) => command.MoveCall?.function),
        [
            "mint_lifecycle_cap",
            "mint_pool_valuation_cap",
            "single_owner",
            "public_party_transfer",
            "single_owner",
            "public_party_transfer",
        ],
    );
    const inputs = tx.getData().inputs;
    const parties = tx
        .getData()
        .commands.filter((command) => command.MoveCall?.function === "single_owner");
    for (const party of parties) {
        const argument = party.MoveCall!.arguments[0];
        assert.equal(argument.$kind, "Input");
        if (argument.$kind !== "Input") throw new Error("party address must be an input");
        const index = argument.Input;
        assert.equal(
            inputs[index].Pure?.bytes,
            Buffer.from(recipient.slice(2), "hex").toString("base64"),
        );
    }
    const runtime = testRuntime(state);
    let broadcasts = 0;
    let failOwnerRead = true;
    const owners: string[] = [];
    const ops: NonNullable<Parameters<typeof issueOperationalCaps>[2]> = {
        executeTransaction: async (_runtime, label) => {
            if (!state.transactions[label]) {
                broadcasts++;
                state.transactions[label] = "issued";
            }
            return {
                digest: "issued",
                objectChanges: [
                    {
                        type: "created",
                        objectType: `${id("4")}::market_lifecycle_cap::MarketLifecycleCap`,
                        objectId: id("b"),
                    },
                    {
                        type: "created",
                        objectType: `${id("4")}::pool_valuation_cap::PoolValuationCap`,
                        objectId: id("c"),
                    },
                ],
            };
        },
        objectEvidence: async (_runtime, object, _type, owner) => {
            if (failOwnerRead) {
                failOwnerRead = false;
                throw new Error("owner read unavailable");
            }
            owners.push(owner!);
            return objectEvidence(object);
        },
        writeState() {},
    };
    await assert.rejects(issueOperationalCaps(runtime, recipient, ops), /owner read/);
    assert.deepEqual(state.issuedCaps, {});
    const issued = await issueOperationalCaps(runtime, recipient, ops);
    assert.equal(broadcasts, 1);
    assert.deepEqual(issued, {
        recipient,
        lifecycleCap: id("b"),
        poolValuationCap: id("c"),
        transaction: "issued",
    });
    assert.deepEqual(owners, [`party:${recipient}`, `party:${recipient}`]);
    assert.equal(state.status, "complete");
});

test("Block Scholes store-pair inspection decodes both IDs and the base asset", () => {
    const left = id("a");
    const right = id("b");
    const bytes = (value: string) => Array.from(Buffer.from(value.slice(2), "hex"));
    const baseAsset = Array.from(Buffer.from("BTC"));
    assert.deepEqual(
        parseOptionBlockScholesStorePair([
            1,
            ...bytes(left),
            ...bytes(right),
            baseAsset.length,
            ...baseAsset,
        ]),
        {
            valueStoreId: left,
            sviStoreId: right,
            baseAsset: "BTC",
        },
    );
    assert.equal(parseOptionBlockScholesStorePair([0]), null);
    assert.throws(() => parseOptionBlockScholesStorePair([1]), /invalid Option/);
});

test("stale publication recovery temporaries are removed before resume", () => {
    const directory = mkdtempSync(join(tmpdir(), "predict-publish-recovery-"));
    const temporary = join(directory, "Published.toml.recovery.tmp");
    try {
        writeFileSync(temporary, "partial");
        removeRecoveryTemporaries([temporary]);
        assert.equal(existsSync(temporary), false);
        assert.doesNotThrow(() => removeRecoveryTemporaries([temporary]));
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("only the Predict missing-underlying abort is treated as an absent registration", () => {
    const missing = new Error(
        'MoveAbort(MoveLocation { module: ModuleId { name: Identifier("market_manager") }, function_name: Some("underlying_config") }, 0) in command 0',
    );
    assert.equal(isUnderlyingNotRegisteredError(missing), true);
    assert.equal(
        isUnderlyingNotRegisteredError(
            new Error(
                'predict_underlying_registered simulation failed: {"success":false,"error":{"$kind":"MoveAbort","message":"MoveAbort in 1st command, abort code: 0, in \'0x1::market_manager::underlying_config\'","MoveAbort":{"abortCode":"0","location":{"module":"market_manager","functionName":"underlying_config"}}}}',
            ),
        ),
        true,
    );
    assert.equal(
        isUnderlyingNotRegisteredError(
            new Error(
                'MoveAbort(MoveLocation { module: ModuleId { name: Identifier("market_manager") }, function_name: Some("underlying_config") }, 1) in command 0',
            ),
        ),
        false,
    );
    assert.equal(isUnderlyingNotRegisteredError(new Error("network unavailable")), false);
});

test("published package metadata decoding preserves exact bytecode, lineage, and origins", () => {
    const packageId = id("9");
    const dependency = id("1");
    const metadata = parsePackageMetadata({
        content: {
            Package: {
                version: 1,
                module_map: { beta: [3, 4], alpha: [1, 2] },
                linkage_table: {
                    [dependency]: { upgraded_id: dependency, upgraded_version: 1 },
                },
                type_origin_table: [
                    { module_name: "alpha", datatype_name: "Thing", package: packageId },
                ],
            },
        },
    });
    assert.deepEqual(metadata, {
        packageVersion: "1",
        modules: { alpha: "AQI=", beta: "AwQ=" },
        linkage: [{ originalId: dependency, upgradedId: dependency, upgradedVersion: "1" }],
        typeOrigins: [{ module: "alpha", datatype: "Thing", packageId }],
    });
    const compiled = {
        modules: ["AQI=", "AwQ="],
        dependencies: [dependency],
        typeOrigins: [{ module: "alpha", datatype: "Thing" }],
    };
    assert.doesNotThrow(() =>
        assertExactPackageGraph("fixture", packageId, compiled, metadata, () => ({
            originalId: dependency,
            upgradedVersion: "1",
        })),
    );
    assert.throws(
        () =>
            assertExactPackageGraph(
                "fixture",
                packageId,
                { ...compiled, dependencies: [] },
                metadata,
                () => ({ originalId: dependency, upgradedVersion: "1" }),
            ),
        /linkage does not match/,
    );
    assert.throws(
        () =>
            assertExactPackageGraph("fixture", packageId, compiled, metadata, () => ({
                originalId: id("2"),
                upgradedVersion: "2",
            })),
        /original\/version/,
    );
    const movedOrigin = structuredClone(metadata);
    movedOrigin.typeOrigins[0].packageId = id("8");
    assert.throws(
        () =>
            assertExactPackageGraph("fixture", packageId, compiled, movedOrigin, () => ({
                originalId: dependency,
                upgradedVersion: "1",
            })),
        /type origins do not match/,
    );
    assert.equal(
        sameObjectReference(
            {
                objectId: id("1"),
                type: "x",
                owner: "shared",
                version: "1",
                digest: "a",
                previousTransaction: null,
            },
            {
                objectId: id("1"),
                type: "y",
                owner: "shared",
                version: "1",
                digest: "a",
                previousTransaction: "tx",
            },
        ),
        true,
    );
});

test("network and deployer are explicit and invalid targets fail before wallet access", () => {
    for (const args of [
        [],
        ["--network", "mainnet"],
        ["--network", "devnet", "--deployer", id("a")],
        ["--network", "mainnet", "--deployer", id("0")],
    ]) {
        assert.throws(() => parseTargetArgs(args));
    }
    assert.deepEqual(
        parseTargetArgs(["--network", "mainnet", "--deployer", id("a"), "--execute"]),
        {
            network: "mainnet",
            deployer: id("a"),
            remaining: ["--execute"],
        },
    );
    assert.throws(() => configureDeployment("mainnet", ""));
    assert.throws(() => configureDeployment("mainnet", id("0")));
});

test("Mainnet publishes six packages, retains Testnet identities, and cannot mint USDC or supply LP capital", () => {
    try {
        configureDeployment("mainnet", id("a"));
        const state = createDeploymentState();
        assert.equal(state.chainId, "35834a8a");
        assert.equal(state.deployer, id("a"));
        assert.equal(state.wiring.currencies.usdc.mintedAmount, "0");
        assert.equal(state.wiring.bootstrap.supplyAmount, "0");
        assert.equal(state.wiring.bootstrap.lockCapitalAmount, "10000000");
        assert.deepEqual(
            irreversibleDeploymentSteps().filter((step) => step.startsWith("publish_")),
            [
                "publish_fixed_math",
                "publish_account",
                "publish_propbook",
                "publish_predict",
                "publish_deepbook_core_account",
                "publish_sessions",
            ],
        );
        const steps = plannedTransactionSteps();
        for (const forbidden of [
            "mint_deployer_usdc",
            "finalize_usdc_currency_registration",
            "create_deployer_account",
        ])
            assert.equal(steps.includes(forbidden), false);
        assertPackagePlan();
        assertDeploymentTarget("mainnet", "35834a8a", id("a"));
        assert.throws(() => assertDeploymentTarget("testnet", "4c78adac", id("a")));
        const existing = '[published.testnet]\nchain-id = "4c78adac"\npublished-at = "0x1"\n';
        const merged = mergePublishedMetadata(existing, publishedMetadataText(id("1"), id("2")));
        assert.ok(merged.startsWith(existing.trimEnd()));
        assert.equal(merged.split("[published.mainnet]").length, 2);
        assert.equal(
            mergePublishedMetadata(merged, publishedMetadataText(id("1"), id("2"))).split(
                "[published.mainnet]",
            ).length,
            2,
        );
        assert.equal(MANIFEST_RELATIVE, "packages/predict/deployment/deployment.mainnet.json");
    } finally {
        configureDeployment("testnet", id("a"));
    }
    assert.equal(
        createDeploymentState().linked.pyth_lazer,
        "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
    );
});

function lockRuntime() {
    const runtime = testRuntime();
    runtime.result.packages.predict = id("4");
    runtime.result.sharedObjects.predict = {
        "plp::PoolVault": id("5"),
        "protocol_config::ProtocolConfig": id("6"),
    };
    runtime.result.ownedCaps.predict = { "admin::AdminCap": id("7") };
    return runtime;
}

test("Mainnet lock transaction consumes native USDC and only calls lock_capital", () => {
    try {
        configureDeployment("mainnet", id("a"));
        const runtime = lockRuntime();
        const tx = lockedCapitalTransaction(runtime.result);
        const data = tx.getData();
        assert.deepEqual(
            data.commands
                .filter((command) => command.MoveCall)
                .map((command) => command.MoveCall?.function),
            ["lock_capital"],
        );
        const intent = data.commands.find((command) => command.$Intent)?.$Intent;
        assert.equal(intent?.data.type, `${MAINNET_USDC}::usdc::USDC`);
        assert.equal(String(intent?.data.balance), "10000000");
    } finally {
        configureDeployment("testnet", id("a"));
    }
});

test("Mainnet lock-only audit validates the exact event and rejects LP supply events", () => {
    const receipt: Receipt = {
        digest: "lock",
        events: [
            {
                type: `${id("4")}::vault_events::CapitalLocked`,
                parsedJson: { pool_vault_id: id("5"), amount: "10000000" },
            },
        ],
    };
    validateLockedCapitalReceipt(receipt, id("5"), id("4"));
    for (const invalid of [
        { ...receipt, events: [] },
        { ...receipt, events: [...receipt.events!, ...receipt.events!] },
        {
            ...receipt,
            events: [
                {
                    type: `${id("4")}::vault_events::CapitalLocked`,
                    parsedJson: { pool_vault_id: id("5"), amount: "10000001" },
                },
            ],
        },
        {
            ...receipt,
            events: [...receipt.events!, { type: `${id("4")}::vault_events::SupplyRequested` }],
        },
    ])
        assert.throws(() => validateLockedCapitalReceipt(invalid, id("5"), id("4")));
    assert.throws(() => validateLockedCapitalReceipt(receipt, id("6"), id("4")));
    assert.throws(() => validateLockedCapitalReceipt(receipt, id("5"), id("9")));
});

test("lock-only bootstrap recovers a lost response and read failures without a second lock", async () => {
    try {
        configureDeployment("mainnet", id("a"));
        for (const failure of ["after-submit", "pool-read", "receipt-read", "checkpoint"]) {
            const runtime = lockRuntime();
            let supply = 0n;
            let broadcasts = 0;
            let failed = false;
            const fail = (stage: string) => {
                if (failure === stage && !failed) {
                    failed = true;
                    throw new Error(`interrupted ${stage}`);
                }
            };
            const receipt: Receipt = {
                digest: "lock",
                events: [
                    {
                        type: `${id("4")}::vault_events::CapitalLocked`,
                        parsedJson: { pool_vault_id: id("5"), amount: "10000000" },
                    },
                ],
            };
            const ops: NonNullable<Parameters<typeof ensureLockedCapital>[2]> = {
                poolU64: async (_runtime, fn) => {
                    if (supply > 0n) fail("pool-read");
                    return fn === "plp_total_supply" || fn === "idle_balance" ? supply : 0n;
                },
                executeTransaction: async (_runtime, label) => {
                    broadcasts++;
                    supply = 10000000n;
                    runtime.result.transactions[label] = "lock";
                    fail("after-submit");
                    return receipt;
                },
                settledReceipt: async () => {
                    fail("receipt-read");
                    return receipt;
                },
                writeState: () => fail("checkpoint"),
            };
            await assert.rejects(ensureLockedCapital(runtime, false, ops), /interrupted/);
            await ensureLockedCapital(runtime, false, ops);
            await ensureLockedCapital(runtime, true, ops);
            assert.equal(broadcasts, 1, failure);
            assert.equal(runtime.result.wiring.bootstrap.accountId, null);
            assert.equal(runtime.result.wiring.bootstrap.sharesMinted, "0");
            assert.equal(runtime.result.wiring.bootstrap.lockCapitalTx, "lock");
        }
        const runtime = lockRuntime();
        let broadcast = false;
        const ops: NonNullable<Parameters<typeof ensureLockedCapital>[2]> = {
            poolU64: async () => 0n,
            executeTransaction: async () => {
                broadcast = true;
                throw new Error("unexpected");
            },
            settledReceipt: async () => ({ digest: "none" }),
            writeState() {},
        };
        await assert.rejects(
            ensureLockedCapital(runtime, true, ops),
            /requires its recorded receipt/,
        );
        assert.equal(broadcast, false);
    } finally {
        configureDeployment("testnet", id("a"));
    }
});

function mainnetVerificationFixture() {
    const verification = completeStateFixture().verification!;
    verification.chainId = "35834a8a";
    delete verification.packages.usdc;
    verification.linkedPackages = {
        deepbook: objectEvidence(
            "0x0e735f8c93a95722efd73521aca7a7652c0bb71ed1daf41b26dfd7d1ff71f748",
        ),
        deep: objectEvidence("0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270"),
        pyth_lazer: objectEvidence(
            "0xefbfd064480777699fd9c557a5804d72ace7bc82661fdc8d1f1a44ea6d92ee10",
        ),
        wormhole: objectEvidence(
            "0x5306f64e312b581766351c07af79c72fcb1cd25147157fdc2f8ad76de9a3fb6a",
        ),
        bs_oracle: objectEvidence(
            "0xa408bcdeb8e7607b1cbb92c088147d61664a6255a3ea5696a8fef44711e113d8",
        ),
        bs_sid: objectEvidence(
            "0xdacaf624c4802c9ff7b8c72447207f5078b78be246f78e143d63e6cd89b4f63d",
        ),
        usdc: objectEvidence("0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7"),
    };
    verification.linkedObjects.pythLazerState.objectId =
        "0xd0db9c1e9212a98120384bf78d8b8c985d87b9ee6921dffcf9d1394062911573";
    verification.linkedObjects.wormholeState.objectId =
        "0xaeab97f96cf9877fee2883315d459552b2b921edc16d7ceac6eab944dd88919c";
    verification.linkedObjects.blockScholesSignerRegistry.objectId =
        "0xc578b6058b0ba9cf2254962168cd779593805c4f10f80aef8749df75ef7fc0e5";
    verification.linkedObjects.deepbookRegistry.objectId =
        "0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d";
    verification.currencies.usdc = objectEvidence(
        "0x75cfbbf8c962d542e99a1d15731e6069f60a00db895407785b15d14f606f2b4a",
    );
    verification.currencies.mintedAmount = "0";
    verification.currencies.deployerBalance = "0";
    verification.account.accountWrapper = null;
    verification.pool.totalSupply = "10000000";
    verification.pool.idleBalance = "10000000";
    verification.pool.deployerAccountPlpBalance = "0";
    return verification;
}

test("Mainnet orchestration resumes each stage and never calls mint, LP-account creation, or root-cap handoff", async () => {
    try {
        configureDeployment("mainnet", id("a"));
        for (const boundary of [
            "publish_fixed_math",
            "publish_account",
            "publish_propbook",
            "publish_predict",
            "publish_deepbook_core_account",
            "publish_sessions",
            "currency_plp",
            "authorize_apps",
            "lifecycle_cap",
            "valuation_cap",
            "wire_empty_oracle_objects",
            "underlying",
            "cadences",
            "capitalization",
            "markets",
        ]) {
            const fixture = orchestrationFixture(boundary);
            fixture.ops.ensureDeployerUsdcMint = async () => {
                throw new Error("forbidden USDC mint");
            };
            fixture.ops.ensureAccountWrapper = async () => {
                throw new Error("forbidden LP bootstrap account");
            };
            const currency = fixture.ops.ensureCurrencyRegistration;
            fixture.ops.ensureCurrencyRegistration = async (runtime, name) =>
                name === "usdc"
                    ? "0x75cfbbf8c962d542e99a1d15731e6069f60a00db895407785b15d14f606f2b4a"
                    : currency(runtime, name);
            fixture.ops.verifyDeployment = async () => mainnetVerificationFixture();
            await assert.rejects(
                executeDeployment(fixture.runtime, testBindings, fixture.ops),
                /interrupted/,
                boundary,
            );
            assert.equal(fixture.manifests.length, 0);
            await executeDeployment(fixture.runtime, testBindings, fixture.ops);
            assert.equal(fixture.runtime.result.status, "complete", boundary);
            assert.equal(fixture.mutations.length, new Set(fixture.mutations).size, boundary);
            assert.deepEqual(fixture.runtime.result.issuedCaps, {});
            assert.equal(fixture.manifests[0].schemaVersion, 9);
            assert.equal(fixture.manifests[0].objects.usdcCurrency, null);
            assert.equal(
                fixture.manifests[0].objects.usdcCoinMetadata,
                "0x75cfbbf8c962d542e99a1d15731e6069f60a00db895407785b15d14f606f2b4a",
            );
        }
    } finally {
        configureDeployment("testnet", id("a"));
    }
});

test("Mainnet gas funding rejects coin-only SUI because transactions use address-balance gas", async () => {
    try {
        configureDeployment("mainnet", id("a"));
        assert.equal(availableGasBalance({ balance: "10000000000", addressBalance: "0" }), 0n);
        const runtime = testRuntime();
        runtime.client = {
            getBalance: async () => ({ balance: { balance: "999999999999", addressBalance: "0" } }),
        } as unknown as typeof runtime.client;
        await assert.rejects(assertGasFunding(runtime), /insufficient deployer SUI gas: have 0/);
    } finally {
        configureDeployment("testnet", id("a"));
    }
    assert.equal(
        availableGasBalance({ balance: "10000000000", addressBalance: "0" }),
        10000000000n,
    );
});

test("DEEP resolution uses the module identity instead of an incidental token directory suffix", () => {
    const directory = mkdtempSync(join(tmpdir(), "predict-deep-resolution-"));
    try {
        mkdirSync(join(directory, "token"));
        writeFileSync(
            join(directory, "token", "deep.json"),
            JSON.stringify({ module_name: [id("1"), "deep"] }),
        );
        assert.equal(resolvedModuleAddress(directory, "deep.json"), id("1"));
        mkdirSync(join(directory, "token_2"));
        writeFileSync(
            join(directory, "token_2", "deep.json"),
            JSON.stringify({ module_name: [id("2"), "deep"] }),
        );
        assert.throws(() => resolvedModuleAddress(directory, "deep.json"), /exactly one/);
        assert.throws(() => resolvedModuleAddress(directory, "missing.json"), /exactly one/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});
