// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
    MANIFEST_RELATIVE,
    SESSIONS_STATE_RELATIVE,
    STATE_RELATIVE,
    assertIntegrationManifest,
    buildIntegrationManifest,
    buildSessionsIntegrationManifest,
    createDeploymentState,
    createSessionsDeploymentState,
    parseDeploymentArgs,
    parseOptionBlockScholesStorePair,
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
    sourceCommit: "a92ceb017fb95e78db32825811c0c695965097c4",
    chainId: "4c78adac",
    indexingStartCheckpoint: "367911686",
    verifiedAfterCheckpoint: "367912068",
    packages: {
        fixed_math: "0xdf0bd2a0d201562f2bdecb1b77d7998c7af316f6fd7d1eab9b9035064f21bfd4",
        account: "0xbdbb60b00f2d4f30daeff62f2c642b18433a8fcdfbebccc808df578df2a0c203",
        propbook: "0xed1295ff3c9a9415766afff20a74cdf2e362647be09aaf13b809302c0109e912",
        predict: "0xfe742239a3b033f7d52ed5275f238c17d27498ca0ee5ea5672ea732eb3f4dbbb",
    },
    linkedPackages: {
        dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
        deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
        pyth_lazer: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
        wormhole: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
        bs_oracle: "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
    },
    linkedObjects: {
        clock: "0x0000000000000000000000000000000000000000000000000000000000000006",
        accumulatorRoot: "0x0000000000000000000000000000000000000000000000000000000000000acc",
        pythLazerState: "0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8",
        wormholeState: "0x3c89c52e413edb9b0d9a145e02258c96916c79b1e57a12861bb61791ee5c5f81",
        blockScholesSignerRegistry:
            "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
    },
    sharedObjects: {
        accountRegistry: "0x21a7ed28397363b5550853c1f08795731257de81028cd1bf87f20c0752c8ca2f",
        oracleRegistry: "0xc1dffc5f7a5404cb002ba3bd7c50d6a2dbe8bb6afd40080cd663965deff9d577",
        protocolConfig: {
            objectId: "0x43703ceee4d5f5a9e8cbf728071c34dc65961dd6e878fafd9ac36d86a9a4ce5b",
            version: "965519142",
            digest: "9seyJxMB6uFojknZL3cqemLr9i8AZdFETuZnvN5Gsu9i",
        },
        poolVault: "0xeef535e7fcb850a943807ce48cc543c6d990b39e68a7bc47d0b56651ff20ab0a",
        registry: {
            objectId: "0x35970bfd0ff3703cb38b3fff3a3fbb0bc0e5638e7c747af3a8e42e2c95d353f0",
            version: "965519935",
            digest: "8QVgzKoLRswCZY5ZcTnBTeyQjzBFwfFRAESqmFE7TV1r",
        },
    },
    oracleObjects: {
        pythFeed: "0xccafaa6c5a41f0493585cf268f2b4dc14c91ed798362444144cac2c745db8dde",
        blockScholesValueStore:
            "0x6d9de17954f4c1a2f01fdd97c0bb8a2e682c1fea0f8f048dcd127d543a6ac051",
        blockScholesSviStore: "0x83c2d6307fd3591228052fc0d24c4f00a698b0eb4fef5e6083a213ca0d54bd35",
    },
    lifecycleCap: "0x7384f57268f0e94a20cfe7f7ea4b0d3e7160812b4330b4be713a06fcc45030eb",
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
    assert.match(SESSIONS_STATE_RELATIVE, /\.state\.json$/);
    assert.notEqual(SESSIONS_STATE_RELATIVE, STATE_RELATIVE);
    assert.notEqual(SESSIONS_STATE_RELATIVE, MANIFEST_RELATIVE);
    assert.match(gitignore, new RegExp(`^${SESSIONS_STATE_RELATIVE}$`, "m"));
    assert.match(gitignore, new RegExp(`^${SESSIONS_STATE_RELATIVE}\.tmp$`, "m"));
});

test("Sessions mode arguments are explicit and smoke always broadcasts", () => {
    assert.deepEqual(parseDeploymentArgs([]), { execute: false, sessions: false, smoke: false });
    assert.deepEqual(parseDeploymentArgs(["--execute"]), {
        execute: true,
        sessions: false,
        smoke: false,
    });
    assert.deepEqual(parseDeploymentArgs(["--sessions"]), {
        execute: false,
        sessions: true,
        smoke: false,
    });
    assert.deepEqual(parseDeploymentArgs(["--sessions", "--smoke", "--execute"]), {
        execute: true,
        sessions: true,
        smoke: true,
    });
    assert.throws(() => parseDeploymentArgs(["--smoke"]), /requires --sessions/);
    assert.throws(() => parseDeploymentArgs(["--sessions", "--smoke"]), /requires --execute/);
    assert.throws(() => parseDeploymentArgs(["--wat"]), /unknown deployment arguments/);
});

test("a fresh deployment targets the official Block Scholes package pair", () => {
    const state = createDeploymentState();
    assert.equal(
        state.linked.bs_oracle,
        "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
    );
    assert.equal(
        state.linked.bs_sid,
        "0x6a54299d593fca24edf6b17bf8c3aff0b7ba8bc8f4276e9c1065689c50223bba",
    );
    assert.equal(
        state.linkedObjects.blockScholesSignerRegistry,
        "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
    );
    assert.equal(
        state.wiring.lifecycleCap.recipient,
        "0xc230d3a341a4fddd752979fbac7625fb2b302ea28202d218a81b007653380c82",
    );
});

test("Block Scholes store-pair inspection decodes both canonical IDs", () => {
    const idBytes = (id: string) => Array.from(Buffer.from(id.replace(/^0x/, ""), "hex"));
    assert.deepEqual(
        parseOptionBlockScholesStorePair([
            1,
            ...idBytes(FIXTURE.oracleObjects.blockScholesValueStore),
            ...idBytes(FIXTURE.oracleObjects.blockScholesSviStore),
        ]),
        {
            valueStoreId: FIXTURE.oracleObjects.blockScholesValueStore,
            sviStoreId: FIXTURE.oracleObjects.blockScholesSviStore,
        },
    );
    assert.equal(parseOptionBlockScholesStorePair([0]), null);
    assert.throws(() => parseOptionBlockScholesStorePair([1]), /invalid Option/);
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

test("the manifest validator rejects a mismatched Block Scholes package and registry", () => {
    const invalid = JSON.parse(JSON.stringify(manifest)) as {
        writers: { priceUpdater: { blockScholesSignerRegistry: string } };
    };
    invalid.writers.priceUpdater.blockScholesSignerRegistry =
        "0xe1198f0add6ba5286d23f2790818937e4a629b95a86e98b1ece93c0ef3c2c440";
    assert.throws(() => assertIntegrationManifest(invalid), /verified dependencies/);
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

const SESSIONS_PACKAGE = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SESSIONS_CAP = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

function completeSessionsState() {
    const state = createSessionsDeploymentState();
    state.status = "complete";
    state.sourceCommit = "bd4535c900000000000000000000000000000000";
    state.startedAt = "2026-08-06T12:00:00.000Z";
    state.completedAt = "2026-08-06T12:05:00.000Z";
    state.sessions = {
        packageId: SESSIONS_PACKAGE,
        publishTx: "publish-digest",
        upgradeCapId: SESSIONS_CAP,
    };
    state.authorization = {
        authorized: true,
        authorizeTx: "authorize-digest",
        verifiedAt: state.completedAt,
    };
    state.verification = {
        verifiedAt: state.completedAt,
        package: evidence(SESSIONS_PACKAGE),
        upgradeCap: evidence(SESSIONS_CAP),
        accountRegistry: evidence(FIXTURE.sharedObjects.accountRegistry),
        accountAdminCap: evidence(
            "0xb60110c92b80b64433b627bc141e68f5bbe1a404b06bcadd02b4073e98a3a6ae",
        ),
        appAuthorized: true,
    };
    return state;
}

test("schema-3 to schema-4 extension changes only the source, schema, and Sessions package", () => {
    assertIntegrationManifest(manifest);
    const before = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
    const extended = buildSessionsIntegrationManifest(manifest, completeSessionsState());
    assert.equal(extended.schemaVersion, 4);
    assert.equal(extended.sourceCommit, "bd4535c900000000000000000000000000000000");
    assert.equal(extended.packages.sessions, SESSIONS_PACKAGE);
    assert.deepEqual(manifest, before, "the committed schema-3 input is not mutated");
    const expected = JSON.parse(JSON.stringify(manifest)) as IntegrationManifest;
    expected.schemaVersion = 4;
    expected.sourceCommit = "bd4535c900000000000000000000000000000000";
    expected.packages.sessions = SESSIONS_PACKAGE;
    assert.deepEqual(extended, expected);
    assert.deepEqual(extended.indexing, (manifest as IntegrationManifest).indexing);
    assert.deepEqual(
        extended.initialConfiguration,
        (manifest as IntegrationManifest).initialConfiguration,
    );
});

test("partial Sessions state cannot extend or write the public manifest", () => {
    assert.throws(
        () => buildSessionsIntegrationManifest(manifest, createSessionsDeploymentState()),
        /complete, verified Sessions deployment state/,
    );
    const partial = completeSessionsState();
    partial.inFlight = {
        kind: "transaction",
        label: "authorize_sessions_app",
        startedAt: partial.completedAt!,
        digest: "known-digest",
    };
    assert.throws(
        () => buildSessionsIntegrationManifest(manifest, partial),
        /complete, verified Sessions deployment state/,
    );
});

test("schema-4 manifest excludes Sessions operator and secret-bearing fields", () => {
    const extended = buildSessionsIntegrationManifest(manifest, completeSessionsState());
    for (const key of [
        "deployer",
        "publishTx",
        "upgradeCapId",
        "authorization",
        "transactions",
        "verification",
        "smoke",
        "privateKey",
        "secretKey",
    ]) {
        assert.equal(key in extended, false);
    }
    assert.throws(
        () => assertIntegrationManifest({ ...extended, transactions: {} }),
        /integration manifest keys/,
    );
});
