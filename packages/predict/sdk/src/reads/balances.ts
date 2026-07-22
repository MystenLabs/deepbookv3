import { Transaction } from "@mysten/sui/transactions";
import {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	accountTarget,
	predictTarget,
	type PredictConfig,
} from "../config/index.js";
import { deriveAccountWrapperId } from "../tx/common.js";
import { inspectReturns, type ReadClient } from "./inspect.js";
import { parseU64LE } from "./parse.js";

// An owner's stored account balance for a coin type (defaults to the quote coin,
// DUSDC on testnet). Chains `account::load_account(wrapper)` →
// `account::balance<T>(account, root, clock)`; the u64 is command 1's return —
// see packages/account/sources/account.move:{86,92} and harness runtime.ts:458-466.
// The wrapper id is derived off-chain (no read needed).
export async function accountBalance(
	client: ReadClient,
	cfg: PredictConfig,
	owner: string,
	coinType: string = cfg.quoteCoinType,
): Promise<bigint> {
	const wrapperId = deriveAccountWrapperId(cfg, owner);
	const tx = new Transaction();
	const account = tx.moveCall({
		target: accountTarget(cfg, "account", "load_account"),
		arguments: [tx.object(wrapperId)],
	});
	tx.moveCall({
		target: accountTarget(cfg, "account", "balance"),
		typeArguments: [coinType],
		arguments: [account, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
	});
	const cmds = await inspectReturns(client, tx);
	return parseU64LE(cmds[1][0]);
}

// Whether the owner's account still holds `orderId` on `marketId`. The cheap
// on-chain validator for app-stored order ids (stale after a full close or a
// partial-close replacement — see RedeemReceipt.replacementOrderId). Chains
// `account::load_account(wrapper)` → `predict_account::has_position(account,
// market_id, order_id)` — see packages/predict/sources/predict_account.move:86.
export async function hasPosition(
	client: ReadClient,
	cfg: PredictConfig,
	owner: string,
	marketId: string,
	orderId: bigint,
): Promise<boolean> {
	const wrapperId = deriveAccountWrapperId(cfg, owner);
	const tx = new Transaction();
	const account = tx.moveCall({
		target: accountTarget(cfg, "account", "load_account"),
		arguments: [tx.object(wrapperId)],
	});
	tx.moveCall({
		target: predictTarget(cfg, "predict_account", "has_position"),
		arguments: [account, tx.pure.id(marketId), tx.pure.u256(orderId)],
	});
	const cmds = await inspectReturns(client, tx);
	return (cmds[1][0][0] ?? 0) !== 0; // BCS bool: 1 byte
}
