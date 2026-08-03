import assert from "node:assert/strict";
import test from "node:test";

import { forwardSid, spotSid, sviSid } from "./blockScholesSid.js";

const ORACLE_PACKAGE_ID = `0x${"11".repeat(32)}`;
const EXPIRY_MS = 1_785_250_800_000n;

function hex(value: bigint): string {
    return `0x${value.toString(16).padStart(64, "0")}`;
}

test("derives the provider's pinned forward and SVI vectors", () => {
    assert.equal(
        hex(forwardSid(ORACLE_PACKAGE_ID, "HYPE", EXPIRY_MS)),
        "0x767852094662e0763fdfb8cc02f08969892b2d083159df16cb91ccb6505e3cd6",
    );
    assert.equal(
        hex(sviSid(ORACLE_PACKAGE_ID, "HYPE", EXPIRY_MS)),
        "0x29f876378481972bf272eddcbb987579ec3a75a634533295c3c8c2cbfe548a6a",
    );
});

test("scopes spot SIDs by oracle package and base asset", () => {
    const btc = spotSid(ORACLE_PACKAGE_ID, "BTC");
    assert.notEqual(btc, spotSid(ORACLE_PACKAGE_ID, "ETH"));
    assert.notEqual(btc, spotSid(`0x${"22".repeat(32)}`, "BTC"));
});
