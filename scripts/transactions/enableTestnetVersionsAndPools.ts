// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { getSigner } from '../utils/utils.js';
import { adminCapID, adminCapOwner } from '../config/constants.js';

// JSON-RPC is switched off on the testnet fullnode (it 404s), so `utils.getClient` cannot be
// used here — talk to the same host over gRPC instead.
const GRPC_URL = 'https://fullnode.testnet.sui.io';

// deepbook testnet, package v20 (Published.toml [published.testnet].published-at).
const DEEPBOOK_PACKAGE_ID = '0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24';
const REGISTRY_ID = '0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1';
const ORIGINAL_PACKAGE_ID = '0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982';
const GRAPHQL_URL = 'https://graphql.testnet.sui.io/graphql';

// Testnet Registry.allowed_versions was {1,2,3,4,5}; mainnet is {1,2,3,4,5,6,8}.
// 6 = constants::CURRENT_VERSION of the previously deployed package, 8 = the current one.
// 7 was never a CURRENT_VERSION (the constant went 6 -> 8), which is why mainnet skips it.
const VERSIONS_TO_ENABLE = [6, 8];

// One tx per chunk of pools: each pool is a separate shared object, so a single
// giant PTB both risks the tx size limit and serializes on congestion.
const POOLS_PER_TX = 25;

const DRY_RUN = process.env.DRY_RUN === '1';

// Split `Pool<Base, Quote>` into [Base, Quote] while respecting nested <>.
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

// Enumerate every Pool object of the original package. The pool_created indexer
// endpoint used by updateAllPoolAllowedVersions.ts is mainnet-only.
const fetchPools = async (): Promise<{ id: string; base: string; quote: string }[]> => {
	const pools: { id: string; base: string; quote: string }[] = [];
	let after: string | null = null;
	do {
		const query = `{ objects(filter: {type: "${ORIGINAL_PACKAGE_ID}::pool::Pool"}, first: 50${
			after ? `, after: "${after}"` : ''
		}) { pageInfo { hasNextPage endCursor } nodes { address asMoveObject { contents { type { repr } } } } } }`;
		const resp = await fetch(GRAPHQL_URL, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ query }),
		});
		if (!resp.ok) throw new Error(`graphql ${resp.status} ${resp.statusText}`);
		const body = (await resp.json()) as any;
		if (body.errors) throw new Error(`graphql errors: ${JSON.stringify(body.errors)}`);
		const page = body.data.objects;
		for (const n of page.nodes) {
			const [base, quote] = splitTypeArgs(n.asMoveObject.contents.type.repr);
			pools.push({ id: n.address, base, quote });
		}
		after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
	} while (after);
	return pools;
};

(async () => {
	const env = 'testnet';
	const client = new SuiGrpcClient({ baseUrl: GRPC_URL, network: env });
	const signer = getSigner();
	const sender = signer.getPublicKey().toSuiAddress();

	if (sender !== adminCapOwner[env]) {
		throw new Error(
			`signer ${sender} is not the testnet adminCapOwner ${adminCapOwner[env]} — it cannot use DeepbookAdminCap ${adminCapID[env]}`,
		);
	}

	const pools = await fetchPools();
	console.log(`enabling versions [${VERSIONS_TO_ENABLE}] and refreshing ${pools.length} pools`);

	const execute = async (label: string, tx: Transaction) => {
		tx.setSender(sender);

		const res: any = DRY_RUN
			? await client.simulateTransaction({ transaction: tx })
			: await client.signAndExecuteTransaction({ transaction: tx, signer });

		const result = res.Transaction ?? res.transaction ?? res;
		const status = result?.status ?? result?.effects?.status;
		const digest: string | undefined = result?.digest ?? res?.digest;

		if (!status?.success) {
			console.dir(status ?? res, { depth: null });
			throw new Error(`${label} failed`);
		}
		if (digest && !DRY_RUN) await client.waitForTransaction({ digest });
		console.log(`${DRY_RUN ? '[dry-run] ' : ''}${label}: success${digest ? ` (${digest})` : ''}`);
	};

	// 1. Enable the versions on the Registry. `enable_version` asserts the version is not
	// already present (EVersionAlreadyEnabled), so only pass versions that are missing.
	const versionTx = new Transaction();
	for (const version of VERSIONS_TO_ENABLE) {
		versionTx.moveCall({
			target: `${DEEPBOOK_PACKAGE_ID}::registry::enable_version`,
			arguments: [
				versionTx.object(REGISTRY_ID),
				versionTx.pure.u64(version),
				versionTx.object(adminCapID[env]),
			],
		});
	}
	await execute(`enable_version ${VERSIONS_TO_ENABLE}`, versionTx);

	// 2. Refresh each pool's cached allowed_versions from the Registry. Pools cache the set
	// and never re-read it, so a pool that is not refreshed still rejects the new version.
	// `update_pool_allowed_versions` is permissionless and gate-exempt (pool.move:1070).
	for (let i = 0; i < pools.length; i += POOLS_PER_TX) {
		const chunk = pools.slice(i, i + POOLS_PER_TX);
		const tx = new Transaction();
		for (const pool of chunk) {
			tx.moveCall({
				target: `${DEEPBOOK_PACKAGE_ID}::pool::update_pool_allowed_versions`,
				arguments: [tx.object(pool.id), tx.object(REGISTRY_ID)],
				typeArguments: [pool.base, pool.quote],
			});
		}
		await execute(`pools ${i + 1}-${i + chunk.length} of ${pools.length}`, tx);
	}
})();
