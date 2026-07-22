import type {
	Transaction,
	TransactionObjectArgument,
	TransactionResult,
} from "@mysten/sui/transactions";
import {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	accountTarget,
	type PredictConfig,
} from "../config/index.js";
import { generateAuth } from "./common.js";

// Create the sender's canonical derived account wrapper and share it. `new` derives the
// wrapper at a deterministic address (see `deriveAccountWrapperId`); `share` publishes
// the shared object the trade flows borrow against. See
// `packages/account/sources/account_registry.move:76` and `account.move:123`.
export function createAccount(cfg: PredictConfig, tx: Transaction): void {
	const wrapper = tx.moveCall({
		target: accountTarget(cfg, "account_registry", "new"),
		arguments: [tx.object(cfg.objects.accountRegistry)],
	});
	tx.moveCall({
		target: accountTarget(cfg, "account", "share"),
		arguments: [wrapper],
	});
}

// Deposit a caller-provided `coin` into the account's stored balance via the
// PTB-callable `deposit_funds` (folds settle → authorize → load → deposit). The caller
// owns coin sourcing. See `packages/account/sources/account.move:196`.
export function depositFunds(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; coin: TransactionObjectArgument; coinType?: string },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: accountTarget(cfg, "account", "deposit_funds"),
		typeArguments: [args.coinType ?? cfg.quoteCoinType],
		arguments: [
			tx.object(args.wrapperId),
			auth,
			args.coin,
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Withdraw `amountRaw` (raw u64 units) from the account's stored balance via the
// PTB-callable `withdraw_funds` (folds settle → authorize → load → withdraw), returning
// the minted `Coin<T>`. `ctx` is implicit in a PTB. See
// `packages/account/sources/account.move:209`.
export function withdrawFunds(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; amountRaw: bigint; coinType?: string },
): TransactionResult {
	const auth = generateAuth(cfg, tx);
	return tx.moveCall({
		target: accountTarget(cfg, "account", "withdraw_funds"),
		typeArguments: [args.coinType ?? cfg.quoteCoinType],
		arguments: [
			tx.object(args.wrapperId),
			auth,
			tx.pure.u64(args.amountRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}
