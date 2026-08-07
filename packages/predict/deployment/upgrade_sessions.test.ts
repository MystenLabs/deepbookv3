// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
    assertSmokeSessionResume,
    assertSessionsUpgradeState,
    buildSessionsUpgradeManifest,
    createSessionsUpgradeState,
    parsePackageMetadata,
    parseSessionsUpgradeArgs,
    parseUpgradeCapMetadata,
    type SessionsUpgradeState,
} from "./upgrade_sessions.ts";
import type { IntegrationManifest } from "./deploy.ts";

const V1 = "0x78887ffbb5e449776152c612fe05af03f729c02dbb7218c270e645c241ad527b";
const V2 = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CAP = "0xec1a56cd72b2a6a97c592b0a66512bf92ce2d0508ebac2b8956abbc5d98a55a8";
const DEPLOYER = "0x364c09b14bc64320dd8ced0848e7e4efe75510bd7ee05a88253a5330b6f22bef";
const WRAPPER = "0x7ea715df00320b9460cd17531ecb507d8cc28925dce5be5de40af448c1d34239";
const ACCOUNT = "0xbdbb60b00f2d4f30daeff62f2c642b18433a8fcdfbebccc808df578df2a0c203";

const manifest = JSON.parse(
    readFileSync(new URL("deployment.testnet.json", import.meta.url), "utf8"),
) as IntegrationManifest;

function completeState(): SessionsUpgradeState {
    const state = createSessionsUpgradeState();
    state.status = "complete";
    state.sourceCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    state.suiVersion = "sui 1.74.1-test";
    state.rpcUrlHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    state.startedAt = "2026-08-07T12:00:00.000Z";
    state.completedAt = "2026-08-07T12:10:00.000Z";
    state.packageId = V2;
    state.upgradeTx = "upgrade-digest";
    state.verification = {
        packageVersion: "2",
        upgradeCapVersion: "2",
        moduleNames: ["sessions"],
        typeOriginsPreserved: true,
        dependencies: [ACCOUNT, WRAPPER],
        sessionsAppAuthorized: true,
        wrapperAppAuthorized: true,
        verifiedAt: "2026-08-07T12:05:00.000Z",
    };
    state.smoke.status = "complete";
    state.smoke.wrapperId = "0xe008235d34146f0993bea592191b382f5172d34a3142c07637cef31732445707";
    state.smoke.sessionAddress =
        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    state.smoke.quantity = "10000000";
    state.smoke.fundingAmount = "500000000";
    state.smoke.initialSuiBalance = "0";
    state.smoke.initialDeepBalance = "0";
    state.smoke.marketPreSuiBalance = "500000000";
    state.smoke.marketPreDeepBalance = "0";
    state.smoke.limitClientId = "1";
    state.smoke.marketClientId = "2";
    state.smoke.limitPrice = "100000000";
    state.smoke.marketPriceLimit = "125000000";
    state.smoke.limitOrderId = "123";
    state.smoke.marketExecutedQuantity = "10000000";
    state.smoke.marketQuoteQuantity = "324000000";
    state.smoke.marketPaidFees = "1000000";
    state.smoke.marketPostSuiBalance = "175000000";
    state.smoke.marketPostDeepBalance = "10000000";
    state.smoke.accountFundsRecovered = true;
    state.smoke.sessionRevoked = true;
    state.smoke.sessionGasReturned = true;
    return state;
}

test("upgrade defaults to non-broadcasting mode and smoke requires execute", () => {
    assert.deepEqual(parseSessionsUpgradeArgs([]), { execute: false, smoke: false });
    assert.deepEqual(parseSessionsUpgradeArgs(["--execute"]), { execute: true, smoke: false });
    assert.deepEqual(parseSessionsUpgradeArgs(["--execute", "--smoke"]), {
        execute: true,
        smoke: true,
    });
    assert.throws(() => parseSessionsUpgradeArgs(["--smoke"]), /requires --execute/);
    assert.throws(() => parseSessionsUpgradeArgs(["--force"]), /unknown Sessions upgrade/);
});

test("session resume allows post-market cleanup but rejects missing write authority", () => {
    assert.doesNotThrow(() => assertSmokeSessionResume(false, false, 123n));
    assert.doesNotThrow(() => assertSmokeSessionResume(true, true, null));
    assert.throws(() => assertSmokeSessionResume(false, false, null), /no longer authorized/);
    assert.throws(
        () => assertSmokeSessionResume(true, false, null),
        /revoked before the market checkpoint/,
    );
});

test("journal validation pins the Testnet chain, deployer, v1 package, and UpgradeCap", () => {
    const state = createSessionsUpgradeState();
    assertSessionsUpgradeState(state);
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, chainId: "deadbeef" }),
        /pinned Sessions v2 upgrade/,
    );
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, deployer: V2 }),
        /pinned Sessions v2 upgrade/,
    );
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, previousPackageId: V2 }),
        /pinned Sessions v2 upgrade/,
    );
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, upgradeCapId: V2 }),
        /pinned Sessions v2 upgrade/,
    );
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, packageGasBudget: "1" }),
        /pinned Sessions v2 upgrade/,
    );
    assert.throws(
        () => assertSessionsUpgradeState({ ...state, sessionTransactionGasBudget: "1" }),
        /pinned Sessions v2 upgrade/,
    );
});

test("complete journal requires both package audit and live spot smoke", () => {
    const state = createSessionsUpgradeState();
    state.status = "complete";
    assert.throws(() => assertSessionsUpgradeState(state), /lacks verification or smoke/);
    const complete = completeState();
    assertSessionsUpgradeState(complete);
    complete.inFlight = {
        label: "smoke_session_market_fill",
        digest: "known-digest",
        startedAt: complete.completedAt!,
    };
    assert.throws(
        () => buildSessionsUpgradeManifest(manifest, complete),
        /complete audited upgrade and spot smoke/,
    );
    for (const field of [
        "accountFundsRecovered",
        "sessionRevoked",
        "sessionGasReturned",
    ] as const) {
        const incomplete = completeState();
        incomplete.smoke[field] = false;
        assert.throws(() => assertSessionsUpgradeState(incomplete), /lacks verification or smoke/);
    }
});

test("package parser preserves logical version, type origins, linkage, and provenance", () => {
    const parsed = parsePackageMetadata({
        objectId: V2,
        version: 1,
        prevTx: "upgrade-digest",
        content: {
            Package: {
                id: V2,
                version: 2,
                module_map: { sessions: [1, 2, 3] },
                type_origin_table: [
                    { module_name: "sessions", datatype_name: "SessionsApp", package: V1 },
                    { module_name: "sessions", datatype_name: "SessionsData", package: V1 },
                ],
                linkage_table: {
                    [ACCOUNT]: { upgraded_id: ACCOUNT, upgraded_version: 1 },
                    [WRAPPER]: { upgraded_id: WRAPPER, upgraded_version: 1 },
                },
            },
        },
    });
    assert.deepEqual(parsed, {
        id: V2,
        version: "2",
        modules: ["sessions"],
        typeOrigins: [
            { module: "sessions", datatype: "SessionsApp", package: V1 },
            { module: "sessions", datatype: "SessionsData", package: V1 },
        ],
        dependencies: [WRAPPER, ACCOUNT].sort(),
        linkages: [
            { originalId: WRAPPER, upgradedId: WRAPPER },
            { originalId: ACCOUNT, upgradedId: ACCOUNT },
        ].sort((left, right) => left.originalId.localeCompare(right.originalId)),
        previousTransaction: "upgrade-digest",
    });
});

test("UpgradeCap parser binds original package, version, policy, and owner", () => {
    assert.deepEqual(
        parseUpgradeCapMetadata({
            owner: { AddressOwner: DEPLOYER },
            content: { id: CAP, package: V1, version: "2", policy: 0 },
        }),
        { packageId: V1, version: "2", policy: "0", owner: DEPLOYER },
    );
});

test("manifest generation changes only sourceCommit and latest Sessions package", () => {
    const before = JSON.parse(JSON.stringify(manifest)) as IntegrationManifest;
    const state = completeState();
    const updated = buildSessionsUpgradeManifest(manifest, state);
    const expected = JSON.parse(JSON.stringify(manifest)) as IntegrationManifest;
    expected.sourceCommit = state.sourceCommit!;
    expected.packages.sessions = V2;
    assert.deepEqual(updated, expected);
    assert.deepEqual(manifest, before, "manifest input must not be mutated");
    assert.equal(updated.packages.deepbookCoreAccount, WRAPPER);

    const rerun = buildSessionsUpgradeManifest(updated, state);
    assert.deepEqual(rerun, updated, "completion manifest generation must be idempotent");
});

test("partial or unaudited upgrades cannot update the public manifest", () => {
    const pending = createSessionsUpgradeState();
    assert.throws(
        () => buildSessionsUpgradeManifest(manifest, pending),
        /complete audited upgrade and spot smoke/,
    );
    const wrongSchema = JSON.parse(JSON.stringify(manifest)) as IntegrationManifest;
    wrongSchema.schemaVersion = 4;
    delete wrongSchema.packages.deepbookCoreAccount;
    assert.throws(
        () => buildSessionsUpgradeManifest(wrongSchema, completeState()),
        /complete audited upgrade and spot smoke/,
    );
});
