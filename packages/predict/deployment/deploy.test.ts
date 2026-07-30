// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
    MANIFEST_RELATIVE,
    STATE_RELATIVE,
    assertIntegrationManifest,
    buildIntegrationManifest,
    createDeploymentState,
    type DeploymentResult,
    type IntegrationManifest,
} from "./deploy.ts";

const manifest = JSON.parse(
    readFileSync(new URL("deployment.testnet.json", import.meta.url), "utf8"),
) as unknown;

function evidence(objectId: string, version = "1", digest = "test") {
    return {
        objectId,
        type: "test",
        owner: "test",
        version,
        digest,
        previousTransaction: null,
    };
}

function publishedAt(packageName: string): string {
    const text = readFileSync(
        new URL(`../../${packageName}/Published.toml`, import.meta.url),
        "utf8",
    );
    const section = text.match(/\[published\.testnet\]([\s\S]*?)(?=\n\[|$)/)?.[1];
    const published = section?.match(/^published-at\s*=\s*"([^"]+)"$/m)?.[1];
    assert.ok(published, `${packageName} has a Testnet publication record`);
    return published;
}

const FIXTURE = {
    sourceCommit: "4c3c62c66196f9ba1cf628c9346e1b4eba1af396",
    chainId: "4c78adac",
    indexingStartCheckpoint: "365866186",
    verifiedAfterCheckpoint: "365866439",
    packages: {
        fixed_math: "0xd81b1e5a28d616b8ff9eeda2241866ece02767fc4f368bec23b8eb57334f3d2d",
        account: "0xdabedf28ee547a20cb4ed30d4ff3dab686ff2926add584822466efded14cec4a",
        propbook: "0x756ab217b8b7cbbe7a9e45a5cc385347cb43f74aac0102772336a24cf48ab9cb",
        predict: "0xd94387c857ab56857f5f2750f2ba959fb007306f977a24290342433aef090298",
    },
    linkedPackages: {
        dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
        deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
        pyth_lazer: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
        wormhole: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
        bs_oracle: "0x87cc43db9b6c1e8b174841221e8e4bde5ab8fc8aaffacc58699c77e9e6340ff6",
    },
    linkedObjects: {
        clock: "0x0000000000000000000000000000000000000000000000000000000000000006",
        accumulatorRoot: "0x0000000000000000000000000000000000000000000000000000000000000acc",
        pythLazerState: "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
        wormholeState: "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
        blockScholesSignerRegistry:
            "0xe1198f0add6ba5286d23f2790818937e4a629b95a86e98b1ece93c0ef3c2c440",
    },
    sharedObjects: {
        accountRegistry: "0x316fa986a919b2f69884bfeec2a8668bf671a4d05c1c434ad6d9647a41d2ccb2",
        oracleRegistry: "0xec1a1aa6aeffb45aae40cba097714e711acc28739faa005e1932de608189667f",
        protocolConfig: {
            objectId: "0x19a07f5be96ca7b47e8b2ec39d7caf40e1fbb7d4156a699bfecda807d1d3d427",
            version: "958699678",
            digest: "BAF23CngnXzpL778fxV174XQU2SqZA2YuuZ478xZZums",
        },
        poolVault: "0x90454f005b8eca464317ffb31adf5e39da94a9304b11b9501d5668d0103bbb0a",
        registry: {
            objectId: "0xafc24283eec35728da1184eea118c41067bbde153447f9946e0667672f18a383",
            version: "958700059",
            digest: "Dpe43QX82TAxgEVXsoEBnfZG5WSLf8d4GYaVxcFoM16M",
        },
    },
    oracleObjects: {
        pythFeed: "0x980be0a52ea3f1e5243d5d5cd116c4de9107abb07fdbe134314996302a97c524",
        blockScholesValueStore:
            "0x24b684a5f9168bbe792e1e10aece0353e5e5f8f9be3d07acded253644f1c3d4c",
        blockScholesSviStore: "0x8400d1ea44291177bd02ff33d49be5785cc809cdf280f7e2f05f72866af05dca",
    },
    lifecycleCap: "0x1f88aac230dc8bccf82c537d987bad6cdab0c438fa81884365b6ec6345f74240",
    protocolConfig: {
        usePythSpotForForward: true,
        pythSpotFreshnessMs: "10000",
        blockScholesPriceFreshnessMs: "10000",
        blockScholesSviFreshnessMs: "60000",
        ewmaAlpha: "10000000",
        ewmaZScoreThreshold: "3000000000",
        ewmaPenaltyRate: "1000000",
        ewmaEnabled: false,
        lowerBenefitPower: "100000000000",
        upperBenefitPower: "1100000000000",
        protocolReserveProfitShare: "400000000",
        tradeLiquidationBudget: "24",
        liquidationLtv: "850000000",
        maxAdmissionLeverage: "3000000000",
        backingBufferLambda: "250000000",
        baseFee: "20000000",
        minFee: "5000000",
        minEntryProbability: "10000000",
        maxEntryProbability: "990000000",
        expiryFeeWindowMs: "86400000",
        expiryFeeMaxMultiplier: "1000000000",
        noLeverageWindowMs: "3600000",
        tradingLossRebateRate: "500000000",
        versionWatermark: "1",
        tradingPaused: false,
        frozen: false,
        valuationInProgress: false,
    },
    cadences: [
        {
            id: 0,
            name: "1m",
            tickSize: "10000000",
            admissionTickSize: "1000000000",
            maxExpiryAllocation: "50000000000",
            initialExpiryCash: "10000000000",
            windowSize: "3",
        },
        {
            id: 1,
            name: "5m",
            tickSize: "10000000",
            admissionTickSize: "1000000000",
            maxExpiryAllocation: "50000000000",
            initialExpiryCash: "10000000000",
            windowSize: "3",
        },
        {
            id: 2,
            name: "1h",
            tickSize: "10000000",
            admissionTickSize: "1000000000",
            maxExpiryAllocation: "250000000000",
            initialExpiryCash: "50000000000",
            windowSize: "3",
        },
        {
            id: 3,
            name: "1d",
            tickSize: "0",
            admissionTickSize: "0",
            maxExpiryAllocation: "0",
            initialExpiryCash: "0",
            windowSize: "0",
        },
        {
            id: 4,
            name: "1w",
            tickSize: "0",
            admissionTickSize: "0",
            maxExpiryAllocation: "0",
            initialExpiryCash: "0",
            windowSize: "0",
        },
        {
            id: 5,
            name: "1mo",
            tickSize: "0",
            admissionTickSize: "0",
            maxExpiryAllocation: "0",
            initialExpiryCash: "0",
            windowSize: "0",
        },
    ],
} as const;

function verifiedState(): DeploymentResult {
    const state = createDeploymentState();
    state.status = "complete";
    state.sourceCommit = FIXTURE.sourceCommit;
    state.startedAt = "2026-07-30T01:35:29.616Z";
    state.completedAt = "2026-07-30T01:36:38.607Z";
    state.packages = { ...FIXTURE.packages };
    state.verification = {
        verifiedAt: state.completedAt,
        chainId: FIXTURE.chainId,
        indexingStartCheckpoint: FIXTURE.indexingStartCheckpoint,
        verifiedAfterCheckpoint: FIXTURE.verifiedAfterCheckpoint,
        packages: {
            fixed_math: evidence(FIXTURE.packages.fixed_math),
            account: evidence(FIXTURE.packages.account),
            propbook: evidence(FIXTURE.packages.propbook),
            predict: evidence(FIXTURE.packages.predict),
        },
        linkedPackages: {
            dusdc: evidence(FIXTURE.linkedPackages.dusdc),
            deep: evidence(FIXTURE.linkedPackages.deep),
            pyth_lazer: evidence(FIXTURE.linkedPackages.pyth_lazer),
            wormhole: evidence(FIXTURE.linkedPackages.wormhole),
            bs_oracle: evidence(FIXTURE.linkedPackages.bs_oracle),
        },
        linkedObjects: {
            clock: evidence(FIXTURE.linkedObjects.clock),
            accumulatorRoot: evidence(FIXTURE.linkedObjects.accumulatorRoot),
            pythLazerState: evidence(FIXTURE.linkedObjects.pythLazerState),
            wormholeState: evidence(FIXTURE.linkedObjects.wormholeState),
            blockScholesSignerRegistry: evidence(FIXTURE.linkedObjects.blockScholesSignerRegistry),
        },
        sharedObjects: {
            account: {
                "account_registry::AccountRegistry": evidence(
                    FIXTURE.sharedObjects.accountRegistry,
                ),
            },
            propbook: {
                "registry::OracleRegistry": evidence(FIXTURE.sharedObjects.oracleRegistry),
            },
            predict: {
                "protocol_config::ProtocolConfig": evidence(
                    FIXTURE.sharedObjects.protocolConfig.objectId,
                    FIXTURE.sharedObjects.protocolConfig.version,
                    FIXTURE.sharedObjects.protocolConfig.digest,
                ),
                "plp::PoolVault": evidence(FIXTURE.sharedObjects.poolVault),
                "registry::Registry": evidence(
                    FIXTURE.sharedObjects.registry.objectId,
                    FIXTURE.sharedObjects.registry.version,
                    FIXTURE.sharedObjects.registry.digest,
                ),
            },
        },
        ownedCaps: {},
        oracleObjects: {
            pythFeed: evidence(FIXTURE.oracleObjects.pythFeed),
            blockScholesValueStore: evidence(FIXTURE.oracleObjects.blockScholesValueStore),
            blockScholesSviStore: evidence(FIXTURE.oracleObjects.blockScholesSviStore),
        },
        account: {
            predictAppAuthorized: true,
            accountWrapper: evidence(FIXTURE.sharedObjects.accountRegistry),
        },
        lifecycleCap: evidence(FIXTURE.lifecycleCap),
        cadences: FIXTURE.cadences.map((cadence) => ({
            ...cadence,
            setTx: null,
        })),
        protocolConfig: { ...FIXTURE.protocolConfig },
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

test("operator state and integration manifest are separate artifacts", () => {
    assert.notEqual(STATE_RELATIVE, MANIFEST_RELATIVE);
    assert.match(STATE_RELATIVE, /\.state\.json$/);
    assert.equal(MANIFEST_RELATIVE.endsWith(".state.json"), false);
    const gitignore = readFileSync(new URL("../../../.gitignore", import.meta.url), "utf8");
    assert.match(gitignore, new RegExp(`^${STATE_RELATIVE}$`, "m"));
});

test("the committed integration manifest has the stable public schema", () => {
    assertIntegrationManifest(manifest);
    const value = manifest as IntegrationManifest;
    assert.deepEqual(Object.keys(value), [
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
        "indexing",
        "initialConfiguration",
    ]);
    for (const internalKey of [
        "deployer",
        "publishTx",
        "transactions",
        "ownedCaps",
        "bootstrap",
        "markets",
        "verification",
    ]) {
        assert.equal(internalKey in value, false);
    }
    assert.deepEqual(value.initialConfiguration.units, {
        fixedPointScale: "1000000000",
        quoteCoinDecimals: 6,
        plpCoinDecimals: 6,
        deepCoinDecimals: 6,
        positionQuantityDecimals: 6,
        positionLotSize: "10000",
        timestampUnit: "milliseconds",
    });
    assert.deepEqual(value.initialConfiguration.stateAnchors, {
        protocolConfig: {
            objectVersion: FIXTURE.sharedObjects.protocolConfig.version,
            digest: FIXTURE.sharedObjects.protocolConfig.digest,
        },
        registry: {
            objectVersion: FIXTURE.sharedObjects.registry.version,
            digest: FIXTURE.sharedObjects.registry.digest,
        },
    });
    assert.deepEqual(value.packages, {
        fixedMath: publishedAt("fixed_math"),
        account: publishedAt("account"),
        propbook: publishedAt("propbook"),
        predict: publishedAt("predict"),
    });
});

test("a complete verified state deterministically generates the committed manifest", () => {
    assertIntegrationManifest(manifest);
    assert.deepEqual(buildIntegrationManifest(verifiedState()), manifest);
});

test("partial deployment state cannot generate an integration manifest", () => {
    assert.throws(
        () => buildIntegrationManifest(createDeploymentState()),
        /complete, verified deployment state/,
    );
});

test("the manifest validator rejects operator-only fields", () => {
    assertIntegrationManifest(manifest);
    assert.throws(
        () => assertIntegrationManifest({ ...manifest, transactions: {} }),
        /integration manifest keys/,
    );
});

test("configuration provenance requires exact shared-object anchors", () => {
    const invalid = JSON.parse(JSON.stringify(manifest)) as {
        initialConfiguration: Record<string, unknown>;
    };
    invalid.initialConfiguration.asOfCheckpoint =
        invalid.initialConfiguration.verifiedAfterCheckpoint;
    delete invalid.initialConfiguration.verifiedAfterCheckpoint;
    delete invalid.initialConfiguration.stateAnchors;
    assert.throws(() => assertIntegrationManifest(invalid), /initialConfiguration keys/);
});
