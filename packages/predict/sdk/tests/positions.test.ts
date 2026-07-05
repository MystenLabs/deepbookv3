import { bcs } from "@mysten/sui/bcs";
import { deriveDynamicFieldID, normalizeSuiAddress } from "@mysten/sui/utils";
import { describe, expect, test } from "vitest";
import { PredictClient } from "../src/client.js";
import { TESTNET_CONFIG as cfg } from "../src/config/index.js";
import { PredictInputError } from "../src/errors.js";
import {
	positionsFromTable,
	resolvePositionsTable,
	type ObjectReadClient,
} from "../src/reads/positions.js";
import { deriveAccountWrapperId } from "../src/tx/common.js";

const OWNER = "0x" + "ab".repeat(32);
const ACCOUNT_UID = "0x" + "22".repeat(32);
const TABLE_ID = "0x" + "33".repeat(32);
const MARKET = "0x" + "44".repeat(32);

// Fixtures serialize with the same layouts as src (field order anchored to the
// deployed structs; the live smoke validates against the real chain).
const BagBcs = bcs.struct("Bag", { id: bcs.Address, size: bcs.u64() });
const wrapperContent = bcs
	.struct("AccountWrapper", {
		id: bcs.Address,
		account: bcs.struct("Account", {
			account_id: bcs.Address,
			owner: bcs.Address,
			receive_address: bcs.Address,
			balances: BagBcs,
			settlements: BagBcs,
		}),
	})
	.serialize({
		id: deriveAccountWrapperId(cfg, OWNER),
		account: {
			account_id: ACCOUNT_UID,
			owner: OWNER,
			receive_address: OWNER,
			balances: { id: "0x1", size: 0n },
			settlements: { id: "0x2", size: 0n },
		},
	})
	.toBytes();

const dataFieldContent = bcs
	.struct("Field", {
		id: bcs.Address,
		name: bcs.bool(), // DataKey's hidden dummy_field
		value: bcs.struct("PredictData", {
			positions: bcs.struct("T1", { id: bcs.Address, size: bcs.u64() }),
			expiry_summaries: bcs.struct("T2", { id: bcs.Address, size: bcs.u64() }),
			active_stake: bcs.u64(),
			inactive_stake: bcs.u64(),
			stake_epoch: bcs.u64(),
			builder_code_id: bcs.option(bcs.Address),
		}),
	})
	.serialize({
		id: "0x5",
		name: false,
		value: {
			positions: { id: TABLE_ID, size: 2n },
			expiry_summaries: { id: "0x6", size: 1n },
			active_stake: 0n,
			inactive_stake: 0n,
			stake_epoch: 1n,
			builder_code_id: null,
		},
	})
	.toBytes();

const keyBcs = (orderId: bigint) =>
	bcs
		.struct("PositionKey", { expiry_market_id: bcs.Address, order_id: bcs.u256() })
		.serialize({ expiry_market_id: MARKET, order_id: orderId })
		.toBytes();

const DATA_FIELD_ID = deriveDynamicFieldID(
	ACCOUNT_UID,
	`${cfg.packages.account}::account::DataKey<${cfg.packages.predict}::predict_account::PredictApp>`,
	new Uint8Array([0]),
);

function mockClient(opts: { pages?: number } = {}) {
	const pages = opts.pages ?? 1;
	const calls = { getObject: 0, listDynamicFields: 0 };
	const client = {
		async getObject({ objectId }: { objectId: string }) {
			calls.getObject++;
			if (normalizeSuiAddress(objectId) === normalizeSuiAddress(deriveAccountWrapperId(cfg, OWNER))) {
				return { object: { content: wrapperContent } };
			}
			if (normalizeSuiAddress(objectId) === normalizeSuiAddress(DATA_FIELD_ID)) {
				return { object: { content: dataFieldContent } };
			}
			throw new Error(`object not found: ${objectId}`);
		},
		async listDynamicFields({ cursor }: { parentId: string; cursor?: string }) {
			calls.listDynamicFields++;
			const page = cursor ? Number(cursor) : 0;
			const base = BigInt(page * 2);
			return {
				hasNextPage: page + 1 < pages,
				cursor: page + 1 < pages ? String(page + 1) : null,
				dynamicFields: [
					{ fieldId: "0x7", type: "", valueType: "", name: { type: "", bcs: keyBcs(base + 1n) } },
					{ fieldId: "0x8", type: "", valueType: "", name: { type: "", bcs: keyBcs(base + 2n) } },
				],
			};
		},
	} as unknown as ObjectReadClient;
	return { client, calls };
}

describe("position enumeration", () => {
	test("resolvePositionsTable walks wrapper → derived data field → table id", async () => {
		const { client, calls } = mockClient();
		const handle = await resolvePositionsTable(client, cfg, OWNER);
		expect(handle).toEqual({
			accountUid: ACCOUNT_UID,
			positionsTableId: TABLE_ID,
			positionCount: 2n,
		});
		expect(calls.getObject).toBe(2); // wrapper + derived field — no listing needed
	});

	test("never-onboarded owner → null handle, [] from the facade", async () => {
		const client = {
			async getObject() {
				throw new Error("Object 0xabc not found");
			},
			async listDynamicFields() {
				throw new Error("unreachable");
			},
		} as unknown as ObjectReadClient;
		expect(await resolvePositionsTable(client, cfg, OWNER)).toBeNull();
		const pc = new PredictClient({ network: "testnet", client: client as never });
		expect(await pc.read.positions(OWNER)).toEqual([]);
	});

	test("keys parse from dynamic-field names — no per-entry fetches", async () => {
		const { client, calls } = mockClient();
		const out = await positionsFromTable(client, TABLE_ID);
		expect(out).toEqual([
			{ marketId: MARKET, orderId: 1n },
			{ marketId: MARKET, orderId: 2n },
		]);
		expect(calls.getObject).toBe(0);
		expect(calls.listDynamicFields).toBe(1);
	});

	test("pagination follows cursors and maxPages guards runaways", async () => {
		const three = mockClient({ pages: 3 });
		const out = await positionsFromTable(three.client, TABLE_ID);
		expect(out.length).toBe(6);
		expect(three.calls.listDynamicFields).toBe(3);
		const many = mockClient({ pages: 99 });
		await expect(positionsFromTable(many.client, TABLE_ID, { maxPages: 2 })).rejects.toThrow(
			/maxPages/,
		);
	});

	test("facade caches the resolution: second call is one listing only", async () => {
		const { client, calls } = mockClient();
		const pc = new PredictClient({ network: "testnet", client: client as never });
		await pc.read.positions(OWNER);
		const afterFirst = { ...calls };
		await pc.read.positions(OWNER);
		expect(calls.getObject).toBe(afterFirst.getObject); // no re-resolution
		expect(calls.listDynamicFields).toBe(afterFirst.listDynamicFields + 1);
	});

	test("simulate-only client → pointed capability error", async () => {
		const pc = new PredictClient({
			network: "testnet",
			client: { simulateTransaction: async () => ({}) } as never,
		});
		await expect(pc.read.positions(OWNER)).rejects.toThrow(PredictInputError);
		await expect(pc.read.positions(OWNER)).rejects.toThrow(/getObject/);
	});
});
