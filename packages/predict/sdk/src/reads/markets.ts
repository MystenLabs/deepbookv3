import { Transaction } from "@mysten/sui/transactions";
import { predictTarget, type PredictConfig } from "../config/index.js";
import { PredictMoveError } from "../errors.js";
import { loadLivePricer } from "../tx/trade.js";
import { inspectReturns, type ReadClient } from "./inspect.js";
import { parseOptionalId, parseU64LE, parseVectorOfIds } from "./parse.js";

// On-chain ids of the pool's active (live, not-yet-settled) expiry markets.
// `plp::active_expiry_markets(vault)` — see packages/predict/sources/plp/plp.move:182.
export async function activeMarketIds(client: ReadClient, cfg: PredictConfig): Promise<string[]> {
	const tx = new Transaction();
	tx.moveCall({
		target: predictTarget(cfg, "plp", "active_expiry_markets"),
		arguments: [tx.object(cfg.objects.poolVault)],
	});
	const [cmd0] = await inspectReturns(client, tx);
	return parseVectorOfIds(cmd0[0]);
}

// The expiry market id for one underlying at one expiry, or null if none exists.
// `registry::expiry_market_id(registry, propbook_underlying_id: u32, expiry: u64):
// Option<ID>` — see packages/predict/sources/registry/registry.move:54.
export async function expiryMarketId(
	client: ReadClient,
	cfg: PredictConfig,
	underlying: string,
	expiryMs: bigint,
): Promise<string | null> {
	const u = cfg.underlyings[underlying];
	if (!u) throw new Error(`unknown underlying: ${underlying}`);
	const tx = new Transaction();
	tx.moveCall({
		target: predictTarget(cfg, "registry", "expiry_market_id"),
		arguments: [
			tx.object(cfg.objects.registry),
			tx.pure.u32(u.propbookUnderlyingId),
			tx.pure.u64(expiryMs),
		],
	});
	const [cmd0] = await inspectReturns(client, tx);
	return parseOptionalId(cmd0[0]);
}

export interface MarketState {
	expiryMs: bigint;
	tickSizeRaw: bigint;
	mintPaused: boolean;
}

// A market's three single-arg state reads batched into one PTB (command order fixed
// below). `expiry_market::{expiry, tick_size, mint_paused}` — see
// packages/predict/sources/expiry_market.move:{90,146,234}. Settlement price is
// deliberately NOT batched here: on the deployed package it aborts for a live
// (unsettled) market — use `settlementPrice` below.
export async function marketState(
	client: ReadClient,
	cfg: PredictConfig,
	marketId: string,
): Promise<MarketState> {
	const tx = new Transaction();
	for (const fn of ["expiry", "tick_size", "mint_paused"]) {
		tx.moveCall({
			target: predictTarget(cfg, "expiry_market", fn),
			arguments: [tx.object(marketId)],
		});
	}
	const cmds = await inspectReturns(client, tx);
	return {
		expiryMs: parseU64LE(cmds[0][0]),
		tickSizeRaw: parseU64LE(cmds[1][0]),
		mintPaused: (cmds[2][0][0] ?? 0) !== 0, // BCS bool: 1 byte
	};
}

// Batched marketState for N markets in ONE PTB (3 commands per market, same
// order as marketState). Returns states aligned with `marketIds`.
export async function marketStates(
	client: ReadClient,
	cfg: PredictConfig,
	marketIds: readonly string[],
): Promise<MarketState[]> {
	if (marketIds.length === 0) return [];
	const tx = new Transaction();
	for (const id of marketIds) {
		for (const fn of ["expiry", "tick_size", "mint_paused"]) {
			tx.moveCall({
				target: predictTarget(cfg, "expiry_market", fn),
				arguments: [tx.object(id)],
			});
		}
	}
	const cmds = await inspectReturns(client, tx);
	return marketIds.map((_, i) => ({
		expiryMs: parseU64LE(cmds[3 * i][0]),
		tickSizeRaw: parseU64LE(cmds[3 * i + 1][0]),
		mintPaused: (cmds[3 * i + 2][0][0] ?? 0) !== 0,
	}));
}

// The recorded settlement price, or null while the market is unsettled.
//
// On the deployed package `expiry_market::settlement_price` is public(package) and
// `destroy_some`s the stored Option — callable here only because simulate runs with
// checksEnabled:false, and it aborts in std::option (EOPTION_NOT_SET) when the
// market has not settled; we map exactly that abort (and the public
// EMarketNotSettled variant, should a future package guard it directly) to null.
export async function settlementPrice(
	client: ReadClient,
	cfg: PredictConfig,
	marketId: string,
): Promise<bigint | null> {
	const tx = new Transaction();
	tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "settlement_price"),
		arguments: [tx.object(marketId)],
	});
	try {
		const [cmd0] = await inspectReturns(client, tx);
		return parseU64LE(cmd0[0]);
	} catch (e) {
		if (
			e instanceof PredictMoveError &&
			(e.module === "option" ||
				(e.module === "expiry_market" && e.abortName === "EMarketNotSettled"))
		) {
			return null;
		}
		throw e;
	}
}

// A market's current NAV mark (the per-expiry recoverable value the flush prices
// against). Loads a fresh live pricer, then reads `current_nav(market, &pricer)` —
// see packages/predict/sources/expiry_market.move:221 and harness runtime.ts:476-481.
// `Pricer` has copy+drop, so the unconsumed borrow is fine in a read-only inspect.
export async function currentNav(
	client: ReadClient,
	cfg: PredictConfig,
	marketId: string,
	underlying: string,
): Promise<bigint> {
	const u = cfg.underlyings[underlying];
	if (!u) throw new Error(`unknown underlying: ${underlying}`);
	const tx = new Transaction();
	const pricer = loadLivePricer(cfg, tx, {
		expiryMarketId: marketId,
		pythFeedId: u.pythFeedId,
		bsSpotFeedId: u.bsSpotFeedId,
		bsForwardFeedId: u.bsForwardFeedId,
		bsSviFeedId: u.bsSviFeedId,
	});
	tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "current_nav"),
		arguments: [tx.object(marketId), pricer],
	});
	const cmds = await inspectReturns(client, tx);
	// current_nav is the last command; load_live_pricer precedes it.
	return parseU64LE(cmds[cmds.length - 1][0]);
}
