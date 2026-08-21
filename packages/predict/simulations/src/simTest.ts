import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import test from "node:test";

process.env.INSTANCE_DIR ??= tmpdir();
const { SCENARIO_COLUMNS, parseScenarioText } = await import("./shared.js");

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

test("scenario parser accepts every current explicit action", () => {
    const text = [
        SCENARIO_COLUMNS.join(","),
        csvRow(1, "mint", { ...oracle, strike: "75000000000000", is_up: "true", quantity: "20000", order_ref: "o1" }),
        csvRow(2, "redeem_live", { ...oracle, order_ref: "o1", close_quantity: "10000", replacement_order_ref: "o2" }),
        csvRow(3, "request_supply", { amount: "100", min_output: "0", lp_ref: "s1" }),
        csvRow(4, "request_withdraw", { shares: "100", min_output: "0", lp_ref: "w1" }),
        csvRow(5, "flush", oracle),
        csvRow(6, "rebalance_expiry_cash"),
        csvRow(7, "settle", { settlement_price: "75000000000000" }),
        csvRow(8, "redeem_settled", { order_ref: "o2", permissionless: "true" }),
    ].join("\n");

    assert.deepEqual(
        parseScenarioText(text).map((row) => row.action),
        ["mint", "redeem_live", "request_supply", "request_withdraw", "flush", "rebalance_expiry_cash", "settle", "redeem_settled"],
    );
});

test("scenario parser rejects removed leverage-era actions", () => {
    const text = [SCENARIO_COLUMNS.join(","), csvRow(1, "liquidate")].join("\n");
    assert.throws(() => parseScenarioText(text), /unsupported action/);
});
