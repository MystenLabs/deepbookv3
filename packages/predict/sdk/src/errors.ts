// Typed errors for the Predict SDK.
//
// Two failure kinds cross the SDK boundary:
//   - PredictInputError — a caller gave us something we rejected before touching
//     the chain (unknown underlying, malformed argument, …).
//   - PredictMoveError — a Move `abort` surfaced by a read/simulate. We decode the
//     on-chain module + code into the human abort name so callers can branch on
//     `abortName` / `code` instead of string-matching a rendered failure.

/** A caller-supplied argument the SDK rejected before building/sending a tx. */
export class PredictInputError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "PredictInputError";
	}
}

/** A Move `abort` decoded from a simulate/read failure. */
export class PredictMoveError extends Error {
	readonly module: string;
	readonly code: number;
	/** The `E…` constant name from the abort table, or null if unmapped. */
	readonly abortName: string | null;

	constructor(module: string, code: number, abortName: string | null) {
		super(
			abortName
				? `Move abort in ${module}: ${abortName} (code ${code})`
				: `Move abort in ${module}: code ${code}`,
		);
		this.name = "PredictMoveError";
		this.module = module;
		this.code = code;
		this.abortName = abortName;
	}
}

// Abort code → name, per module. Generated from the DEPLOYED sources at commit
// ec99cfae (this repo's packages/predict + packages/account): grep of
// `const E<Name>: u64 = <n>;` in each module. Regenerate from that same commit if
// the deployed package changes — a stale table mislabels a real abort.
export const ABORT_TABLES: Record<string, Record<number, string>> = {
	expiry_market: {
		0: "EMintPaused",
		1: "EFullCloseRequired",
		2: "EMarketNotSettled",
		3: "EWrongPythFeed",
		4: "EMintCostAboveMax",
		5: "EMintProbabilityAboveMax",
		6: "EMintQuantityBelowMin",
		7: "EWrongPricer",
		8: "EReferenceTickObservationMissing",
		9: "EReferenceTickTimestampMismatch",
		10: "EMintRedeemSameTimestamp",
	},
	plp: {
		0: "EExpiryMarketNotActive",
		1: "EExpiryMarketAlreadyValued",
		2: "EWrongPoolVault",
		3: "EMissingExpiryValuation",
		4: "ENotBootstrapped",
		5: "EPlpPriceBelowCircuitBreaker",
		6: "EPlpPriceAboveCircuitBreaker",
		7: "EAlreadyBootstrapped",
		8: "EPoolNavDust",
		9: "EBelowMinBootstrapLiquidity",
		10: "EBelowMinFeeIncentiveSponsorship",
		11: "EMarketNotSettled",
	},
	lp_book: {
		0: "ERequestNotFound",
		1: "EBelowMinSupplyRequest",
		2: "EBelowMinWithdrawRequest",
		3: "ENotRequestOwner",
		4: "EInvalidDrainMark",
	},
	predict_account: {
		0: "EPositionAlreadyExists",
		1: "EPositionNotFound",
		2: "EInsufficientPosition",
		3: "EExpirySummaryHasOpenPositions",
	},
	account: {
		0: "EInvalidOwner",
		1: "EBalanceTooLow",
		2: "EInvalidAuth",
	},
	registry: {
		0: "EPauseCapNotValid",
		1: "ELifecycleCapNotValid",
		2: "ELifecycleCapNotFound",
	},
};

// The module name lives inside `ModuleId { … name: Identifier("<module>") }`.
const MODULE_RE = /name:\s*Identifier\("([^"]+)"\)/;
// The abort code is the integer following the MoveLocation block, i.e. the last
// `, <n>)` in the string. The greedy `.*` skips ahead to that final occurrence,
// so a trailing suffix (e.g. " in command 0") after the code is tolerated.
const CODE_RE = /MoveAbort\(.*,\s*(\d+)\s*\)/s;

/**
 * Decode a rendered Move-abort failure string into a {@link PredictMoveError}.
 * Returns null when `raw` is not a MoveAbort. An abort in an unmapped module or
 * with an unmapped code still decodes (module/code populated, `abortName: null`).
 */
export function decodeMoveAbort(raw: string): PredictMoveError | null {
	if (typeof raw !== "string" || !raw.includes("MoveAbort")) return null;
	const moduleMatch = raw.match(MODULE_RE);
	const codeMatch = raw.match(CODE_RE);
	if (!moduleMatch || !codeMatch) return null;
	const module = moduleMatch[1];
	const code = Number(codeMatch[1]);
	const abortName = ABORT_TABLES[module]?.[code] ?? null;
	return new PredictMoveError(module, code, abortName);
}
