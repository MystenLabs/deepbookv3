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

// Canned trade events for quote dry-runs (layouts mirror src/decode.ts).
const MINTED_EVENT = {
	eventType: `${cfg.packages.predict}::order_events::OrderMinted`,
	bcs: bcs
		.struct("OrderMinted", {
			expiry_market_id: bcs.Address,
			account_id: bcs.Address,
			order_id: bcs.u256(),
			position_root_id: bcs.u256(),
			owner: bcs.Address,
			lower_tick: bcs.u64(),
			higher_tick: bcs.u64(),
			leverage: bcs.u64(),
			entry_probability: bcs.u64(),
			quantity: bcs.u64(),
			net_premium: bcs.u64(),
			trading_fee: bcs.u64(),
			fee_incentive_subsidy: bcs.u64(),
			builder_fee: bcs.u64(),
			penalty_fee: bcs.u64(),
			builder_code_id: bcs.option(bcs.Address),
		})
		.serialize({
			expiry_market_id: MARKET_ID,
			account_id: MARKET_ID,
			order_id: 7n,
			position_root_id: 7n,
			owner: OWNER,
			lower_tick: 10_500_000n,
			higher_tick: (1n << 30n) - 1n,
			leverage: 1_000_000_000n,
			entry_probability: 340_000_000n, // 0.34
			quantity: 50_000_000n, // $50
			net_premium: 17_000_000n, // $17
			trading_fee: 100_000n, // $0.10
			fee_incentive_subsidy: 20_000n, // $0.02 sponsor-paid
			builder_fee: 30_000n, // $0.03
			penalty_fee: 5_000n, // $0.005
			builder_code_id: null,
		})
		.toBytes(),
};
const REDEEMED_EVENT = {
	eventType: `${cfg.packages.predict}::order_events::LiveOrderRedeemed`,
	bcs: bcs
		.struct("LiveOrderRedeemed", {
			expiry_market_id: bcs.Address,
			account_id: bcs.Address,
			order_id: bcs.u256(),
			position_root_id: bcs.u256(),
			owner: bcs.Address,
			quantity_closed: bcs.u64(),
			remaining_quantity: bcs.u64(),
			replacement_order_id: bcs.option(bcs.u256()),
			redeem_amount: bcs.u64(),
			trading_fee: bcs.u64(),
			builder_fee: bcs.u64(),
			penalty_fee: bcs.u64(),
			builder_code_id: bcs.option(bcs.Address),
		})
		.serialize({
			expiry_market_id: MARKET_ID,
			account_id: MARKET_ID,
			order_id: 7n,
			position_root_id: 7n,
			owner: OWNER,
			quantity_closed: 20_000_000n,
			remaining_quantity: 30_000_000n,
			replacement_order_id: 8n,
			redeem_amount: 6_000_000n, // gross $6
			trading_fee: 50_000n,
			builder_fee: 0n,
			penalty_fee: 0n,
			builder_code_id: null,
		})
		.toBytes(),
};

// A mock ReadClient that dispatches canned return values by the first command's
// move-call function, and counts how many times each function was simulated.
function mockClient() {
	const counts: Record<string, number> = {};
	const client = {
		async simulateTransaction(opts: { transaction: Transaction }) {
			const cmds = opts.transaction.getData().commands;
			const fns = cmds.map((c) =>
				"MoveCall" in c && c.MoveCall ? c.MoveCall.function : "?",
			);
			const fn = fns[0];
			counts[fn] = (counts[fn] ?? 0) + 1;
			// Quote dry-runs: a simulated trade returns its emitted events.
			if (fns.includes("mint_exact_quantity")) {
				counts.quote_mint_sim = (counts.quote_mint_sim ?? 0) + 1;
				return { $kind: "Transaction", Transaction: { events: [MINTED_EVENT] } };
			}
			if (fns.includes("redeem_live")) {
				return { $kind: "Transaction", Transaction: { events: [REDEEMED_EVENT] } };
			}
			let results: Uint8Array[][];
			if (fns[1] === "range_price") {
				// price PTB: load_live_pricer → up range → down range
				results = [
					[new Uint8Array(0)],
					[bcs.u64().serialize(340_000_000n).toBytes()], // up 0.34
					[bcs.u64().serialize(660_000_000n).toBytes()], // down 0.66
				];
			} else if (fn === "active_expiry_markets") {
				results = [[bcs.vector(bcs.Address).serialize([MARKET_ID]).toBytes()]];
			} else if (fn === "expiry_market_id") {
				results = [[bcs.option(bcs.Address).serialize(MARKET_ID).toBytes()]];
			} else if (fn === "expiry") {
				// marketState PTB: expiry, tick_size, mint_paused, reference_tick
				results = [
					[bcs.u64().serialize(BigInt(EXPIRY)).toBytes()],
					[bcs.u64().serialize(10_000_000n).toBytes()],
					[bcs.bool().serialize(false).toBytes()],
					[bcs.option(bcs.u64()).serialize(10_500_000n).toBytes()],
				];
			} else if (fn === "reference_tick") {
				// mint-at-reference fresh read: tick 10_500_000 (= $105,000 @ $0.01)
				results = [[bcs.option(bcs.u64()).serialize(10_500_000n).toBytes()]];
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
				referencePrice: 105_000, // tick 10_500_000 × $0.01
			},
		]);
	});

	test("mint at the reference strike uses the on-chain reference tick directly", async () => {
		const { client, counts } = mockClient();
		const pc = new PredictClient({ network: "testnet", client });
		const tx = await pc.tx.mint(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: "reference", side: "up" },
			{ quantity: 50 },
		);
		// The fresh reference read must have happened (never served from cache).
		expect(counts.reference_tick).toBe(1);
		// lowerTick input = the reference tick itself; higherTick = +inf sentinel.
		const inputs = tx.getData().inputs;
		const pureB64 = inputs
			.filter((i) => "Pure" in i && i.Pure)
			.map((i) => (i as { Pure: { bytes: string } }).Pure.bytes);
		expect(pureB64).toContain(b64(10_500_000n)); // reference tick
		expect(pureB64).toContain(b64((1n << 30n) - 1n)); // POS_INF_TICK
	});

	test("mint at reference: DOWN side puts the tick on the higher bound", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const tx = await pc.tx.mint(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: "reference", side: "down" },
			{ quantity: 50 },
		);
		const pureB64 = tx
			.getData()
			.inputs.filter((i) => "Pure" in i && i.Pure)
			.map((i) => (i as { Pure: { bytes: string } }).Pure.bytes);
		expect(pureB64).toContain(b64(0n)); // -inf sentinel on the lower bound
		expect(pureB64).toContain(b64(10_500_000n)); // reference tick on the higher
	});

	test("mint at reference: unset reference → PredictInputError", async () => {
		const base = mockClient().client as unknown as {
			simulateTransaction: (o: { transaction: Transaction }) => Promise<unknown>;
		};
		// Wrap the mock: reference_tick returns None; everything else passes through.
		const client = {
			async simulateTransaction(opts: { transaction: Transaction }) {
				const cmds = opts.transaction.getData().commands;
				const fn =
					"MoveCall" in cmds[0] && cmds[0].MoveCall ? cmds[0].MoveCall.function : "?";
				if (fn === "reference_tick") {
					return {
						$kind: "Transaction",
						Transaction: {},
						commandResults: [
							{
								returnValues: [
									{ bcs: bcs.option(bcs.u64()).serialize(null).toBytes() },
								],
								mutatedReferences: [],
							},
						],
					};
				}
				return base.simulateTransaction(opts);
			},
		} as never;
		const pc = new PredictClient({ network: "testnet", client });
		await expect(
			pc.tx.mint(
				OWNER,
				{ underlying: "BTC", expiryMs: EXPIRY, strike: "reference", side: "up" },
				{ quantity: 50 },
			),
		).rejects.toThrow(/reference price not set/);
	});

	test("read.price returns both sides from the chain's range_price", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const p = await pc.read.price({ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000 });
		expect(p).toEqual({ up: 0.34, down: 0.66 });
	});

	test("read.price rejects off-grid strikes", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		await expect(
			pc.read.price({ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000.005 }),
		).rejects.toThrow(/tick grid/);
	});

	test("read.quoteMint dry-runs the mint and computes the all-in cost", async () => {
		const { client, counts } = mockClient();
		const pc = new PredictClient({ network: "testnet", client });
		const q = await pc.read.quoteMint(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
			{ quantity: 50 },
		);
		expect(counts.quote_mint_sim).toBe(1);
		expect(q.entryProbability).toBeCloseTo(0.34);
		expect(q.premium).toBe(17);
		// cost = premium + (trading − subsidy) + builder + penalty
		expect(q.raw.cost).toBe(17_000_000n + 80_000n + 30_000n + 5_000n);
		expect(q.cost).toBeCloseTo(17.115);
		expect(q.quantity).toBe(50);
		expect(q.feesExact).toBe(true);
	});

	test("read.quoteRedeem dry-runs the close and returns NET proceeds", async () => {
		const pc = new PredictClient({ network: "testnet", client: mockClient().client });
		const q = await pc.read.quoteRedeem(
			OWNER,
			{ underlying: "BTC", expiryMs: EXPIRY, strike: 105_000, side: "up" },
			{ orderId: 7n, quantity: 0.02 },
		);
		expect(q.gross).toBe(6);
		expect(q.proceeds).toBe(5.95);
		expect(q.wouldLiquidate).toBe(false);
		expect(q.remaining).toBe(30);
		expect(q.feesExact).toBe(true);
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
