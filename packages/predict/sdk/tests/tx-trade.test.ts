import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { expect, test } from "vitest";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import { U64_MAX } from "../src/units.js";
import {
	loadLivePricer,
	mintExactAmount,
	mintExactQuantity,
	redeemLive,
	redeemSettled,
} from "../src/tx/trade.js";

const btc = cfg.underlyings.BTC;
const feeds = {
	pythFeedId: btc.pythFeedId,
	bsSpotFeedId: btc.bsSpotFeedId,
	bsForwardFeedId: btc.bsForwardFeedId,
	bsSviFeedId: btc.bsSviFeedId,
};

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

// Resolve the base64 pure bytes an argument points at, or undefined if the
// argument is not a pure input (e.g. it's an object or a command result).
function argPureBytes(tx: Transaction, cmdIdx: number, argIdx: number): string | undefined {
	const arg = call(tx, cmdIdx).arguments[argIdx] as { $kind: string; Input?: number };
	if (arg.$kind !== "Input" || arg.Input === undefined) return undefined;
	const input = tx.getData().inputs[arg.Input];
	return "Pure" in input && input.Pure ? input.Pure.bytes : undefined;
}

const U64_MAX_B64 = Buffer.from(bcs.u64().serialize(U64_MAX).toBytes()).toString("base64");

test("loadLivePricer: 8 args to expiry_market::load_live_pricer", () => {
	const tx = new Transaction();
	loadLivePricer(cfg, tx, { expiryMarketId: "0xabc", ...feeds });
	expect(targets(tx)).toEqual([`${cfg.packages.predict}::expiry_market::load_live_pricer`]);
	expect(call(tx, 0).arguments).toHaveLength(8);
});

test("mintExactQuantity: pricer → auth → mint, 13 args", () => {
	const tx = new Transaction();
	mintExactQuantity(cfg, tx, {
		expiryMarketId: "0xabc",
		wrapperId: "0xdef",
		lowerTick: 10n,
		higherTick: 20n,
		quantityRaw: 1_000_000n,
		leverageRaw: 1_000_000_000n,
		...feeds,
	});
	expect(targets(tx)).toEqual([
		`${cfg.packages.predict}::expiry_market::load_live_pricer`,
		`${cfg.packages.account}::account::generate_auth`,
		`${cfg.packages.predict}::expiry_market::mint_exact_quantity`,
	]);
	const mint = call(tx, 2);
	expect(mint.arguments).toHaveLength(13);
	// arg order: [market, wrapper, auth(Result), config, pricer(Result), lower, higher,
	//             quantity, leverage, maxCost, maxProbability, root, clock]
	expect(mint.arguments[2].$kind).toBe("Result"); // auth
	expect(mint.arguments[4].$kind).toBe("Result"); // pricer
	// defaults: maxCost (idx 9) and maxProbability (idx 10) = U64_MAX
	expect(argPureBytes(tx, 2, 9)).toBe(U64_MAX_B64);
	expect(argPureBytes(tx, 2, 10)).toBe(U64_MAX_B64);
});

test("mintExactQuantity: explicit maxCost/maxProbability override defaults", () => {
	const tx = new Transaction();
	mintExactQuantity(cfg, tx, {
		expiryMarketId: "0xabc",
		wrapperId: "0xdef",
		lowerTick: 10n,
		higherTick: 20n,
		quantityRaw: 1_000_000n,
		leverageRaw: 1_000_000_000n,
		maxCostRaw: 5_000_000n,
		maxProbabilityRaw: 900_000_000n,
		...feeds,
	});
	expect(argPureBytes(tx, 2, 9)).toBe(
		Buffer.from(bcs.u64().serialize(5_000_000n).toBytes()).toString("base64"),
	);
	expect(argPureBytes(tx, 2, 10)).toBe(
		Buffer.from(bcs.u64().serialize(900_000_000n).toBytes()).toString("base64"),
	);
	expect(argPureBytes(tx, 2, 9)).not.toBe(U64_MAX_B64);
});

test("mintExactAmount: pricer → auth → mint, 12 args", () => {
	const tx = new Transaction();
	mintExactAmount(cfg, tx, {
		expiryMarketId: "0xabc",
		wrapperId: "0xdef",
		lowerTick: 10n,
		higherTick: 20n,
		amountRaw: 5_000_000n,
		minQuantityRaw: 1_000_000n,
		leverageRaw: 1_000_000_000n,
		...feeds,
	});
	expect(targets(tx)).toEqual([
		`${cfg.packages.predict}::expiry_market::load_live_pricer`,
		`${cfg.packages.account}::account::generate_auth`,
		`${cfg.packages.predict}::expiry_market::mint_exact_amount`,
	]);
	const mint = call(tx, 2);
	expect(mint.arguments).toHaveLength(12);
	expect(mint.arguments[2].$kind).toBe("Result"); // auth
	expect(mint.arguments[4].$kind).toBe("Result"); // pricer
});

test("redeemLive: pricer → auth → redeem, 9 args, NO slippage-floor pair", () => {
	const tx = new Transaction();
	redeemLive(cfg, tx, {
		expiryMarketId: "0xabc",
		wrapperId: "0xdef",
		orderId: 42n,
		closeQuantityRaw: 500_000n,
		...feeds,
	});
	expect(targets(tx)).toEqual([
		`${cfg.packages.predict}::expiry_market::load_live_pricer`,
		`${cfg.packages.account}::account::generate_auth`,
		`${cfg.packages.predict}::expiry_market::redeem_live`,
	]);
	const redeem = call(tx, 2);
	// deployed: market, wrapper, auth, config, pricer, order_id u256, close_quantity u64,
	//           root, clock  →  9 moveCall args (drift guard: main has 11 with two floors)
	expect(redeem.arguments).toHaveLength(9);
	expect(redeem.arguments[2].$kind).toBe("Result"); // auth
	expect(redeem.arguments[4].$kind).toBe("Result"); // pricer
	// after close_quantity (idx 6) come root and clock objects — NOT a pure u64 floor pair
	expect(argPureBytes(tx, 2, 7)).toBeUndefined(); // root object, not pure
	expect(argPureBytes(tx, 2, 8)).toBeUndefined(); // clock object, not pure
});

test("redeemSettled: 10 args, app-auth (no generate_auth in tx)", () => {
	const tx = new Transaction();
	redeemSettled(cfg, tx, {
		expiryMarketId: "0xabc",
		wrapperId: "0xdef",
		orderId: 42n,
		closeQuantityRaw: 500_000n,
		pythFeedId: btc.pythFeedId,
	});
	expect(targets(tx)).toEqual([
		`${cfg.packages.predict}::expiry_market::redeem_settled`,
	]);
	// no auth command anywhere
	expect(targets(tx)).not.toContain(`${cfg.packages.account}::account::generate_auth`);
	const redeem = call(tx, 0);
	// market, accountRegistry, wrapper, config, oracleRegistry, pyth, order_id u256,
	// close_quantity u64, root, clock  →  10 moveCall args
	expect(redeem.arguments).toHaveLength(10);
	// all object/pure inputs (no command results) — app-auth path threads no Auth
	for (const a of redeem.arguments) expect(a.$kind).toBe("Input");
});
