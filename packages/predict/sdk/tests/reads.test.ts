import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { normalizeSuiAddress } from "@mysten/sui/utils";
import { describe, expect, test } from "vitest";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import { PredictMoveError } from "../src/errors.js";
import { accountBalance } from "../src/reads/balances.js";
import type { ReadClient } from "../src/reads/inspect.js";
import { inspectReturns } from "../src/reads/inspect.js";
import {
	activeMarketIds,
	currentNav,
	expiryMarketId,
	marketState,
	settlementPrice,
} from "../src/reads/markets.js";
import {
	parseOptionalId,
	parseOptionalU64,
	parseU64LE,
	parseVectorOfIds,
} from "../src/reads/parse.js";
import { poolStats } from "../src/reads/pool.js";

// The moveCall targets in the order the read built its PTB.
function targets(tx: Transaction): string[] {
	return tx.getData().commands.flatMap((c) =>
		"MoveCall" in c && c.MoveCall
			? [`${c.MoveCall.package}::${c.MoveCall.module}::${c.MoveCall.function}`]
			: [],
	);
}

// A mock ReadClient: returns a canned SimulateTransactionResult-shaped value and
// captures the Transaction it was called with, plus the options. Result shape per
// node_modules/@mysten/sui/dist/client/types.d.mts:309-348 (commandResults[].returnValues[].bcs).
function mockClient(commandReturns: Uint8Array[][], kind: "Transaction" | "FailedTransaction" = "Transaction") {
	const captured: { tx?: Transaction; opts?: Record<string, unknown> } = {};
	const client = {
		async simulateTransaction(opts: { transaction: Transaction } & Record<string, unknown>) {
			captured.tx = opts.transaction;
			captured.opts = opts;
			return {
				$kind: kind,
				Transaction: {},
				FailedTransaction: {},
				commandResults: commandReturns.map((rvs) => ({
					returnValues: rvs.map((b) => ({ bcs: b })),
					mutatedReferences: [],
				})),
			};
		},
	} as unknown as ReadClient;
	return { client, captured };
}

const ADDR_A = normalizeSuiAddress("0x1");
const ADDR_B = normalizeSuiAddress("0xabc");

describe("parsers (pure, round-trip via bcs)", () => {
	test("parseU64LE round-trips a bcs u64", () => {
		expect(parseU64LE(bcs.u64().serialize(42n).toBytes())).toBe(42n);
		expect(parseU64LE(bcs.u64().serialize(0n).toBytes())).toBe(0n);
		const big = (1n << 64n) - 1n;
		expect(parseU64LE(bcs.u64().serialize(big).toBytes())).toBe(big);
	});

	test("parseVectorOfIds round-trips a bcs vector<address>", () => {
		expect(parseVectorOfIds(bcs.vector(bcs.Address).serialize([]).toBytes())).toEqual([]);
		expect(
			parseVectorOfIds(bcs.vector(bcs.Address).serialize([ADDR_A, ADDR_B]).toBytes()),
		).toEqual([ADDR_A, ADDR_B]);
	});

	test("parseOptionalU64 handles Some and None via bcs.option(bcs.u64())", () => {
		expect(parseOptionalU64(bcs.option(bcs.u64()).serialize(7n).toBytes())).toBe(7n);
		expect(parseOptionalU64(bcs.option(bcs.u64()).serialize(null).toBytes())).toBeNull();
	});

	test("parseOptionalId handles Some and None via bcs.option(bcs.Address)", () => {
		expect(parseOptionalId(bcs.option(bcs.Address).serialize(ADDR_B).toBytes())).toBe(ADDR_B);
		expect(parseOptionalId(bcs.option(bcs.Address).serialize(null).toBytes())).toBeNull();
	});
});

describe("inspectReturns (the network seam)", () => {
	test("sets sender, checksEnabled:false, include.commandResults; returns per-command bcs", async () => {
		const { client, captured } = mockClient([
			[bcs.u64().serialize(5n).toBytes()],
			[bcs.u64().serialize(6n).toBytes()],
		]);
		const tx = new Transaction();
		const out = await inspectReturns(client, tx);
		expect(captured.opts?.checksEnabled).toBe(false);
		expect((captured.opts?.include as { commandResults?: boolean }).commandResults).toBe(true);
		expect(captured.tx?.getData().sender).toBe(normalizeSuiAddress("0x0"));
		expect(out).toHaveLength(2);
		expect(parseU64LE(out[0][0])).toBe(5n);
		expect(parseU64LE(out[1][0])).toBe(6n);
	});

	test("honors an explicit sender", async () => {
		const { client, captured } = mockClient([[bcs.u64().serialize(1n).toBytes()]]);
		await inspectReturns(client, new Transaction(), ADDR_B);
		expect(captured.tx?.getData().sender).toBe(ADDR_B);
	});

	test("throws on FailedTransaction (abort)", async () => {
		const { client } = mockClient([], "FailedTransaction");
		await expect(inspectReturns(client, new Transaction())).rejects.toThrow();
	});
});

describe("markets reads", () => {
	test("activeMarketIds: plp::active_expiry_markets(vault), parses vector<ID>", async () => {
		const { client, captured } = mockClient([
			[bcs.vector(bcs.Address).serialize([ADDR_A, ADDR_B]).toBytes()],
		]);
		const ids = await activeMarketIds(client, cfg);
		expect(targets(captured.tx!)).toEqual([`${cfg.packages.predict}::plp::active_expiry_markets`]);
		expect(ids).toEqual([ADDR_A, ADDR_B]);
	});

	test("expiryMarketId: registry::expiry_market_id, Some → id", async () => {
		const { client, captured } = mockClient([
			[bcs.option(bcs.Address).serialize(ADDR_B).toBytes()],
		]);
		const id = await expiryMarketId(client, cfg, "BTC", 1_700_000_000_000n);
		expect(targets(captured.tx!)).toEqual([`${cfg.packages.predict}::registry::expiry_market_id`]);
		expect(id).toBe(ADDR_B);
	});

	test("expiryMarketId: None → null", async () => {
		const { client } = mockClient([[bcs.option(bcs.Address).serialize(null).toBytes()]]);
		expect(await expiryMarketId(client, cfg, "BTC", 1n)).toBeNull();
	});

	test("expiryMarketId: unknown underlying throws", async () => {
		const { client } = mockClient([]);
		await expect(expiryMarketId(client, cfg, "DOGE", 1n)).rejects.toThrow(/DOGE/);
	});

	test("marketState: one PTB with 3 reads, dispatched per command index", async () => {
		const { client, captured } = mockClient([
			[bcs.u64().serialize(1_700_000_000_000n).toBytes()], // expiry
			[bcs.u64().serialize(10_000_000n).toBytes()], // tick_size
			[bcs.bool().serialize(true).toBytes()], // mint_paused
		]);
		const s = await marketState(client, cfg, "0xdeadbeef");
		expect(targets(captured.tx!)).toEqual([
			`${cfg.packages.predict}::expiry_market::expiry`,
			`${cfg.packages.predict}::expiry_market::tick_size`,
			`${cfg.packages.predict}::expiry_market::mint_paused`,
		]);
		expect(s).toEqual({
			expiryMs: 1_700_000_000_000n,
			tickSizeRaw: 10_000_000n,
			mintPaused: true,
		});
	});

	test("settlementPrice: settled market → u64", async () => {
		const { client, captured } = mockClient([
			[bcs.u64().serialize(65_000_000_000_000n).toBytes()],
		]);
		const p = await settlementPrice(client, cfg, "0xdeadbeef");
		expect(targets(captured.tx!)).toEqual([
			`${cfg.packages.predict}::expiry_market::settlement_price`,
		]);
		expect(p).toBe(65_000_000_000_000n);
	});

	test("settlementPrice: unsettled market's option abort → null", async () => {
		// The deployed getter destroy_some()s the stored Option; unsettled markets
		// abort in std::option. The read maps exactly that abort to null.
		const client = {
			simulateTransaction: async () => {
				throw new PredictMoveError("option", 262145n, null);
			},
		} as unknown as ReadClient;
		expect(await settlementPrice(client, cfg, "0xdeadbeef")).toBeNull();
	});

	test("settlementPrice: unrelated aborts propagate", async () => {
		const client = {
			simulateTransaction: async () => {
				throw new PredictMoveError("expiry_market", 3n, "EWrongPythFeed");
			},
		} as unknown as ReadClient;
		await expect(settlementPrice(client, cfg, "0xdeadbeef")).rejects.toThrow(
			PredictMoveError,
		);
	});

	test("currentNav: load_live_pricer → current_nav, parses last command's u64", async () => {
		const { client, captured } = mockClient([
			[new Uint8Array([0])], // load_live_pricer's Pricer bytes (opaque here)
			[bcs.u64().serialize(999n).toBytes()], // current_nav
		]);
		const nav = await currentNav(client, cfg, "0xabc123", "BTC");
		expect(targets(captured.tx!)).toEqual([
			`${cfg.packages.predict}::expiry_market::load_live_pricer`,
			`${cfg.packages.predict}::expiry_market::current_nav`,
		]);
		expect(nav).toBe(999n);
	});

	test("currentNav: unknown underlying throws", async () => {
		const { client } = mockClient([]);
		await expect(currentNav(client, cfg, "0xabc123", "DOGE")).rejects.toThrow(/DOGE/);
	});
});

describe("balances read", () => {
	test("accountBalance: load_account → balance<T>, parses command 1's u64", async () => {
		const { client, captured } = mockClient([
			[], // load_account returns a &Account reference (no bcs return value)
			[bcs.u64().serialize(123_456n).toBytes()], // balance
		]);
		const bal = await accountBalance(client, cfg, ADDR_A);
		expect(targets(captured.tx!)).toEqual([
			`${cfg.packages.account}::account::load_account`,
			`${cfg.packages.account}::account::balance`,
		]);
		expect(bal).toBe(123_456n);
		// default coin type is the quote coin
		const balCmd = captured.tx!.getData().commands[1];
		expect(
			"MoveCall" in balCmd && balCmd.MoveCall?.typeArguments,
		).toEqual([cfg.quoteCoinType]);
	});

	test("accountBalance: honors an explicit coin type", async () => {
		const { client, captured } = mockClient([[], [bcs.u64().serialize(1n).toBytes()]]);
		await accountBalance(client, cfg, ADDR_A, "0x2::sui::SUI");
		const balCmd = captured.tx!.getData().commands[1];
		expect("MoveCall" in balCmd && balCmd.MoveCall?.typeArguments).toEqual(["0x2::sui::SUI"]);
	});
});

describe("pool read", () => {
	test("poolStats: one PTB, 4 plp reads, dispatched per command index", async () => {
		const { client, captured } = mockClient([
			[bcs.u64().serialize(1_000n).toBytes()], // plp_total_supply
			[bcs.u64().serialize(2_000n).toBytes()], // idle_balance
			[bcs.u64().serialize(3_000n).toBytes()], // supply_requests_pending
			[bcs.u64().serialize(4_000n).toBytes()], // withdraw_requests_pending
		]);
		const stats = await poolStats(client, cfg);
		expect(targets(captured.tx!)).toEqual([
			`${cfg.packages.predict}::plp::plp_total_supply`,
			`${cfg.packages.predict}::plp::idle_balance`,
			`${cfg.packages.predict}::plp::supply_requests_pending`,
			`${cfg.packages.predict}::plp::withdraw_requests_pending`,
		]);
		expect(stats).toEqual({
			plpTotalSupply: 1_000n,
			idleBalance: 2_000n,
			supplyRequestsPending: 3_000n,
			withdrawRequestsPending: 4_000n,
		});
	});
});
