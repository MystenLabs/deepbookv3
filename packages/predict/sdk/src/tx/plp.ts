import type { Transaction } from "@mysten/sui/transactions";
import {
	ACCUMULATOR_ROOT_ID,
	CLOCK_ID,
	predictTarget,
	type PredictConfig,
} from "../config/index.js";
import { generateAuth } from "./common.js";

// Queue a supply request pulling `amountRaw` (raw DUSDC u64) from the account's existing
// custody balance. `request_supply` auto-settles DUSDC then `account.withdraw`s the payment
// into queue escrow; the PLP fill is delivered at the next flush, not returned here. Command
// order is auth → request (auth is a hot potato consumed by this call). Ports harness
// `requestSupplyFromCustodyTx` (runtime.ts:1260) against deployed sig
// `git show ec99cfae:.../plp/plp.move:517` — 7 moveCall args (ctx implicit).
export function requestSupply(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; amountRaw: bigint },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "plp", "request_supply"),
		arguments: [
			tx.object(cfg.objects.poolVault),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			tx.pure.u64(args.amountRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Queue a withdraw request pulling `sharesRaw` (raw PLP u64) from account custody into queue
// escrow. Auto-settles flush-delivered PLP first; the DUSDC fill lands on the account at the
// next flush (no `withdraw_settled` entrypoint). Command order is auth → request. Ports
// harness `requestWithdrawTx` (runtime.ts:1288); deployed sig `.../plp/plp.move:545` — 7 args.
export function requestWithdraw(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; sharesRaw: bigint },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "plp", "request_withdraw"),
		arguments: [
			tx.object(cfg.objects.poolVault),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			tx.pure.u64(args.sharesRaw),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Cancel a still-pending supply request by queue `index`, refunding its escrowed DUSDC
// straight back into the requesting account. Command order is auth → cancel. Deployed sig
// `.../plp/plp.move:571` — same 7-arg shape as request_supply with `index` in the u64 slot.
export function cancelSupplyRequest(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; index: bigint },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "plp", "cancel_supply_request"),
		arguments: [
			tx.object(cfg.objects.poolVault),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			tx.pure.u64(args.index),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}

// Cancel a still-pending withdraw request by queue `index`, refunding its escrowed PLP
// straight back into the requesting account. Command order is auth → cancel. Deployed sig
// `.../plp/plp.move:594` — same 7-arg shape with `index` in the u64 slot.
export function cancelWithdrawRequest(
	cfg: PredictConfig,
	tx: Transaction,
	args: { wrapperId: string; index: bigint },
): void {
	const auth = generateAuth(cfg, tx);
	tx.moveCall({
		target: predictTarget(cfg, "plp", "cancel_withdraw_request"),
		arguments: [
			tx.object(cfg.objects.poolVault),
			tx.object(args.wrapperId),
			auth,
			tx.object(cfg.objects.protocolConfig),
			tx.pure.u64(args.index),
			tx.object(ACCUMULATOR_ROOT_ID),
			tx.object(CLOCK_ID),
		],
	});
}
