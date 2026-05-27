// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 1: create a PredictManager.
//
// Each user holds exactly one PredictManager. It carries deposited DUSDC and
// the user's open positions / ranges. Run this once per attendee address.
//
// Usage:  pnpm predict-create-manager
// Output: prints the new manager ID. Save it — every later script wants it as
//         MANAGER_ID=0x... env var.

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../../utils/utils.js';
import { predictPackageID } from '../../config/constants.js';

const network = 'testnet' as const;

(async () => {
	const client = getClient(network);
	const signer = getSigner();

	const tx = new Transaction();
	tx.moveCall({
		target: `${predictPackageID[network]}::predict::create_manager`,
		arguments: [],
	});

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showObjectChanges: true },
	});

	if (result.effects?.status.status !== 'success') {
		console.error('create_manager failed:', result.effects?.status);
		process.exit(1);
	}

	const created = result.objectChanges?.find(
		(c) => c.type === 'created' && c.objectType.endsWith('::predict_manager::PredictManager'),
	);
	if (!created || created.type !== 'created') {
		console.error('PredictManager not found in objectChanges');
		console.dir(result.objectChanges, { depth: null });
		process.exit(1);
	}

	console.log(`\nPredictManager created.`);
	console.log(`MANAGER_ID: ${created.objectId}`);
	console.log(`Digest:     ${result.digest}`);
	console.log(`\nPaste the id above into the CONFIG block of each script you'll run:`);
	console.log(`  mintPosition.ts  → MANAGER_ID: '${created.objectId}',`);
	console.log(`  mintRange.ts     → MANAGER_ID: '${created.objectId}',`);
	console.log(`  redeemPosition.ts → MANAGER_ID: '${created.objectId}',`);
})();
