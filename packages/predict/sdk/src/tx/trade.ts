import type { Transaction, TransactionResult } from "@mysten/sui/transactions";
import {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	predictTarget,
	type PredictConfig,
} from "../config/index.js";
import { U64_MAX } from "../units.js";
import { generateAuth } from "./common.js";

// The four oracle feed object ids a live market's pricer / redeem paths read. Grouped
// so callers pass one bundle; the deployment's per-underlying ids live in
// `cfg.underlyings[symbol]` (see `src/config/testnet.ts`).
export interface MarketFeeds {
	pythFeedId: string;
	bsSpotFeedId: string;
	bsForwardFeedId: string;
	bsSviFeedId: string;
}

// Load a fresh `Pricer` from the four live oracle feeds. Every live-flow trade call
// (`mint_*`, `redeem_live`) borrows this `&Pricer` and it must be loaded first in the
// PTB. Ports harness `runtime.ts:804` (`load_live_pricer`, 8 args) against the deployed
// surface (`git show ec99cfae:.../expiry_market.move:167`). `ctx` is not a param here.
export function loadLivePricer(
	cfg: PredictConfig,
	tx: Transaction,
	args: { expiryMarketId: string } & MarketFeeds,
): TransactionResult {
	return tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "load_live_pricer"),
		arguments: [
			tx.object(args.expiryMarketId),
			tx.object(cfg.objects.protocolConfig),
			tx.object(cfg.objects.oracleRegistry),
			tx.object(args.pythFeedId),
			tx.object(args.bsSpotFeedId),
			tx.object(args.bsForwardFeedId),
			tx.object(args.bsSviFeedId),
			tx.object(CLOCK_ID),
		],
	});
}

// Mint a position of an exact `quantityRaw` at a fixed cost/probability ceiling, returning
// the new order id (u256). Command order is pricer → auth → mint (auth is a hot potato
// consumed by this call). Ports harness `runtime.ts:863` (`mint_exact_quantity`, 13 args,
// deployed sig `expiry_market.move:242`). `maxCostRaw`/`maxProbabilityRaw` default to
// `U64_MAX` (no slippage cap), matching the harness.
export function mintExactQuantity(
	cfg: PredictConfig,
	tx: Transaction,
	args: {
		expiryMarketId: string;
		wrapperId: string;
		lowerTick: bigint;
		higherTick: bigint;
		quantityRaw: bigint;
		leverageRaw: bigint;
		maxCostRaw?: bigint;
		maxProbabilityRaw?: bigint;
	} & MarketFeeds,
): TransactionResult {
	const pricer = loadLivePricer(cfg, tx, args);
	const auth = generateAuth(cfg, tx);
	return tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "mint_exact_quantity"),
		arguments: [
			tx.object(args.expiryMarketId),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			pricer,
			tx.pure.u64(args.lowerTick),
			tx.pure.u64(args.higherTick),
			tx.pure.u64(args.quantityRaw),
			tx.pure.u64(args.leverageRaw),
			tx.pure.u64(args.maxCostRaw ?? U64_MAX),
			tx.pure.u64(args.maxProbabilityRaw ?? U64_MAX),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Mint by spending an exact `amountRaw` (raw quote units), enforcing a `minQuantityRaw`
// floor on the position received, returning the new order id (u256). Command order is
// pricer → auth → mint. Deployed sig `expiry_market.move:293` (`mint_exact_amount`, 12
// moveCall args — note: no cost/probability ceilings, the floor is `min_quantity`).
export function mintExactAmount(
	cfg: PredictConfig,
	tx: Transaction,
	args: {
		expiryMarketId: string;
		wrapperId: string;
		lowerTick: bigint;
		higherTick: bigint;
		amountRaw: bigint;
		minQuantityRaw: bigint;
		leverageRaw: bigint;
	} & MarketFeeds,
): TransactionResult {
	const pricer = loadLivePricer(cfg, tx, args);
	const auth = generateAuth(cfg, tx);
	return tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "mint_exact_amount"),
		arguments: [
			tx.object(args.expiryMarketId),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			pricer,
			tx.pure.u64(args.lowerTick),
			tx.pure.u64(args.higherTick),
			tx.pure.u64(args.amountRaw),
			tx.pure.u64(args.minQuantityRaw),
			tx.pure.u64(args.leverageRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Owner-authorized redeem of a live (not-yet-settled) position: close `closeQuantityRaw`
// of `orderId` at the live pricer's mark, returning (proceeds u256, Option<order id>).
// Command order is pricer → auth → redeem.
//
// DEPLOYED SURFACE (drift guard): the live testnet contract's `redeem_live` takes NO
// `min_probability`/`min_proceeds` close-side slippage floors — 9 moveCall args, not the
// 11 the main-shaped harness `runtime.ts:891` passes. Authored from the deployed
// signature `git show ec99cfae:.../expiry_market.move:350`, NOT from runtime.ts.
export function redeemLive(
	cfg: PredictConfig,
	tx: Transaction,
	args: {
		expiryMarketId: string;
		wrapperId: string;
		orderId: bigint;
		closeQuantityRaw: bigint;
	} & MarketFeeds,
): TransactionResult {
	const pricer = loadLivePricer(cfg, tx, args);
	const auth = generateAuth(cfg, tx);
	return tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "redeem_live"),
		arguments: [
			tx.object(args.expiryMarketId),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			pricer,
			tx.pure.u256(args.orderId),
			tx.pure.u64(args.closeQuantityRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Permissionless redeem of a settled position: close `closeQuantityRaw` of `orderId`
// against the settlement pyth price, returning (proceeds u256, Option<order id>).
//
// DEPLOYED SURFACE (drift guard): this is the app-auth path — it takes `account_registry`
// and threads NO `Auth` hot potato, so there is no `generate_auth` call and no live
// `Pricer`. 10 moveCall args (market, accountRegistry, wrapper, config, oracleRegistry,
// pyth, order_id, close_quantity, root, clock). Deployed sig
// `git show ec99cfae:.../expiry_market.move:387`.
export function redeemSettled(
	cfg: PredictConfig,
	tx: Transaction,
	args: {
		expiryMarketId: string;
		wrapperId: string;
		orderId: bigint;
		closeQuantityRaw: bigint;
		pythFeedId: string;
	},
): TransactionResult {
	return tx.moveCall({
		target: predictTarget(cfg, "expiry_market", "redeem_settled"),
		arguments: [
			tx.object(args.expiryMarketId),
			tx.object(cfg.objects.accountRegistry),
			tx.object(args.wrapperId),
			tx.object(cfg.objects.protocolConfig),
			tx.object(cfg.objects.oracleRegistry),
			tx.object(args.pythFeedId),
			tx.pure.u256(args.orderId),
			tx.pure.u64(args.closeQuantityRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}
