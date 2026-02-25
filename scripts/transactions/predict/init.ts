// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils';
import {
	predictPackageID,
	predictRegistryID,
	predictAdminCapID,
	dusdcPackageID,
} from '../../config/constants';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	console.log(`Initializing predict on ${network}...`);
	console.log(`Deployer: ${address}`);

	const tx = new Transaction();

	tx.moveCall({
		target: `${predictPackageID[network]}::registry::create_predict`,
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(predictRegistryID[network]), tx.object(predictAdminCapID[network])],
	});

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (result.effects?.status.status !== 'success') {
		console.error('Init failed:', result.effects?.status);
		process.exit(1);
	}

	let predictId = '';
	const created = result.objectChanges?.filter((c) => c.type === 'created') ?? [];
	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('::predict::Predict')) {
			predictId = obj.objectId;
		}
	}

	// Write Predict object ID to constants
	function updateConstant(content: string, name: string, net: string, value: string): string {
		const regex = new RegExp(`(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`);
		return content.replace(regex, `$1"${value}"`);
	}
	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'predictObjectID', network, predictId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log('\n========== INIT SUMMARY ==========');
	console.log(`Predict<DUSDC>: ${predictId}`);
	console.log(`Tx Digest:     ${result.digest}`);
	console.log('==================================');
	console.log('\nConstants written to config/constants.ts');
})();
