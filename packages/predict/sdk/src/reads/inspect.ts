import type { SuiGrpcClient } from "@mysten/sui/grpc";
import type { Transaction } from "@mysten/sui/transactions";
import { normalizeSuiAddress } from "@mysten/sui/utils";

// The one network seam every read sits on. Structural — any object with a
// `simulateTransaction` matching the gRPC client's satisfies it, so callers can
// inject a mock in tests and the SDK never constructs its own transport.
export type ReadClient = Pick<SuiGrpcClient, "simulateTransaction">;

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
// default to the zero address. On abort the result's `$kind` is `FailedTransaction`.
// TODO(Task 9): decode the abort into a typed PredictMoveError; a plain Error for now.
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
	if (result.$kind === "FailedTransaction") {
		throw new Error("simulateTransaction aborted (FailedTransaction)");
	}
	const commands = result.commandResults;
	if (!commands) throw new Error("simulateTransaction returned no commandResults");
	return commands.map((c) => c.returnValues.map((rv) => rv.bcs));
}
