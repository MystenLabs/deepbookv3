import type { SuiGrpcClient } from "@mysten/sui/grpc";
import type { Transaction } from "@mysten/sui/transactions";
import { normalizeSuiAddress } from "@mysten/sui/utils";
import { decodeMoveAbort } from "../errors.js";

// The one network seam every read sits on. Structural — any object with a
// `simulateTransaction` matching the gRPC client's satisfies it, so callers can
// inject a mock in tests and the SDK never constructs its own transport.
export type ReadClient = Pick<SuiGrpcClient, "simulateTransaction">;

// The abort payload the failed simulate result carries. Read structurally (not via
// the client's exported ExecutionError type) so mocks and future API-shape drift
// still satisfy it. Two renderings occur: a display `message` string of the form
// `MoveAbort(MoveLocation { … name: Identifier("expiry_market") … }, 6)`, and the
// structured gRPC `MoveAbort` enum arm `{ abortCode, location: { module } }`.
type SimAbortError = {
	message?: string;
	MoveAbort?: { abortCode?: string | number; location?: { module?: string } };
};

// Normalize either abort rendering to the string decodeMoveAbort understands.
// Prefer the structured arm (synthesize a canonical MoveAbort string from it) and
// fall back to the display message.
function abortRawString(error: SimAbortError | undefined): string | undefined {
	if (!error) return undefined;
	const ma = error.MoveAbort;
	if (ma?.location?.module != null && ma.abortCode != null) {
		return `MoveAbort(MoveLocation { module: ModuleId { name: Identifier("${ma.location.module}") }, function: 0, instruction: 0 }, ${ma.abortCode})`;
	}
	return error.message;
}

// Run a read-only PTB through the gRPC `simulateTransaction` (the devInspect
// replacement) and return each command's BCS return values, indexed
// [commandIndex][returnValueIndex].
//
// `checksEnabled: false` disables validation so we may inspect non-entry public
// funs — see SimulateTransactionOptions.checksEnabled in
// node_modules/@mysten/sui/dist/client/types.d.mts:385-396. Per-command outputs
// live under `commandResults[i].returnValues[j].bcs` — see
// SimulateTransactionResult / CommandResult / CommandOutput in that same file at
// lines 309-348. `commandResults` is only populated when `include.commandResults`
// is set, so we request it explicitly.
//
// A sender is required to simulate; callers rarely have one for a pure read, so we
// default to the zero address. On abort the result's `$kind` is `FailedTransaction`;
// we decode the carried abort into a typed PredictMoveError, falling back to a plain
// Error with the failure message when it isn't a decodable Move abort.
// Shared failure handling: decode the abort carried by a FailedTransaction
// into a typed PredictMoveError, else throw a plain Error.
function throwSimFailure(failed: unknown): never {
	const status = (failed as { status?: { success: boolean; error?: SimAbortError } })?.status;
	const error = status && status.success === false ? status.error : undefined;
	const raw = abortRawString(error);
	const decoded = raw != null ? decodeMoveAbort(raw) : null;
	if (decoded) throw decoded;
	throw new Error(error?.message ?? "simulateTransaction aborted (FailedTransaction)");
}

// Simulate a full transaction (typically one built by a tx.* builder) and return
// the events it would emit — the quote path: dry-run the real action, decode the
// receipt. Sender must be the acting owner so account auth resolves. Throws the
// same typed errors the real execution would surface.
export async function simulateWithEvents(
	client: ReadClient,
	tx: Transaction,
	sender: string,
): Promise<{ eventType?: string; bcs?: Uint8Array | string }[]> {
	tx.setSender(sender);
	const result = await client.simulateTransaction<{ events: true }>({
		transaction: tx,
		checksEnabled: false,
		include: { events: true },
	});
	if (result.$kind === "FailedTransaction") throwSimFailure(result.FailedTransaction);
	return (result.Transaction?.events ?? []) as { eventType?: string; bcs?: Uint8Array }[];
}

export async function inspectReturns(
	client: ReadClient,
	tx: Transaction,
	sender: string = normalizeSuiAddress("0x0"),
): Promise<Uint8Array[][]> {
	tx.setSender(sender);
	const result = await client.simulateTransaction<{ commandResults: true }>({
		transaction: tx,
		checksEnabled: false,
		include: { commandResults: true },
	});
	if (result.$kind === "FailedTransaction") throwSimFailure(result.FailedTransaction);
	const commands = result.commandResults;
	if (!commands) throw new Error("simulateTransaction returned no commandResults");
	return commands.map((c) => c.returnValues.map((rv) => rv.bcs));
}
