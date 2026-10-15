import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import test from "node:test";
import type { ScenarioRow } from "./shared.js";

process.env.INSTANCE_DIR ??= tmpdir();
const {
    EXPECTED_ACTION_SEQUENCE,
    EXPECTED_MINT_ROLES,
    SCENARIO_COLUMNS,
    parseScenarioText,
    validateCompleteScenario,
} = await import("./shared.js");

const oracle = {
    spot: "75000000000000",
    forward: "75100000000000",
    a: "171736",
    a_negative: "false",
    b: "7449196",
    rho: "243059022",
    rho_negative: "true",
    m: "1133202",
    m_negative: "false",
    sigma: "15731214",
    risk_free_rate: "35000000",
};

function csvRow(tx: number, action: string, values: Record<string, string> = {}): string {
    const row: Record<string, string> = Object.fromEntries(
        SCENARIO_COLUMNS.map((column) => [column, ""]),
    );
    Object.assign(row, { tx: String(tx), action }, values);
    return SCENARIO_COLUMNS.map((column) => row[column]).join(",");
}

test("scenario parser retains both finite boundaries", () => {
    const rows = parseScenarioText([
        SCENARIO_COLUMNS.join(","),
        csvRow(1, "mint", { ...oracle, strike: "75000000000000", is_up: "true", higher_strike: "76000000000000", quantity: "20000", order_ref: "range" }),
    ].join("\n"));
    assert.equal(rows[0].action, "mint");
    if (rows[0].action !== "mint") throw new Error("expected mint");
    assert.equal(rows[0].strike, 75000000000000n);
    assert.equal(rows[0].higherStrike, 76000000000000n);
});

test("scenario parser accepts every current explicit action", () => {
    const text = [
        SCENARIO_COLUMNS.join(","),
        csvRow(1, "mint", { ...oracle, strike: "75000000000000", is_up: "true", quantity: "20000", order_ref: "o1", commit_spot: "75010000000000" }),
        csvRow(2, "redeem_open", { ...oracle, order_ref: "o1", close_quantity: "10000", commit_spot: "75010000000000" }),
        csvRow(3, "request_supply", { amount: "100", min_output: "0", lp_ref: "s1" }),
        csvRow(4, "request_withdraw", { shares: "100", min_output: "0", lp_ref: "w1" }),
        csvRow(5, "flush", oracle),
        csvRow(6, "rebalance_expiry_cash"),
        csvRow(7, "settle", { settlement_price: "75000000000000" }),
        csvRow(8, "settle_payout"),
    ].join("\n");

    const rows = parseScenarioText(text);
    assert.deepEqual(
        rows.map((row) => row.action),
        ["mint", "redeem_open", "request_supply", "request_withdraw", "flush", "rebalance_expiry_cash", "settle", "settle_payout"],
    );
    if (rows[0].action !== "mint" || rows[1].action !== "redeem_open") throw new Error("expected queued trades");
    assert.equal(rows[0].commitSpot, 75010000000000n);
    assert.equal(rows[0].maxProbability, undefined);
    assert.equal(rows[1].replacementOrderRef, null);
    assert.equal(rows[1].commitSpot, 75010000000000n);
});

test("scenario parser leaves a mint without a commit spot uncommitted and requires one to sell", () => {
    const rows = parseScenarioText([
        SCENARIO_COLUMNS.join(","),
        csvRow(1, "mint", { ...oracle, strike: "75000000000000", is_up: "true", quantity: "20000", max_probability: "600000000", order_ref: "o1" }),
    ].join("\n"));
    if (rows[0].action !== "mint") throw new Error("expected mint");
    assert.equal(rows[0].commitSpot, null);
    assert.equal(rows[0].maxProbability, 600000000n);

    const sell = [SCENARIO_COLUMNS.join(","), csvRow(1, "redeem_open", { ...oracle, order_ref: "o1", close_quantity: "10000" })].join("\n");
    assert.throws(() => parseScenarioText(sell), /missing commit_spot/);
});

test("scenario parser rejects removed leverage-era and pre-cutover actions", () => {
    for (const action of ["liquidate", "redeem_live", "redeem_settled"]) {
        const text = [SCENARIO_COLUMNS.join(","), csvRow(1, action)].join("\n");
        assert.throws(() => parseScenarioText(text), /unsupported action/);
    }
});

test("scenario parser rejects a partial oracle refresh containing only the a sign", () => {
    const text = [
        SCENARIO_COLUMNS.join(","),
        csvRow(1, "flush", { a_negative: "true" }),
    ].join("\n");
    assert.throws(() => parseScenarioText(text), /oracle refresh fields must all be present/);
});

// Minimal rows carrying only what the completeness check reads.
function completeRows(roles: readonly string[] = EXPECTED_MINT_ROLES): ScenarioRow[] {
    let mintIndex = 0;
    return EXPECTED_ACTION_SEQUENCE.map((action, index) => {
        if (action !== "mint") return { action, step: index + 1 };
        const role = roles[mintIndex++];
        return {
            action,
            step: index + 1,
            commitSpot: role === "deadline_refund" ? null : 1n,
            maxProbability: role === "limit_refund" ? 1n : undefined,
        };
    }) as unknown as ScenarioRow[];
}

test("complete scenario validation rejects max-rows truncation after all action names appear", () => {
    const rows = completeRows();

    validateCompleteScenario(rows);
    assert.throws(
        () => validateCompleteScenario(rows.slice(0, 16)),
        /must contain exactly 20 steps, got 16/,
    );
});

test("complete scenario validation requires a fill, a limit refund, and a deadline refund", () => {
    const allFills = completeRows(EXPECTED_MINT_ROLES.map(() => "fill"));
    assert.throws(
        () => validateCompleteScenario(allFills),
        /mint roles must be fill\/fill\/fill\/fill\/fill\/limit_refund\/deadline_refund/,
    );
});
