import { bcs } from "@mysten/sui/bcs";
import type { Transaction, TransactionResult } from "@mysten/sui/transactions";
import { deriveObjectID } from "@mysten/sui/utils";
import { accountTarget, type PredictConfig } from "../config/index.js";

// Owner authority is a hot-potato `Auth` minted from the tx sender (`ctx` is implicit
// in a PTB) and consumed by the very next account-loading call (`load_account_mut`
// inside `deposit_funds` / `withdraw_funds` / `mint` / …). It resolves to owner auth
// for whoever signs the transaction. See `packages/account/sources/account.move:113`.
export function generateAuth(cfg: PredictConfig, tx: Transaction): TransactionResult {
	return tx.moveCall({ target: accountTarget(cfg, "account", "generate_auth"), arguments: [] });
}

// `AccountWrapperKey(address)` is a one-field positional struct, so its BCS is just the
// owner's 32-byte address. The wrapper is a derived object of the account registry, so
// its id is `derive_address(accountRegistry, AccountWrapperKey(owner))`. See
// `packages/account/sources/account_registry.move:39`.
const AccountWrapperKeyBcs = bcs.struct("AccountWrapperKey", {
	pos0: bcs.Address,
});

// The deterministic id of an owner's canonical account wrapper — no chain read needed.
export function deriveAccountWrapperId(cfg: PredictConfig, owner: string): string {
	const key = AccountWrapperKeyBcs.serialize({ pos0: owner }).toBytes();
	return deriveObjectID(
		cfg.objects.accountRegistry,
		`${cfg.packages.account}::account_registry::AccountWrapperKey`,
		key,
	);
}
