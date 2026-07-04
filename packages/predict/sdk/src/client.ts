import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction, coinWithBalance } from "@mysten/sui/transactions";
import { getConfig, type PredictConfig } from "./config/index.js";
import {
	decodeAccountsCreated,
	decodeBuilderCodeSets,
	decodeClaims,
	decodeDeposits,
	decodeMints,
	decodePlpCancels,
	decodePlpRequests,
	decodeRedeems,
	decodeWithdrawals,
	exactlyOne,
	type DecodableTransactionResult,
} from "./decode.js";
import { PredictInputError } from "./errors.js";
import type { ReadClient } from "./reads/inspect.js";
import { accountBalance, hasPosition } from "./reads/balances.js";
import {
	activeMarketIds,
	currentNav,
	expiryMarketId,
	marketState,
	marketStates,
	type MarketState,
} from "./reads/markets.js";
import { poolStats } from "./reads/pool.js";
import { binaryRangeTicks, type Side } from "./ticks.js";
import { createAccount, depositFunds, withdrawFunds } from "./tx/account.js";
import { setBuilderCode, unsetBuilderCode } from "./tx/builderCode.js";
import { deriveAccountWrapperId } from "./tx/common.js";
import {
	cancelSupplyRequest,
	cancelWithdrawRequest,
	requestSupply,
	requestWithdraw,
} from "./tx/plp.js";
import type { MarketFeeds } from "./tx/trade.js";
import { mintExactAmount, mintExactQuantity, redeemLive, redeemSettled } from "./tx/trade.js";
import {
	leverageToRaw,
	priceToRaw,
	probabilityToRaw,
	rawToUsdc,
	usdcToRaw,
	fromRaw,
} from "./units.js";

// `position_lot_size` — a position quantity must be a whole multiple of this many
// raw payout units ($0.01 lots). See packages/predict/sources/constants.move:34.
const POSITION_LOT_SIZE = 10_000n;

/** A live/settled binary market addressed by its human coordinates. */
export interface MarketDescriptor {
	underlying: string;
	expiryMs: number | bigint;
	strike: number;
	side: Side;
}

/** Options for the friendly `mint` (exact payout quantity). */
export interface MintOptions {
	quantity: number;
	leverage?: number;
	maxCost?: number;
	maxProbability?: number;
}

/** Options for `mintAmount` (spend an exact amount, floor the quantity received). */
export interface MintAmountOptions {
	spend: number;
	minQuantity: number;
	leverage?: number;
}

/** Options for `redeem` / `claimSettled`: which order and how much to close. */
export interface CloseOptions {
	orderId: bigint;
	quantity: number;
}

/** One tradeable market as returned by read.markets(). */
export interface ActiveMarket {
	id: string;
	expiryMs: bigint;
	/** Strike granularity in USD (e.g. 0.01). */
	tickSize: number;
	mintPaused: boolean;
}

/** A resolved live market: its on-chain state summary for the caller. */
export interface MarketSummary {
	id: string;
	expiryMs: bigint;
	tickSize: number;
	mintPaused: boolean;
	nav: number;
}

/** Aggregate pool figures, in human units (shares raw, everything else scaled). */
export interface PoolSummary {
	plpTotalSupply: bigint;
	idleUsdc: number;
	supplyPending: number;
	withdrawPending: number;
}

interface ResolvedMarket {
	id: string;
	state: MarketState;
}

/**
 * The one object an app constructs. Wraps the config, a gRPC client for reads, and
 * a derived-account model so callers pass owner addresses, decimal amounts, and
 * human market coordinates — the facade converts to raw units, resolves markets
 * (cached), and delegates to the tx primitives / reads. Every primitive stays
 * exported for callers that need to compose their own PTBs.
 */
export class PredictClient {
	readonly cfg: PredictConfig;
	private readonly client: ReadClient;
	// underlying:expiryMs → resolved market. The id and tickSizeRaw — the only
	// state tx building depends on — are immutable per (underlying, expiry), so
	// one resolution per market per client suffices. (mintPaused IS mutable; the
	// cached copy is never consulted for a tx decision — the chain enforces it.)
	private readonly marketCache = new Map<string, ResolvedMarket>();

	constructor(opts: {
		network: "testnet" | "mainnet";
		client: SuiGrpcClient | ReadClient;
		config?: PredictConfig;
	}) {
		this.cfg = opts.config ?? getConfig(opts.network);
		this.client = opts.client;
	}

	/** The deterministic id of an owner's canonical account wrapper — no chain read. */
	wrapperIdFor(owner: string): string {
		return deriveAccountWrapperId(this.cfg, owner);
	}

	// The four oracle feed ids for a symbol; throws a typed error on an unknown symbol.
	private feeds(underlying: string): MarketFeeds {
		const u = this.cfg.underlyings[underlying];
		if (!u) throw new PredictInputError(`unknown underlying: ${underlying}`);
		return {
			pythFeedId: u.pythFeedId,
			bsSpotFeedId: u.bsSpotFeedId,
			bsForwardFeedId: u.bsForwardFeedId,
			bsSviFeedId: u.bsSviFeedId,
		};
	}

	// Resolve (and cache) a market's id + state from its human coordinates.
	private async resolveMarket(m: Pick<MarketDescriptor, "underlying" | "expiryMs">): Promise<ResolvedMarket> {
		const expiryMs = BigInt(m.expiryMs);
		const key = `${m.underlying}:${expiryMs}`;
		const hit = this.marketCache.get(key);
		if (hit) return hit;
		const id = await expiryMarketId(this.client, this.cfg, m.underlying, expiryMs);
		if (!id) throw new PredictInputError(`no market for ${m.underlying} at expiry ${expiryMs}`);
		const state = await marketState(this.client, this.cfg, id);
		const resolved: ResolvedMarket = { id, state };
		this.marketCache.set(key, resolved);
		return resolved;
	}

	// Raw payout quantity must land on a lot boundary — the chain rejects otherwise.
	private assertLot(quantityRaw: bigint): void {
		if (quantityRaw % POSITION_LOT_SIZE !== 0n) {
			throw new PredictInputError(
				`quantity ${quantityRaw} raw is not a whole ${POSITION_LOT_SIZE}-unit lot (position_lot_size)`,
			);
		}
	}

	// === tx builders ===
	// Each returns a ready-to-sign Transaction. Market-resolving builders are async.
	readonly tx = {
		createManager: (): Transaction => {
			const tx = new Transaction();
			createAccount(this.cfg, tx);
			return tx;
		},

		deposit: (owner: string, amountUsdc: number | string): Transaction => {
			const tx = new Transaction();
			const coin = tx.add(
				coinWithBalance({
					type: this.cfg.quoteCoinType,
					balance: usdcToRaw(amountUsdc),
					useGasCoin: false,
				}),
			);
			depositFunds(this.cfg, tx, { wrapperId: this.wrapperIdFor(owner), coin });
			return tx;
		},

		withdraw: (owner: string, amountUsdc: number | string): Transaction => {
			const tx = new Transaction();
			const coin = withdrawFunds(this.cfg, tx, {
				wrapperId: this.wrapperIdFor(owner),
				amountRaw: usdcToRaw(amountUsdc),
			});
			tx.transferObjects([coin], owner);
			return tx;
		},

		mint: async (owner: string, m: MarketDescriptor, opts: MintOptions): Promise<Transaction> => {
			const feeds = this.feeds(m.underlying);
			const { id, state } = await this.resolveMarket(m);
			const quantityRaw = usdcToRaw(opts.quantity);
			this.assertLot(quantityRaw);
			const { lowerTick, higherTick } = binaryRangeTicks(
				priceToRaw(m.strike),
				m.side,
				state.tickSizeRaw,
			);
			const tx = new Transaction();
			mintExactQuantity(this.cfg, tx, {
				expiryMarketId: id,
				wrapperId: this.wrapperIdFor(owner),
				lowerTick,
				higherTick,
				quantityRaw,
				leverageRaw: leverageToRaw(opts.leverage ?? 1),
				maxCostRaw: opts.maxCost != null ? usdcToRaw(opts.maxCost) : undefined,
				maxProbabilityRaw:
					opts.maxProbability != null ? probabilityToRaw(opts.maxProbability) : undefined,
				...feeds,
			});
			return tx;
		},

		mintAmount: async (
			owner: string,
			m: MarketDescriptor,
			opts: MintAmountOptions,
		): Promise<Transaction> => {
			const feeds = this.feeds(m.underlying);
			const { id, state } = await this.resolveMarket(m);
			// No lot check: min_quantity is a floor the chain compares against an
			// already-lot-floored minted quantity, so any floor value is legal.
			const minQuantityRaw = usdcToRaw(opts.minQuantity);
			const { lowerTick, higherTick } = binaryRangeTicks(
				priceToRaw(m.strike),
				m.side,
				state.tickSizeRaw,
			);
			const tx = new Transaction();
			mintExactAmount(this.cfg, tx, {
				expiryMarketId: id,
				wrapperId: this.wrapperIdFor(owner),
				lowerTick,
				higherTick,
				amountRaw: usdcToRaw(opts.spend),
				minQuantityRaw,
				leverageRaw: leverageToRaw(opts.leverage ?? 1),
				...feeds,
			});
			return tx;
		},

		redeem: async (
			owner: string,
			m: MarketDescriptor,
			opts: CloseOptions,
		): Promise<Transaction> => {
			const feeds = this.feeds(m.underlying);
			const { id } = await this.resolveMarket(m);
			const closeQuantityRaw = usdcToRaw(opts.quantity);
			this.assertLot(closeQuantityRaw);
			const tx = new Transaction();
			redeemLive(this.cfg, tx, {
				expiryMarketId: id,
				wrapperId: this.wrapperIdFor(owner),
				orderId: opts.orderId,
				closeQuantityRaw,
				...feeds,
			});
			return tx;
		},

		claimSettled: async (
			owner: string,
			m: MarketDescriptor,
			opts: CloseOptions,
		): Promise<Transaction> => {
			const feeds = this.feeds(m.underlying);
			const { id } = await this.resolveMarket(m);
			const closeQuantityRaw = usdcToRaw(opts.quantity);
			this.assertLot(closeQuantityRaw);
			const tx = new Transaction();
			redeemSettled(this.cfg, tx, {
				expiryMarketId: id,
				wrapperId: this.wrapperIdFor(owner),
				orderId: opts.orderId,
				closeQuantityRaw,
				pythFeedId: feeds.pythFeedId,
			});
			return tx;
		},

		supplyPlp: (owner: string, amountUsdc: number | string): Transaction => {
			const tx = new Transaction();
			requestSupply(this.cfg, tx, {
				wrapperId: this.wrapperIdFor(owner),
				amountRaw: usdcToRaw(amountUsdc),
			});
			return tx;
		},

		withdrawPlp: (owner: string, shares: bigint): Transaction => {
			const tx = new Transaction();
			requestWithdraw(this.cfg, tx, {
				wrapperId: this.wrapperIdFor(owner),
				sharesRaw: shares,
			});
			return tx;
		},

		cancelSupplyPlp: (owner: string, index: bigint): Transaction => {
			const tx = new Transaction();
			cancelSupplyRequest(this.cfg, tx, { wrapperId: this.wrapperIdFor(owner), index });
			return tx;
		},

		cancelWithdrawPlp: (owner: string, index: bigint): Transaction => {
			const tx = new Transaction();
			cancelWithdrawRequest(this.cfg, tx, { wrapperId: this.wrapperIdFor(owner), index });
			return tx;
		},

		setBuilderCode: (owner: string, builderCodeId: string): Transaction => {
			const tx = new Transaction();
			setBuilderCode(this.cfg, tx, { wrapperId: this.wrapperIdFor(owner), builderCodeId });
			return tx;
		},

		unsetBuilderCode: (owner: string): Transaction => {
			const tx = new Transaction();
			unsetBuilderCode(this.cfg, tx, { wrapperId: this.wrapperIdFor(owner) });
			return tx;
		},
	};

	// === reads ===
	readonly read = {
		// All tradeable (active) markets with the state a frontend needs to render
		// and mint: one chain read for ids + one batched PTB for the states.
		markets: async (): Promise<ActiveMarket[]> => {
			const ids = await activeMarketIds(this.client, this.cfg);
			const states = await marketStates(this.client, this.cfg, ids);
			return ids.map((id, i) => ({
				id,
				expiryMs: states[i].expiryMs,
				tickSize: fromRaw(states[i].tickSizeRaw, 9),
				mintPaused: states[i].mintPaused,
			}));
		},

		// Validate an app-stored order id against the chain (stale after full
		// close or partial-close replacement — see RedeemReceipt.replacementOrderId).
		hasPosition: (owner: string, marketId: string, orderId: bigint): Promise<boolean> =>
			hasPosition(this.client, this.cfg, owner, marketId, orderId),

		market: async (
			m: Pick<MarketDescriptor, "underlying" | "expiryMs">,
		): Promise<MarketSummary | null> => {
			const expiryMs = BigInt(m.expiryMs);
			// Deliberately re-queries and overwrites the cache instead of reading
			// through it: this read must return live state (nav, mintPaused), and
			// refreshing the cache on the way keeps later tx builds consistent.
			const id = await expiryMarketId(this.client, this.cfg, m.underlying, expiryMs);
			if (!id) return null;
			const state = await marketState(this.client, this.cfg, id);
			this.marketCache.set(`${m.underlying}:${expiryMs}`, { id, state });
			const navRaw = await currentNav(this.client, this.cfg, id, m.underlying);
			return {
				id,
				expiryMs: state.expiryMs,
				tickSize: fromRaw(state.tickSizeRaw, 9), // strike/price scale
				mintPaused: state.mintPaused,
				nav: rawToUsdc(navRaw),
			};
		},

		balance: async (owner: string): Promise<number> =>
			rawToUsdc(await accountBalance(this.client, this.cfg, owner)),

		// PLP shares held in the owner's account custody (raw u64, 6-decimal PLP coin).
		plpBalance: (owner: string): Promise<bigint> =>
			accountBalance(this.client, this.cfg, owner, `${this.cfg.packages.predict}::plp::PLP`),

		pool: async (): Promise<PoolSummary> => {
			const s = await poolStats(this.client, this.cfg);
			return {
				plpTotalSupply: s.plpTotalSupply, // shares raw (6-decimal)
				idleUsdc: rawToUsdc(s.idleBalance),
				supplyPending: rawToUsdc(s.supplyRequestsPending), // DUSDC queued
				withdrawPending: fromRaw(s.withdrawRequestsPending, 6), // PLP shares queued
			};
		},
	};

	// === execution-result decoders ===
	// Pure event parsing (no network): pass the executed/simulated transaction
	// result (with events included) and get a typed receipt back. Singular forms
	// throw unless exactly one matching event exists; plural forms return all
	// (an integrator batching N actions in one PTB gets N receipts).
	readonly decode = {
		mint: (r: DecodableTransactionResult) => exactlyOne(decodeMints(this.cfg, r), "OrderMinted"),
		mints: (r: DecodableTransactionResult) => decodeMints(this.cfg, r),
		redeem: (r: DecodableTransactionResult) =>
			exactlyOne(decodeRedeems(this.cfg, r), "order-redeemed"),
		redeems: (r: DecodableTransactionResult) => decodeRedeems(this.cfg, r),
		claim: (r: DecodableTransactionResult) =>
			exactlyOne(decodeClaims(this.cfg, r), "SettledOrderRedeemed"),
		claims: (r: DecodableTransactionResult) => decodeClaims(this.cfg, r),
		createManager: (r: DecodableTransactionResult) =>
			exactlyOne(decodeAccountsCreated(this.cfg, r), "AccountCreated"),
		deposit: (r: DecodableTransactionResult) =>
			exactlyOne(decodeDeposits(this.cfg, r), "Deposited"),
		withdraw: (r: DecodableTransactionResult) =>
			exactlyOne(decodeWithdrawals(this.cfg, r), "Withdrawn"),
		plpRequest: (r: DecodableTransactionResult) =>
			exactlyOne(decodePlpRequests(this.cfg, r), "supply/withdraw-requested"),
		plpCancel: (r: DecodableTransactionResult) =>
			exactlyOne(decodePlpCancels(this.cfg, r), "RequestCancelled"),
		builderCode: (r: DecodableTransactionResult) =>
			exactlyOne(decodeBuilderCodeSets(this.cfg, r), "BuilderCodeSet"),
	};
}
