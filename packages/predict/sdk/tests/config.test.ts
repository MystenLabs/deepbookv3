import { expect, test } from "vitest";

import {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	TESTNET_CONFIG,
	accountTarget,
	getConfig,
	predictTarget,
} from "../src/config/index.js";

const ID_RE = /^0x[0-9a-f]{1,64}$/;

test("all package IDs are well-formed", () => {
	expect(TESTNET_CONFIG.packages.predict).toMatch(ID_RE);
	expect(TESTNET_CONFIG.packages.account).toMatch(ID_RE);
	expect(TESTNET_CONFIG.packages.propbook).toMatch(ID_RE);
});

test("all shared object IDs are well-formed", () => {
	for (const id of Object.values(TESTNET_CONFIG.objects)) {
		expect(id).toMatch(ID_RE);
	}
});

test("quoteCoinType is a DUSDC coin type", () => {
	expect(TESTNET_CONFIG.quoteCoinType).toMatch(/^0x[0-9a-f]+::dusdc::DUSDC$/);
});

test("BTC underlying is present and well-formed", () => {
	const btc = TESTNET_CONFIG.underlyings.BTC;
	expect(btc.symbol).toBe("BTC");
	expect(Number.isInteger(btc.propbookUnderlyingId)).toBe(true);
	expect(btc.pythFeedId).toMatch(ID_RE);
	expect(btc.bsSpotFeedId).toMatch(ID_RE);
	expect(btc.bsForwardFeedId).toMatch(ID_RE);
	expect(btc.bsSviFeedId).toMatch(ID_RE);
});

test("predictTarget concatenates from the predict package", () => {
	expect(predictTarget(TESTNET_CONFIG, "plp", "request_supply")).toBe(
		`${TESTNET_CONFIG.packages.predict}::plp::request_supply`,
	);
});

test("accountTarget concatenates from the account package", () => {
	expect(accountTarget(TESTNET_CONFIG, "account", "open")).toBe(
		`${TESTNET_CONFIG.packages.account}::account::open`,
	);
});

test("getConfig returns the testnet config", () => {
	expect(getConfig("testnet")).toBe(TESTNET_CONFIG);
});

test("getConfig throws for mainnet", () => {
	expect(() => getConfig("mainnet")).toThrow(/no mainnet deployment/);
});

test("well-known object id constants", () => {
	expect(CLOCK_ID).toBe("0x6");
	expect(ACCUMULATOR_ROOT_ID).toBe("0xacc");
});
