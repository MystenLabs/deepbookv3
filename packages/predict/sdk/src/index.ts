export const SDK_NAME = "@mysten/predict";

// === Facade ===
export { PredictClient } from "./client.js";
export type {
	ActiveMarket,
	MarketDescriptor,
	MarketSummary,
	MintOptions,
	MintAmountOptions,
	CloseOptions,
	PoolSummary,
} from "./client.js";

// === Config + target seam ===
export {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	TESTNET_CONFIG,
	accountTarget,
	getConfig,
	predictTarget,
} from "./config/index.js";
export type { PredictConfig, PredictPackages, UnderlyingConfig } from "./config/index.js";

// === Units ===
export {
	U64_MAX,
	fromRaw,
	leverageToRaw,
	priceToRaw,
	probabilityToRaw,
	rawToPrice,
	rawToProbability,
	rawToUsdc,
	toRaw,
	usdcToRaw,
} from "./units.js";

// === Ticks ===
export { POS_INF_TICK, binaryRangeTicks } from "./ticks.js";
export type { Side } from "./ticks.js";

// === Errors ===
export {
	ABORT_TABLES,
	PredictInputError,
	PredictMoveError,
	decodeMoveAbort,
} from "./errors.js";

// === Transaction primitives ===
export {
	loadLivePricer,
	mintExactAmount,
	mintExactQuantity,
	redeemLive,
	redeemSettled,
} from "./tx/trade.js";
export type { MarketFeeds } from "./tx/trade.js";
export { createAccount, depositFunds, withdrawFunds } from "./tx/account.js";
export { deriveAccountWrapperId, generateAuth } from "./tx/common.js";
export {
	cancelSupplyRequest,
	cancelWithdrawRequest,
	requestSupply,
	requestWithdraw,
} from "./tx/plp.js";
export { setBuilderCode, unsetBuilderCode } from "./tx/builderCode.js";

// === Reads ===
export { inspectReturns } from "./reads/inspect.js";
export type { ReadClient } from "./reads/inspect.js";
export {
	activeMarketIds,
	currentNav,
	expiryMarketId,
	marketState,
	marketStates,
	settlementPrice,
} from "./reads/markets.js";
export type { MarketState } from "./reads/markets.js";
export { accountBalance, hasPosition } from "./reads/balances.js";
export { poolStats } from "./reads/pool.js";
export type { PoolStats } from "./reads/pool.js";

// === Execution-result decoders (pure event parsing, no network) ===
export {
	decodeAccountsCreated,
	decodeBuilderCodeSets,
	decodeClaims,
	decodeDeposits,
	decodeMints,
	decodePlpCancels,
	decodePlpRequests,
	decodeRedeems,
	decodeWithdrawals,
} from "./decode.js";
export type {
	BalanceChangeReceipt,
	BuilderCodeReceipt,
	ClaimReceipt,
	CreateManagerReceipt,
	DecodableEvent,
	DecodableTransactionResult,
	MintReceipt,
	PlpCancelReceipt,
	PlpRequestReceipt,
	RedeemReceipt,
} from "./decode.js";
export {
	parseOptionalId,
	parseOptionalU64,
	parseU64LE,
	parseVectorOfIds,
} from "./reads/parse.js";
