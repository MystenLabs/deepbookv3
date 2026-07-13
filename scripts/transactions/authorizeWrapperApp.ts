// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { getSigner } from '../utils/utils.js';
import { adminCapID, adminCapOwner } from '../config/constants.js';

// Authorize an app (e.g. the account wrapper) against deepbook core's Registry, so its calls pass
// `registry::assert_app_is_authorized<App>`. Admin-cap gated; testnet is NOT multisig, so this is
// a single direct tx from the adminCapOwner address.
//
// Usage:
//   WRAPPER_APP_TYPE=0x<pkg>::<module>::<AppWitness> DRY_RUN=1 pnpm tsx transactions/authorizeWrapperApp.ts
//   WRAPPER_APP_TYPE=0x<pkg>::<module>::<AppWitness>           pnpm tsx transactions/authorizeWrapperApp.ts

// MUST be the v20 package. `authorize_app` writes `AppKeyV2<App>`, but the AppKeyV2 key was only
// introduced in #1017 — the older v19 package (0x74cd5657...) still writes the LEGACY `AppKey<App>`.
// Authorizing through v19 would silently record the wrong key and the app would still abort with
// EAppNotAuthorized, so pin this to the current package.
const DEEPBOOK_PACKAGE_ID = '0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24';
const REGISTRY_ID = '0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1';

// JSON-RPC is switched off on the testnet fullnode (it 404s), so `utils.getClient` cannot be used.
const GRPC_URL = 'https://fullnode.testnet.sui.io';

const DRY_RUN = process.env.DRY_RUN === '1';

// Full type of the app witness, e.g. `0xabc...::wrapper::WrapperApp`. It is a phantom type
// parameter, so it must be the exact defining type — authorization is bound to App's defining
// module, not just the type tag.
const WRAPPER_APP_TYPE = process.env.WRAPPER_APP_TYPE;

(async () => {
	if (!WRAPPER_APP_TYPE) {
		throw new Error(
			'set WRAPPER_APP_TYPE to the app witness type, e.g. WRAPPER_APP_TYPE=0x<pkg>::wrapper::WrapperApp',
		);
	}

	const env = 'testnet';
	const client = new SuiGrpcClient({ baseUrl: GRPC_URL, network: env });
	const signer = getSigner();
	const sender = signer.getPublicKey().toSuiAddress();

	if (sender !== adminCapOwner[env]) {
		throw new Error(
			`signer ${sender} is not the testnet adminCapOwner ${adminCapOwner[env]} — it cannot use DeepbookAdminCap ${adminCapID[env]}`,
		);
	}

	// `authorize_app` is `self.id.add(AppKeyV2<App> {}, true)`, and `dynamic_field::add` ABORTS if
	// the key already exists. Check first so a re-run reports "already authorized" instead of a
	// bare MoveAbort.
	const { dynamicFields } = await client.core.listDynamicFields({ parentId: REGISTRY_ID });
	const existing = dynamicFields.find(
		(f: any) => f.name?.type?.includes('AppKeyV2') && f.name?.type?.includes(WRAPPER_APP_TYPE),
	);
	if (existing) {
		console.log(`${WRAPPER_APP_TYPE} is already authorized — nothing to do`);
		return;
	}

	const tx = new Transaction();
	tx.setSender(sender);
	tx.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::registry::authorize_app`,
		arguments: [tx.object(REGISTRY_ID), tx.object(adminCapID[env])],
		typeArguments: [WRAPPER_APP_TYPE],
	});

	const res: any = DRY_RUN
		? await client.simulateTransaction({ transaction: tx })
		: await client.signAndExecuteTransaction({ transaction: tx, signer });

	const result = res.Transaction ?? res.transaction ?? res;
	const status = result?.status ?? result?.effects?.status;
	const digest: string | undefined = result?.digest ?? res?.digest;

	if (!status?.success) {
		console.dir(status ?? res, { depth: null });
		throw new Error(`authorize_app<${WRAPPER_APP_TYPE}> failed`);
	}
	if (digest && !DRY_RUN) await client.waitForTransaction({ digest });
	console.log(
		`${DRY_RUN ? '[dry-run] ' : ''}authorize_app<${WRAPPER_APP_TYPE}>: success${
			digest ? ` (${digest})` : ''
		}`,
	);
})();
