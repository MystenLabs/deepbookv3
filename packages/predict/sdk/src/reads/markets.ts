import { Transaction } from "@mysten/sui/transactions";
import { predictTarget, type PredictConfig } from "../config/index.js";
import { PredictMoveError } from "../errors.js";
import { loadLivePricer } from "../tx/trade.js";
import { inspectReturns, type ReadClient } from "./inspect.js";
import { parseOptionalId, parseOptionalU64, parseU64LE, parseVectorOfIds } from "./parse.js";

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
	/**
	 * The reference fine-grid tick (Polymarket-style anchor strike: derived
	 * on-chain from the exact previous-window oracle observation), or null while
	 * the keeper has not seeded it. Reference PRICE raw = tick * tickSizeRaw.
	 */
	referenceTickRaw: bigint | null;
}

// The per-market state commands, in fixed order. `expiry_market::{expiry,
// tick_size, mint_paused, reference_tick}` — see
// packages/predict/sources/expiry_market.move:{90,141,~230,149}. reference_tick
// returns Option (no abort risk), unlike settlement_price which is deliberately
// NOT batched here: on the deployed package it aborts for a live (unsettled)
// market — use `settlementPrice` below.
const STATE_FNS = ["expiry", "tick_size", "mint_paused", "reference_tick"] as const;

function parseStateAt(cmds: Uint8Array[][], base: number): MarketState {
	return {
		expiryMs: parseU64LE(cmds[base][0]),
		tickSizeRaw: parseU64LE(cmds[base + 1][0]),
		mintPaused: (cmds[base + 2][0][0] ?? 0) !== 0, // BCS bool: 1 byte
		referenceTickRaw: parseOptionalU64(cmds[base + 3][0]),
	};
}

export async function marketState(
	client: ReadClient,
	cfg: PredictConfig,
	marketId: string,
): Promise<MarketState> {
	const [state] = await marketStates(client, cfg, [marketId]);
	return state;
}

// Batched marketState for N markets in ONE PTB (STATE_FNS.length commands per
// market, same order). Returns states aligned with `marketIds`.
export async function marketStates(
	client: ReadClient,
	cfg: PredictConfig,
	marketIds: readonly string[],
): Promise<MarketState[]> {
	if (marketIds.length === 0) return [];
	const tx = new Transaction();
	for (const id of marketIds) {
		for (const fn of STATE_FNS) {
			tx.moveCall({
				target: predictTarget(cfg, "expiry_market", fn),
				arguments: [tx.object(id)],
			});
		}
	}
	const cmds = await inspectReturns(client, tx);
	return marketIds.map((_, i) => parseStateAt(cmds, STATE_FNS.length * i));
}

// Fresh single read of the reference tick — used by mint-at-reference, which
// must not trust a cached state (the reference is unset early in a window
// until the keeper seeds it).
export async function referenceTick(
	client: ReadClient,
	cfg: PredictConfig,
	marketId: string,
): Promise<bigint | null> {
	const tx = new Transaction();
	tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "reference_tick"),
		arguments: [tx.object(marketId)],
	});
	const [cmd0] = await inspectReturns(client, tx);
	return parseOptionalU64(cmd0[0]);
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
