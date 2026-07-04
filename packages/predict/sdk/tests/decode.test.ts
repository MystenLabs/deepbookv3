import { bcs } from "@mysten/sui/bcs";
import { toBase64 } from "@mysten/sui/utils";
import { describe, expect, test } from "vitest";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import {
	decodeAccountsCreated,
	decodeClaims,
	decodeDeposits,
	decodeMints,
	decodePlpCancels,
	decodePlpRequests,
	decodeRedeems,
	type DecodableEvent,
} from "../src/decode.js";
import { PredictClient } from "../src/client.js";
import { PredictInputError } from "../src/errors.js";

// Fixtures serialize with layouts mirroring the deployed structs. NOTE: this
// round-trips the SDK's own layouts (field order vs chain is anchored by the
// verbatim-source comments in decode.ts and validated live for AccountCreated
// in the testnet smoke).

const MARKET = "0x" + "11".repeat(32);
const ACCOUNT = "0x" + "22".repeat(32);
const OWNER = "0x" + "33".repeat(32);
const VAULT = "0x" + "44".repeat(32);
const CODE = "0x" + "55".repeat(32);

const OrderMintedBcs = bcs.struct("OrderMinted", {
	expiry_market_id: bcs.Address,
	account_id: bcs.Address,
	order_id: bcs.u256(),
	position_root_id: bcs.u256(),
	owner: bcs.Address,
	lower_tick: bcs.u64(),
	higher_tick: bcs.u64(),
	leverage: bcs.u64(),
	entry_probability: bcs.u64(),
	quantity: bcs.u64(),
	net_premium: bcs.u64(),
	trading_fee: bcs.u64(),
	fee_incentive_subsidy: bcs.u64(),
	builder_fee: bcs.u64(),
	penalty_fee: bcs.u64(),
	builder_code_id: bcs.option(bcs.Address),
});

function mintedEvent(orderId: bigint, overrides: Record<string, unknown> = {}): DecodableEvent {
	return {
		eventType: `${cfg.packages.predict}::order_events::OrderMinted`,
		bcs: OrderMintedBcs.serialize({
			expiry_market_id: MARKET,
			account_id: ACCOUNT,
			order_id: orderId,
			position_root_id: orderId,
			owner: OWNER,
			lower_tick: 10_500_000n,
			higher_tick: (1n << 30n) - 1n,
			leverage: 2_000_000_000n,
			entry_probability: 300_000_000n,
			quantity: 50_000_000n,
			net_premium: 12_500_000n,
			trading_fee: 100_000n,
			fee_incentive_subsidy: 20_000n,
			builder_fee: 30_000n,
			penalty_fee: 5_000n,
			builder_code_id: CODE,
			...overrides,
		}).toBytes(),
	};
}

describe("decodeMints", () => {
	test("full receipt with human + raw units", () => {
		const [r] = decodeMints(cfg, { events: [mintedEvent(7n)] });
		expect(r.orderId).toBe(7n);
		expect(r.positionRootId).toBe(7n);
		expect(r.marketId).toBe(MARKET);
		expect(r.quantity).toBe(50); // $50 payout
		expect(r.netPremium).toBe(12.5);
		expect(r.entryProbability).toBeCloseTo(0.3);
		expect(r.leverage).toBe(2);
		expect(r.fees).toEqual({ trading: 0.1, subsidy: 0.02, builder: 0.03, penalty: 0.005 });
		expect(r.builderCodeId).toBe(CODE);
		expect(r.raw.quantity).toBe(50_000_000n);
		expect(r.raw.netPremium).toBe(12_500_000n);
	});

	test("batched PTB: N mints → N receipts, in order", () => {
		const receipts = decodeMints(cfg, { events: [mintedEvent(1n), mintedEvent(2n)] });
		expect(receipts.map((r) => r.orderId)).toEqual([1n, 2n]);
	});

	test("accepts base64-encoded bcs payloads", () => {
		const e = mintedEvent(9n);
		const [r] = decodeMints(cfg, {
			events: [{ ...e, bcs: toBase64(e.bcs as Uint8Array) }],
		});
		expect(r.orderId).toBe(9n);
	});

	test("None builder code → null", () => {
		const [r] = decodeMints(cfg, { events: [mintedEvent(1n, { builder_code_id: null })] });
		expect(r.builderCodeId).toBeNull();
	});

	test("foreign events are ignored", () => {
		const wrongPkg = {
			...mintedEvent(1n),
			eventType: `0x${"aa".repeat(32)}::order_events::OrderMinted`,
		};
		const wrongName = {
			...mintedEvent(1n),
			eventType: `${cfg.packages.predict}::order_events::SomethingElse`,
		};
		expect(decodeMints(cfg, { events: [wrongPkg, wrongName] })).toEqual([]);
	});

	test("facade singular: throws unless exactly one", () => {
		const pc = new PredictClient({
			network: "testnet",
			client: { simulateTransaction: async () => ({}) } as never,
		});
		expect(() => pc.decode.mint({ events: [] })).toThrow(PredictInputError);
		expect(() => pc.decode.mint({ events: [mintedEvent(1n), mintedEvent(2n)] })).toThrow(
			/found 2/,
		);
		expect(pc.decode.mint({ events: [mintedEvent(3n)] }).orderId).toBe(3n);
	});
});

describe("decodeRedeems", () => {
	const LiveOrderRedeemedBcs = bcs.struct("LiveOrderRedeemed", {
		expiry_market_id: bcs.Address,
		account_id: bcs.Address,
		order_id: bcs.u256(),
		position_root_id: bcs.u256(),
		owner: bcs.Address,
		quantity_closed: bcs.u64(),
		remaining_quantity: bcs.u64(),
		replacement_order_id: bcs.option(bcs.u256()),
		redeem_amount: bcs.u64(),
		trading_fee: bcs.u64(),
		builder_fee: bcs.u64(),
		penalty_fee: bcs.u64(),
		builder_code_id: bcs.option(bcs.Address),
	});

	function liveRedeem(replacement: bigint | null): DecodableEvent {
		return {
			eventType: `${cfg.packages.predict}::order_events::LiveOrderRedeemed`,
			bcs: LiveOrderRedeemedBcs.serialize({
				expiry_market_id: MARKET,
				account_id: ACCOUNT,
				order_id: 7n,
				position_root_id: 7n,
				owner: OWNER,
				quantity_closed: 20_000_000n,
				remaining_quantity: replacement == null ? 0n : 30_000_000n,
				replacement_order_id: replacement,
				redeem_amount: 6_000_000n,
				trading_fee: 50_000n,
				builder_fee: 0n,
				penalty_fee: 0n,
				builder_code_id: null,
			}).toBytes(),
		};
	}

	test("partial close surfaces the replacement order id", () => {
		const [r] = decodeRedeems(cfg, { events: [liveRedeem(8n)] });
		expect(r.replacementOrderId).toBe(8n);
		expect(r.remaining).toBe(30);
		expect(r.proceeds).toBe(6);
		expect(r.liquidated).toBe(false);
	});

	test("full close → replacement null", () => {
		const [r] = decodeRedeems(cfg, { events: [liveRedeem(null)] });
		expect(r.replacementOrderId).toBeNull();
		expect(r.remaining).toBe(0);
	});

	test("liquidated tombstone → zero payout, liquidated flag", () => {
		const LiquidatedBcs = bcs.struct("LiquidatedOrderRedeemed", {
			expiry_market_id: bcs.Address,
			account_id: bcs.Address,
			order_id: bcs.u256(),
			position_root_id: bcs.u256(),
			owner: bcs.Address,
			quantity_closed: bcs.u64(),
		});
		const [r] = decodeRedeems(cfg, {
			events: [
				{
					eventType: `${cfg.packages.predict}::order_events::LiquidatedOrderRedeemed`,
					bcs: LiquidatedBcs.serialize({
						expiry_market_id: MARKET,
						account_id: ACCOUNT,
						order_id: 7n,
						position_root_id: 7n,
						owner: OWNER,
						quantity_closed: 50_000_000n,
					}).toBytes(),
				},
			],
		});
		expect(r.liquidated).toBe(true);
		expect(r.proceeds).toBe(0);
		expect(r.quantityClosed).toBe(50);
	});
});

describe("other decoders", () => {
	test("claim receipt", () => {
		const SettledBcs = bcs.struct("SettledOrderRedeemed", {
			expiry_market_id: bcs.Address,
			account_id: bcs.Address,
			order_id: bcs.u256(),
			position_root_id: bcs.u256(),
			owner: bcs.Address,
			quantity_closed: bcs.u64(),
			settlement_price: bcs.u64(),
			payout_amount: bcs.u64(),
		});
		const [r] = decodeClaims(cfg, {
			events: [
				{
					eventType: `${cfg.packages.predict}::order_events::SettledOrderRedeemed`,
					bcs: SettledBcs.serialize({
						expiry_market_id: MARKET,
						account_id: ACCOUNT,
						order_id: 7n,
						position_root_id: 7n,
						owner: OWNER,
						quantity_closed: 50_000_000n,
						settlement_price: 106_000_000_000_000n,
						payout_amount: 50_000_000n,
					}).toBytes(),
				},
			],
		});
		expect(r.settlementPrice).toBe(106_000);
		expect(r.payout).toBe(50);
	});

	test("createManager receipt", () => {
		const AccountCreatedBcs = bcs.struct("AccountCreated", {
			account_id: bcs.Address,
			wrapper_id: bcs.Address,
			owner: bcs.Address,
			self_owned: bcs.bool(),
		});
		const [r] = decodeAccountsCreated(cfg, {
			events: [
				{
					eventType: `${cfg.packages.account}::account_events::AccountCreated`,
					bcs: AccountCreatedBcs.serialize({
						account_id: ACCOUNT,
						wrapper_id: VAULT,
						owner: OWNER,
						self_owned: true,
					}).toBytes(),
				},
			],
		});
		expect(r).toEqual({ accountId: ACCOUNT, wrapperId: VAULT, owner: OWNER, selfOwned: true });
	});

	test("deposit receipt carries new balance", () => {
		const DepositedBcs = bcs.struct("Deposited", {
			account_id: bcs.Address,
			coin_type: bcs.string(),
			amount: bcs.u64(),
			new_balance: bcs.u64(),
		});
		const [r] = decodeDeposits(cfg, {
			events: [
				{
					eventType: `${cfg.packages.account}::account_events::Deposited`,
					bcs: DepositedBcs.serialize({
						account_id: ACCOUNT,
						coin_type: cfg.quoteCoinType.slice(2),
						amount: 250_000_000n,
						new_balance: 1_000_000_000n,
					}).toBytes(),
				},
			],
		});
		expect(r.amount).toBe(250);
		expect(r.newBalance).toBe(1000);
	});

	test("plp request receipt yields the cancel index", () => {
		const SupplyRequestedBcs = bcs.struct("SupplyRequested", {
			pool_vault_id: bcs.Address,
			account_id: bcs.Address,
			recipient: bcs.Address,
			index: bcs.u64(),
			amount: bcs.u64(),
		});
		const [r] = decodePlpRequests(cfg, {
			events: [
				{
					eventType: `${cfg.packages.predict}::vault_events::SupplyRequested`,
					bcs: SupplyRequestedBcs.serialize({
						pool_vault_id: VAULT,
						account_id: ACCOUNT,
						recipient: OWNER,
						index: 42n,
						amount: 100_000_000n,
					}).toBytes(),
				},
			],
		});
		expect(r.kind).toBe("supply");
		expect(r.index).toBe(42n);
		expect(r.amount).toBe(100);
	});

	test("plp cancel receipt", () => {
		const RequestCancelledBcs = bcs.struct("RequestCancelled", {
			pool_vault_id: bcs.Address,
			account_id: bcs.Address,
			recipient: bcs.Address,
			index: bcs.u64(),
			amount: bcs.u64(),
			is_supply: bcs.bool(),
		});
		const [r] = decodePlpCancels(cfg, {
			events: [
				{
					eventType: `${cfg.packages.predict}::vault_events::RequestCancelled`,
					bcs: RequestCancelledBcs.serialize({
						pool_vault_id: VAULT,
						account_id: ACCOUNT,
						recipient: OWNER,
						index: 42n,
						amount: 100_000_000n,
						is_supply: true,
					}).toBytes(),
				},
			],
		});
		expect(r.index).toBe(42n);
		expect(r.isSupply).toBe(true);
	});

	test("missing bcs payload → descriptive error", () => {
		expect(() =>
			decodeMints(cfg, {
				events: [{ eventType: `${cfg.packages.predict}::order_events::OrderMinted` }],
			}),
		).toThrow(/events included/);
	});
});
