// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Creates an OracleCap and transfers it to the deployer.

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import { predictPackageID, predictAdminCapID } from '../../config/constants.js';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

const network = 'testnet' as const;

function updateConstant(content: string, name: string, net: string, value: string): string {
	const regex = new RegExp(`(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`);
	return content.replace(regex, `$1"${value}"`);
}

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	console.log(`Creating OracleCap on ${network}...`);
	console.log(`Deployer: ${address}`);

	const tx = new Transaction();

	const oracleCap = tx.moveCall({
		target: `${predictPackageID[network]}::registry::create_oracle_cap`,
		arguments: [tx.object(predictAdminCapID[network])],
	});

	tx.transferObjects([oracleCap], tx.pure.address(address));

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (result.effects?.status.status !== 'success') {
		console.error('CreateOracleCap failed:', result.effects?.status);
		process.exit(1);
	}

	let oracleCapId = '';
	const allChanges = result.objectChanges ?? [];
	const created = allChanges.filter((c: (typeof allChanges)[number]) => c.type === 'created');
	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('::oracle::OracleCapSVI')) oracleCapId = obj.objectId;
	}

	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'predictOracleCapID', network, oracleCapId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log(`\nOracleCap: ${oracleCapId}`);
	console.log(`Tx Digest: ${result.digest}`);
	console.log('\nConstants written to config/constants.ts');
})();
