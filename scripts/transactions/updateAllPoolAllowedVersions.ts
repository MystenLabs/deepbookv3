// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../utils/utils.js';

const DEEPBOOK_PACKAGE_ID = '0x337f4f4f6567fcd778d5454f27c16c70e2f274cc6377ea6249ddf491482ef497';
const REGISTRY_ID = '0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d';
const POOL_CREATED_ENDPOINT = 'https://deepbook-indexer.mainnet.mystenlabs.com/pool_created';

const SIGNER = process.env.SIGNER;
const GAS_OBJECT = process.env.GAS_OBJECT;
if (!SIGNER) throw new Error('set SIGNER env var to the sender address');
if (!GAS_OBJECT) throw new Error('set GAS_OBJECT env var to a SUI coin object id owned by SIGNER');

// Split `Pool<Base, Quote>` type string into [Base, Quote] while respecting nested <>.
const splitTypeArgs = (typeStr: string): [string, string] => {
	const open = typeStr.indexOf('<');
	const close = typeStr.lastIndexOf('>');
	if (open < 0 || close < 0) throw new Error(`no type args in ${typeStr}`);
	const inner = typeStr.slice(open + 1, close);
	let depth = 0;
	let splitIdx = -1;
	for (let i = 0; i < inner.length; i++) {
		const c = inner[i];
		if (c === '<') depth++;
		else if (c === '>') depth--;
		else if (c === ',' && depth === 0) {
			splitIdx = i;
			break;
		}
	}
	if (splitIdx < 0) throw new Error(`could not split type args in ${typeStr}`);
	return [inner.slice(0, splitIdx).trim(), inner.slice(splitIdx + 1).trim()];
};

(async () => {
	const env = 'mainnet';
	const client = getClient(env);

	console.log(`Fetching pool list from ${POOL_CREATED_ENDPOINT}...`);
	const poolCreatedResp = await fetch(POOL_CREATED_ENDPOINT);
	if (!poolCreatedResp.ok) {
		throw new Error(`pool_created fetch failed: ${poolCreatedResp.status} ${poolCreatedResp.statusText}`);
	}
	const poolCreatedEvents = (await poolCreatedResp.json()) as { pool_id: string }[];
	const poolIds = [...new Set(poolCreatedEvents.map((e) => e.pool_id))];
	console.log(`Found ${poolIds.length} unique pools. Fetching coin types...`);

	const poolInfo = await Promise.all(
		poolIds.map(async (id) => {
			const res = await client.getObject({ id, options: { showType: true } });
			const typeStr = res.data?.type;
			if (!typeStr) throw new Error(`pool ${id} returned no type`);
			const [baseType, quoteType] = splitTypeArgs(typeStr);
			return { id, baseType, quoteType };
		}),
	);

	const tx = new Transaction();
	tx.setSender(SIGNER);
	const gasObj = await client.getObject({ id: GAS_OBJECT });
	if (!gasObj.data) throw new Error(`gas object ${GAS_OBJECT} not found`);
	tx.setGasPayment([
		{ objectId: gasObj.data.objectId, version: gasObj.data.version, digest: gasObj.data.digest },
	]);

	for (const { id, baseType, quoteType } of poolInfo) {
		tx.moveCall({
			target: `${DEEPBOOK_PACKAGE_ID}::pool::update_pool_allowed_versions`,
			arguments: [tx.object(id), tx.object(REGISTRY_ID)],
			typeArguments: [baseType, quoteType],
		});
	}

	const signer = getSigner();
	if (signer.getPublicKey().toSuiAddress() !== SIGNER) {
		throw new Error(
			`keypair address ${signer.getPublicKey().toSuiAddress()} does not match SIGNER ${SIGNER}`,
		);
	}

	const res = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showObjectChanges: true },
	});
	console.dir(res, { depth: null });
})();
