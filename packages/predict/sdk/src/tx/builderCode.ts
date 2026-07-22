import type { Transaction } from "@mysten/sui/transactions";
import { predictTarget, type PredictConfig } from "../config/index.js";
import { generateAuth } from "./common.js";

// Set the account's sticky builder-code attribution to `builderCodeId`, an existing
// `BuilderCode` object borrowed as `&BuilderCode`. Command order is auth → set (auth is a
// hot potato consumed by this call). Lives in the PREDICT package's `predict_account`
// module, NOT the account package. Deployed sig
// `git show ec99cfae:packages/predict/sources/predict_account.move:125` — 3 moveCall args
// (wrapper, auth, code; ctx implicit).
export function setBuilderCode(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; builderCodeId: string },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "predict_account", "set_builder_code"),
		arguments: [tx.object(args.wrapperId), auth, tx.object(args.builderCodeId)],
	});
}

// Clear the account's sticky builder-code attribution. Command order is auth → unset.
// Deployed sig `.../predict_account.move:142` — 2 moveCall args (wrapper, auth; ctx implicit).
export function unsetBuilderCode(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "predict_account", "unset_builder_code"),
		arguments: [tx.object(args.wrapperId), auth],
	});
}
