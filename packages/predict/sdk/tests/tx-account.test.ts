import { Transaction } from "@mysten/sui/transactions";
import { expect, test } from "vitest";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import { createAccount, depositFunds, withdrawFunds } from "../src/tx/account.js";
import { deriveAccountWrapperId } from "../src/tx/common.js";

function targets(tx: Transaction): string[] {
	return tx.getData().commands.flatMap((c) =>
		"MoveCall" in c && c.MoveCall
			? [`${c.MoveCall.package}::${c.MoveCall.module}::${c.MoveCall.function}`]
			: [],
	);
}

test("createAccount = registry.new → share", () => {
	const tx = new Transaction();
	createAccount(cfg, tx);
	expect(targets(tx)).toEqual([
		`${cfg.packages.account}::account_registry::new`,
		`${cfg.packages.account}::account::share`,
	]);
});

test("depositFunds: auth then deposit_funds<DUSDC>", () => {
	const tx = new Transaction();
	const coin = tx.object("0xc0");
	depositFunds(cfg, tx, { wrapperId: "0x123", coin });
	const t = targets(tx);
	expect(t[0]).toBe(`${cfg.packages.account}::account::generate_auth`);
	expect(t[1]).toBe(`${cfg.packages.account}::account::deposit_funds`);
	expect(tx.getData().commands[1].MoveCall!.typeArguments).toEqual([cfg.quoteCoinType]);
});

test("depositFunds honors coinType override", () => {
	const tx = new Transaction();
	const coin = tx.object("0xc0");
	depositFunds(cfg, tx, { wrapperId: "0x123", coin, coinType: "0x2::sui::SUI" });
	expect(tx.getData().commands[1].MoveCall!.typeArguments).toEqual(["0x2::sui::SUI"]);
});

test("withdrawFunds: auth then withdraw_funds<DUSDC> with amount", () => {
	const tx = new Transaction();
	withdrawFunds(cfg, tx, { wrapperId: "0x123", amountRaw: 5_000_000n });
	const t = targets(tx);
	expect(t[0]).toBe(`${cfg.packages.account}::account::generate_auth`);
	expect(t[1]).toBe(`${cfg.packages.account}::account::withdraw_funds`);
	const call = tx.getData().commands[1].MoveCall!;
	expect(call.typeArguments).toEqual([cfg.quoteCoinType]);
});

test("wrapper id derivation is deterministic", () => {
	const a = deriveAccountWrapperId(cfg, "0x" + "ab".repeat(32));
	expect(a).toMatch(/^0x[0-9a-f]{64}$/);
	expect(deriveAccountWrapperId(cfg, "0x" + "ab".repeat(32))).toBe(a);
});
