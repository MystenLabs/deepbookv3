import { Transaction } from "@mysten/sui/transactions";
import { describe, expect, test } from "vitest";
import {
	ABORT_TABLES,
	PredictInputError,
	PredictMoveError,
	decodeMoveAbort,
} from "../src/errors.js";
import type { ReadClient } from "../src/reads/inspect.js";
import { inspectReturns } from "../src/reads/inspect.js";

// A representative failure string as the gRPC/JSON-RPC layer renders a MoveAbort.
const ABORT_STR =
	'MoveAbort(MoveLocation { module: ModuleId { address: 0000000000000000000000000000000000000000000000000000000000000abc, name: Identifier("expiry_market") }, function: 12, instruction: 34 }, 6)';

describe("decodeMoveAbort", () => {
	test("decodes a real abort string to module/code/name", () => {
		const e = decodeMoveAbort(ABORT_STR);
		expect(e).toBeInstanceOf(PredictMoveError);
		expect(e).toMatchObject({
			module: "expiry_market",
			code: 6n,
			abortName: "EMintQuantityBelowMin",
		});
	});

	test("known module, unknown code → abortName null", () => {
		const e = decodeMoveAbort(ABORT_STR.replace(/, 6\)$/, ", 99)"));
		expect(e?.module).toBe("expiry_market");
		expect(e?.code).toBe(99n);
		expect(e?.abortName).toBeNull();
	});

	test("unknown module → abortName null", () => {
		const e = decodeMoveAbort(ABORT_STR.replace("expiry_market", "nonsense_mod"));
		expect(e?.module).toBe("nonsense_mod");
		expect(e?.abortName).toBeNull();
	});

	test("u64 abort codes above 2^53 decode exactly (clever-error packing)", () => {
		const e = decodeMoveAbort(ABORT_STR.replace(/, 6\)$/, ", 9223372036854775814)"));
		expect(e?.code).toBe(9223372036854775814n);
		expect(e?.abortName).toBeNull();
	});

	test("non-abort string → null", () => {
		expect(decodeMoveAbort("some random error")).toBeNull();
		expect(decodeMoveAbort("InsufficientGas")).toBeNull();
		expect(decodeMoveAbort("")).toBeNull();
	});

	test("tolerates a trailing suffix after the abort code (e.g. ' in command 0')", () => {
		const e = decodeMoveAbort(`${ABORT_STR} in command 0`);
		expect(e).toMatchObject({ module: "expiry_market", code: 6n });
	});

	test("message includes module and abort name when known", () => {
		const msg = decodeMoveAbort(ABORT_STR)!.message;
		expect(msg).toContain("expiry_market");
		expect(msg).toContain("EMintQuantityBelowMin");
	});

	test("message includes the raw code when the abort is unnamed", () => {
		const msg = decodeMoveAbort(ABORT_STR.replace(/, 6\)$/, ", 99)"))!.message;
		expect(msg).toContain("expiry_market");
		expect(msg).toContain("99");
	});
});

describe("ABORT_TABLES", () => {
	test("carry the six covered modules with their seed values", () => {
		expect(ABORT_TABLES.expiry_market[6]).toBe("EMintQuantityBelowMin");
		expect(ABORT_TABLES.expiry_market[0]).toBe("EMintPaused");
		expect(ABORT_TABLES.plp[5]).toBe("EPlpPriceBelowCircuitBreaker");
		expect(ABORT_TABLES.plp[6]).toBe("EPlpPriceAboveCircuitBreaker");
		expect(ABORT_TABLES.lp_book[0]).toBe("ERequestNotFound");
		expect(ABORT_TABLES.predict_account[1]).toBe("EPositionNotFound");
		expect(ABORT_TABLES.account[0]).toBe("EInvalidOwner");
		expect(ABORT_TABLES.registry[0]).toBe("EPauseCapNotValid");
	});
});

describe("PredictInputError", () => {
	test("is an Error subclass carrying its message", () => {
		const e = new PredictInputError("bad input");
		expect(e).toBeInstanceOf(Error);
		expect(e.message).toBe("bad input");
	});
});

describe("inspectReturns decodes aborts on FailedTransaction", () => {
	function failingClient(error: unknown): ReadClient {
		return {
			async simulateTransaction() {
				return {
					$kind: "FailedTransaction",
					FailedTransaction: { status: { success: false, error } },
					commandResults: undefined,
				};
			},
		} as unknown as ReadClient;
	}

	test("throws PredictMoveError from the display `message` string", async () => {
		const client = failingClient({ message: ABORT_STR });
		const err = await inspectReturns(client, new Transaction()).catch((e) => e);
		expect(err).toBeInstanceOf(PredictMoveError);
		expect(err.abortName).toBe("EMintQuantityBelowMin");
	});

	test("throws PredictMoveError from the structured gRPC MoveAbort arm", async () => {
		const client = failingClient({
			$kind: "MoveAbort",
			message: "transaction aborted",
			MoveAbort: { abortCode: "6", location: { module: "expiry_market" } },
		});
		const err = await inspectReturns(client, new Transaction()).catch((e) => e);
		expect(err).toBeInstanceOf(PredictMoveError);
		expect(err.abortName).toBe("EMintQuantityBelowMin");
	});

	test("falls back to a plain Error when the abort cannot be decoded", async () => {
		const client = failingClient({ message: "InsufficientGas" });
		const err = await inspectReturns(client, new Transaction()).catch((e) => e);
		expect(err).toBeInstanceOf(Error);
		expect(err).not.toBeInstanceOf(PredictMoveError);
		expect(err.message).toContain("InsufficientGas");
	});
});
