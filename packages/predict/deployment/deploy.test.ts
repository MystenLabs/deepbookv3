// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
    CADENCES,
    EXPECTED_PROTOCOL_CONFIG,
    MANIFEST_RELATIVE,
    STATE_RELATIVE,
    assertIntegrationManifest,
    assertPackagePlan,
    buildIntegrationManifest,
    createDeploymentState,
    parseDeploymentArgs,
    parseOptionBlockScholesStorePair,
    parsePackageMetadata,
    type IntegrationManifest,
} from "./deploy.ts";

const id = (digit: string) => `0x${digit.repeat(64)}`;

function manifestFixture(): IntegrationManifest {
    const predict = id("4");
    return {
        schemaVersion: 6,
        deployment: "predict-testnet-8-21",
        network: "testnet",
        chainId: "4c78adac",
        sourceCommit: "a".repeat(40),
        packages: {
            fixedMath: id("1"),
            account: id("2"),
            propbook: id("3"),
            predict,
            deepbookCoreAccount: id("5"),
            sessions: id("6"),
        },
        coinTypes: {
            dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC",
            deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP",
            plp: `${predict}::plp::PLP`,
        },
        objects: {
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
            keeper: { lifecycleCap: id("1") },
            priceUpdater: {
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
        indexing: { startCheckpoint: "1" },
        initialConfiguration: {
            verifiedAfterCheckpoint: "2",
            stateAnchors: {
                protocolConfig: { objectVersion: "1", digest: "protocol" },
                registry: { objectVersion: "1", digest: "registry" },
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

test("the default invocation is non-broadcasting", () => {
    assert.deepEqual(parseDeploymentArgs([]), { execute: false, sessions: false, smoke: false });
    assert.deepEqual(parseDeploymentArgs(["--execute"]), {
        execute: true,
        sessions: false,
        smoke: false,
    });
    assert.throws(() => parseDeploymentArgs(["--sessions"]), /unknown deployment arguments/);
    assert.throws(() => parseDeploymentArgs(["--smoke"]), /unknown deployment arguments/);
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
    assert.deepEqual(
        CADENCES.map(
            ({ name, tickSize, admissionTickSize, maxExpiryAllocation, initialExpiryCash, windowSize }) => ({
            name,
            tickSize: tickSize.toString(),
            admissionTickSize: admissionTickSize.toString(),
            maxExpiryAllocation: maxExpiryAllocation.toString(),
            initialExpiryCash: initialExpiryCash.toString(),
            windowSize: windowSize.toString(),
            }),
        ),
        [
            { name: "1m", tickSize: "10000000", admissionTickSize: "1000000000", maxExpiryAllocation: "50000000000", initialExpiryCash: "10000000000", windowSize: "2" },
            { name: "5m", tickSize: "10000000", admissionTickSize: "1000000000", maxExpiryAllocation: "50000000000", initialExpiryCash: "10000000000", windowSize: "2" },
            { name: "1h", tickSize: "10000000", admissionTickSize: "1000000000", maxExpiryAllocation: "250000000000", initialExpiryCash: "50000000000", windowSize: "2" },
            { name: "1d", tickSize: "10000000", admissionTickSize: "100000000000", maxExpiryAllocation: "250000000000", initialExpiryCash: "50000000000", windowSize: "2" },
            { name: "1w", tickSize: "10000000", admissionTickSize: "100000000000", maxExpiryAllocation: "250000000000", initialExpiryCash: "50000000000", windowSize: "2" },
            { name: "1mo", tickSize: "0", admissionTickSize: "0", maxExpiryAllocation: "0", initialExpiryCash: "0", windowSize: "0" },
        ],
    );
    const state = createDeploymentState();
    assert.equal(state.wiring.bootstrap.lockCapitalAmount, "10000000");
    assert.equal(state.wiring.bootstrap.supplyAmount, "1500000000000");
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
                "fixed_math",
            ]),
        /planned before local dependency/,
    );
});

test("manifest validation requires all six fresh packages and mutable-state anchors", () => {
    const manifest = manifestFixture();
    assert.doesNotThrow(() => assertIntegrationManifest(manifest));
    const missingSessions = structuredClone(manifest) as unknown as Record<string, unknown>;
    delete (missingSessions.packages as Record<string, unknown>).sessions;
    assert.throws(() => assertIntegrationManifest(missingSessions), /packages keys/);
    const operatorField = structuredClone(manifest) as unknown as Record<string, unknown>;
    operatorField.deployer = id("a");
    assert.throws(() => assertIntegrationManifest(operatorField), /integration manifest keys/);
});

test("a manifest cannot be generated before the chain audit completes", () => {
    assert.throws(() => buildIntegrationManifest(createDeploymentState()), /complete, verified/);
});

test("Block Scholes store-pair inspection decodes both IDs", () => {
    const left = id("a");
    const right = id("b");
    const bytes = (value: string) => Array.from(Buffer.from(value.slice(2), "hex"));
    assert.deepEqual(parseOptionBlockScholesStorePair([1, ...bytes(left), ...bytes(right)]), {
        valueStoreId: left,
        sviStoreId: right,
    });
    assert.equal(parseOptionBlockScholesStorePair([0]), null);
    assert.throws(() => parseOptionBlockScholesStorePair([1]), /invalid Option/);
});

test("published package metadata decoding keeps module and dependency identity", () => {
    assert.deepEqual(
        parsePackageMetadata({
            data: {
                content: {
                    disassembled: { beta: {}, alpha: {} },
                    linkageTable: {
                        one: { upgradedId: "0x1" },
                        two: { originalId: "0x2" },
                    },
                },
            },
        }),
        {
            modules: ["alpha", "beta"],
            dependencies: [
                "0x0000000000000000000000000000000000000000000000000000000000000001",
                "0x0000000000000000000000000000000000000000000000000000000000000002",
            ],
        },
    );
});
