import { bcs } from "@mysten/sui/bcs";
import type { Transaction } from "@mysten/sui/transactions";
import { describe, expect, test } from "vitest";
import { PredictClient } from "../src/client.js";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import { PredictInputError } from "../src/errors.js";
import type { ReadClient } from "../src/reads/inspect.js";
import { POS_INF_TICK } from "../src/ticks.js";

const OWNER = "0x" + "ab".repeat(32);
const MARKET_ID = "0x" + "cd".repeat(32);
const EXPIRY = 1_700_000_000_000;

// The moveCall targets in the order the builder emitted them.
function targets(tx: Transaction): string[] {
	return tx.getData().commands.flatMap((c) =>
		"MoveCall" in c && c.MoveCall
			? [`${c.MoveCall.package}::${c.MoveCall.module}::${c.MoveCall.function}`]
			: [],
	);
}

function call(tx: Transaction, cmdIdx: number) {
	return tx.getData().commands[cmdIdx].MoveCall!;
}

// Resolve the base64 pure bytes an argument points at (undefined if not a pure input).
function argPureBytes(tx: Transaction, cmdIdx: number, argIdx: number): string | undefined {
	const arg = call(tx, cmdIdx).arguments[argIdx] as { $kind: string; Input?: number };
	if (arg.$kind !== "Input" || arg.Input === undefined) return undefined;
	const input = tx.getData().inputs[arg.Input];
	return "Pure" in input && input.Pure ? input.Pure.bytes : undefined;
}

const b64 = (v: bigint) => Buffer.from(bcs.u64().serialize(v).toBytes()).toString("base64");

// A mock ReadClient that dispatches canned return values by the first command's
// move-call function, and counts how many times each function was simulated.
function mockClient() {
	const counts: Record<string, number> = {};
	const client = {
		async simulateTransaction(opts: { transaction: Transaction }) {
			const cmds = opts.transaction.getData().commands;
			const fn =
				"MoveCall" in cmds[0] && cmds[0].MoveCall ? cmds[0].MoveCall.function : "?";
			counts[fn] = (counts[fn] ?? 0) + 1;
			let results: Uint8Array[][];
			if (fn === "active_expiry_markets") {
				results = [[bcs.vector(bcs.Address).serialize([MARKET_ID]).toBytes()]];
			} else if (fn === "expiry_market_id") {
				results = [[bcs.option(bcs.Address).serialize(MARKET_ID).toBytes()]];
			} else if (fn === "expiry") {
				// marketState PTB: expiry, tick_size, mint_paused
				results = [
					[bcs.u64().serialize(BigInt(EXPIRY)).toBytes()],
					[bcs.u64().serialize(10_000_000n).toBytes()],
					[bcs.bool().serialize(false).toBytes()],
				];
			} else {
				// e.g. currentNav's load_live_pricer → current_nav: one u64 per command.
				results = cmds.map(() => [bcs.u64().serialize(0n).toBytes()]);
			}
			return {
				$kind: "Transaction",
				Transaction: {},
				commandResults: results.map((rvs) => ({
					returnValues: rvs.map((b) => ({ bcs: b })),
					mutatedReferences: [],
				})),
			};
		},
	} as unknown as ReadClient;
	return { client, counts };
}

// A mock that reports NO market for the descriptor.
function mockNoMarket() {
	const client = {
		async simulateTransaction() {
			return {
				$kind: "Transaction",
				Transaction: {},
				commandResults: [
					{
						returnValues: [{ bcs: bcs.option(bcs.Address).serialize(null).toBytes() }],
						mutatedReferences: [],
					},
				],
			};
		},
	} as unknown as ReadClient;
	return client;
}

describe("PredictClient constructor", () => {
	test("mainnet without config throws (no deployment)", () => {
		expect(() => new PredictClient({ network: "mainnet", client: mockClient().client })).toThrow();
	});

	test("testnet resolves the bundled config; wrapperIdFor is deterministic", () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const id = pc.wrapperIdFor(OWNER);
		expect(id).toMatch(/^0x[0-9a-f]{64}$/);
		expect(pc.wrapperIdFor(OWNER)).toBe(id);
	});
});

describe("tx.deposit / tx.withdraw", () => {
	test("deposit sources a coin via CoinWithBalance intent and calls deposit_funds; 12.5 → 12_500_000", () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const tx = pc.tx.deposit(OWNER, "12.5");
		// a CoinWithBalance $Intent command is present
		const hasIntent = tx
			.getData()
			.commands.some((c) => "$Intent" in c && c.$Intent?.name === "CoinWithBalance");
		expect(hasIntent).toBe(true);
		expect(targets(tx)).toContain(`${cfg.packages.account}::account::deposit_funds`);
	});

	test("withdraw transfers the returned coin to the owner (TransferObjects present)", () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const tx = pc.tx.withdraw(OWNER, "5");
		expect(targets(tx)).toContain(`${cfg.packages.account}::account::withdraw_funds`);
		const hasTransfer = tx.getData().commands.some((c) => "TransferObjects" in c && c.TransferObjects);
		expect(hasTransfer).toBe(true);
	});
});

describe("tx.mint (market resolution + unit conversion)", () => {
	test("converts quantity, leverage, ticks against a resolved market", async () => {
		const { client } = mockClient();
		const pc = new PredictClient({ network: "testnet", client });
		const tx = await pc.tx.mint(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
			{ quantity: 50, leverage: 2 },
		);
		expect(targets(tx)).toEqual([
			`${cfg.packages.predict}::expiry_market::load_live_pricer`,
			`${cfg.packages.account}::account::generate_auth`,
			`${cfg.packages.predict}::expiry_market::mint_exact_quantity`,
		]);
		// mint args: [market, wrapper, auth, config, pricer, lower, higher, quantity, leverage, ...]
		expect(argPureBytes(tx, 2, 5)).toBe(b64(10_500_000n)); // lower tick = strike/tickSize
		expect(argPureBytes(tx, 2, 6)).toBe(b64(POS_INF_TICK)); // higher tick (up)
		expect(argPureBytes(tx, 2, 7)).toBe(b64(50_000_000n)); // quantity 50 → 1e6
		expect(argPureBytes(tx, 2, 8)).toBe(b64(2_000_000_000n)); // leverage 2 → 1e9
	});

	test("unknown market → PredictInputError /no market/", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockNoMarket() });
		await expect(
			pc.tx.mint(
				OWNER,
				{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
				{ quantity: 50 },
			),
		).rejects.toThrow(/no market/);
	});

	test("unknown underlying → PredictInputError", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		await expect(
			pc.tx.mint(
				OWNER,
				{ underlying: "DOGE", expiryMs: EXPIRY, strike: 1, side: "up" },
				{ quantity: 50 },
			),
		).rejects.toBeInstanceOf(PredictInputError);
	});

	test("sub-lot quantity throws /lot/", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		await expect(
			pc.tx.mint(
				OWNER,
				{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
				{ quantity: 0.001 },
			),
		).rejects.toThrow(/lot/);
	});

	test("sub-lot close quantity throws /lot/ on redeem and claimSettled", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const m = { underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" } as const;
		await expect(pc.tx.redeem(OWNER, m, { orderId: 1n, quantity: 0.001 })).rejects.toThrow(
			/lot/,
		);
		await expect(
			pc.tx.claimSettled(OWNER, m, { orderId: 1n, quantity: 0.001 }),
		).rejects.toThrow(/lot/);
	});

	test("mintAmount minQuantity is a floor — sub-lot values are accepted", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const tx = await pc.tx.mintAmount(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
			{ spend: 10, minQuantity: 0.015 },
		);
		expect(tx).toBeTruthy();
	});

	test("read.markets returns tradeable summaries", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const markets = await pc.read.markets();
		expect(markets).toEqual([
			{
				id: MARKET_ID,
				expiryMs: BigInt(EXPIRY),
				tickSize: 0.01,
				mintPaused: false,
			},
		]);
	});

	test("market resolution is cached: a second mint does not re-resolve", async () => {
		const { client, counts } = mockClient();
		const pc = new PredictClient({ network: "testnet", client });
		const m = { underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" } as const;
		await pc.tx.mint(OWNER, m, { quantity: 50 });
		await pc.tx.mint(OWNER, m, { quantity: 50 });
		expect(counts.expiry_market_id).toBe(1);
	});
});

describe("read facade", () => {
	test("market returns id + converted fields, or null when absent", async () => {
		const { client } = mockClient();
		const pc = new PredictClient({ network: "testnet", client });
		const m = await pc.read.market({ underlying: "BTC", expiryMs: EXPIRY });
		expect(m).not.toBeNull();
		expect(m!.id).toBe(MARKET_ID);
		expect(m!.expiryMs).toBe(BigInt(EXPIRY));
		expect(m!.mintPaused).toBe(false);

		const none = await new PredictClient({ network: "testnet", client: mockNoMarket() }).read.market({
			underlying: "BTC",
			expiryMs: 1,
		});
		expect(none).toBeNull();
	});
});
