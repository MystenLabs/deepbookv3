// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
    CADENCES,
    EXPECTED_PROTOCOL_CONFIG,
    MANIFEST_RELATIVE,
    STATE_RELATIVE,
    assertDeploymentTarget,
    assertExactPackageGraph,
    assertExecutionBindings,
    assertNoKeystoreOverride,
    assertIntegrationManifest,
    assertMatchingSid,
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
    type IntegrationManifest,
} from "./deploy.ts";

const id = (digit: string) => `0x${digit.repeat(64)}`;

function manifestFixture(): IntegrationManifest {
    const predict = id("4");
    const usdc = id("2");
    return {
        schemaVersion: 7,
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
        writers: {
            keeper: {
                address: "0xff241a369609060d3f34828b97a47a2d330644615ff57dfdd49f4f0dd299207f",
                lifecycleCap: id("1"),
                poolValuationCap: id("2"),
            },
            priceUpdater: {
                address: "0x921e2bd3432c784dce15b4073ba666d5067e6f8a41704eb63555235fec2e2e41",
                pythLazerPackage:
                    "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
                pythLazerState:
                    "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
                blockScholesOraclePackage:
                    "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
                blockScholesSignerRegistry:
                    "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
            },
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
            pyth_lazer: objectEvidence(manifest.writers.priceUpdater.pythLazerPackage),
            wormhole: objectEvidence(
                "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
            ),
            bs_oracle: objectEvidence(manifest.writers.priceUpdater.blockScholesOraclePackage),
            bs_sid: objectEvidence(
                "0x6a54299d593fca24edf6b17bf8c3aff0b7ba8bc8f4276e9c1065689c50223bba",
            ),
        },
        linkedObjects: {
            clock: objectEvidence(manifest.objects.clock),
            accumulatorRoot: objectEvidence(manifest.objects.accumulatorRoot),
            pythLazerState: objectEvidence(manifest.writers.priceUpdater.pythLazerState),
            wormholeState: objectEvidence(
                "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
            ),
            blockScholesSignerRegistry: objectEvidence(
                manifest.writers.priceUpdater.blockScholesSignerRegistry,
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
            usdc: objectEvidence(manifest.objects.usdcCurrency),
            plp: objectEvidence(manifest.objects.plpCurrency),
            mintedAmount: "100000000000000",
            deployerBalance: "99749990000000",
        },
        lifecycleCap: objectEvidence(manifest.writers.keeper.lifecycleCap),
        valuationCap: objectEvidence(manifest.writers.keeper.poolValuationCap),
        oracleReadiness: [],
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
    assert.deepEqual(parseDeploymentArgs([]), { execute: false, sessions: false, smoke: false });
    assert.deepEqual(parseDeploymentArgs(["--execute"]), {
        execute: true,
        sessions: false,
        smoke: false,
    });
    assert.throws(() => parseDeploymentArgs(["--sessions"]), /unknown deployment arguments/);
    assert.throws(() => parseDeploymentArgs(["--smoke"]), /unknown deployment arguments/);
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
    assert.match(gitignore, new RegExp(`^${STATE_RELATIVE}$`, "m"));
    assert.match(gitignore, new RegExp(`^${STATE_RELATIVE}\\.tmp$`, "m"));
    assert.match(gitignore, new RegExp(`^${MANIFEST_RELATIVE}\\.tmp$`, "m"));
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
    assert.equal(state.wiring.lifecycleCap.recipient, state.wiring.valuationCap.recipient);
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
    assert.equal(plannedTransactionCount(), 28);
    assert.equal(maximumTransactionCountPerRun(), 40);
    assert.equal(irreversibleDeploymentSteps().length, 35);
});

test("target, toolchain, source, and worktree bindings fail closed", () => {
    assert.doesNotThrow(() =>
        assertDeploymentTarget(
            "testnet",
            "4c78adac",
            "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef",
        ),
    );
    assert.throws(
        () =>
            assertDeploymentTarget(
                "mainnet",
                "4c78adac",
                "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef",
            ),
        /deployment target/,
    );
    assert.throws(() => assertDeploymentTarget("testnet", "bad", id("a")), /deployment target/);
    assert.doesNotThrow(() => assertSuiCliVersion("sui 1.77.1-4e476c5c8184"));
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
        suiVersion: "sui 1.77.1-4e476c5c8184",
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
toolchain-version = "1.77.1"
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
    const runtimeMarketIds = CADENCES.filter((cadence) => cadence.marketsToCreate > 0).flatMap(
        (cadence) =>
            Array.from({ length: cadence.marketsToCreate }, (_, index) =>
                id(`${cadence.id + 1}${index + 1}`),
            ),
    );
    const transactionLabels = [
        ...plannedTransactionSteps().filter(
            (label) =>
                !label.startsWith("set_reference_tick_") && !label.startsWith("rebalance_market_"),
        ),
        ...runtimeMarketIds.map((marketId) => `set_reference_tick_${marketId}`),
        ...runtimeMarketIds.map((marketId) => `rebalance_market_${marketId}`),
    ];
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
    assert.throws(() => assertIntegrationManifest(unauthorized), /externalAuthorizations/);
});

test("a complete audited state generates the independent schema-7 fixture", () => {
    assert.deepEqual(buildIntegrationManifest(completeStateFixture()), manifestFixture());
});

test("a manifest cannot be generated before the chain audit completes", () => {
    assert.throws(() => buildIntegrationManifest(createDeploymentState()), /complete, verified/);
});

test("Block Scholes SID parity fails closed", () => {
    assert.doesNotThrow(() => assertMatchingSid("BTC spot", 7n, 7n));
    assert.throws(() => assertMatchingSid("BTC spot", 7n, 8n), /subscription derives/);
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
