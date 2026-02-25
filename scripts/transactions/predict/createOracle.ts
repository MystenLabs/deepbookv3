// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Creates an OracleSVI<SUI> shared object (SUI as phantom Underlying).
/// Usage: EXPIRY=1742515200000 pnpm predict-create-oracle (default 30 days from now)

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils';
import {
	predictPackageID,
	predictRegistryID,
	predictAdminCapID,
	predictOracleCapID,
} from '../../config/constants';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

const network = 'testnet' as const;
const UNDERLYING_TYPE = '0x2::sui::SUI';

// Default expiry: 30 days from now
const EXPIRY_MS = process.env.EXPIRY
	? BigInt(process.env.EXPIRY)
	: BigInt(Date.now()) + 30n * 24n * 60n * 60n * 1000n;

function updateConstant(content: string, name: string, net: string, value: string): string {
	const regex = new RegExp(`(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`);
	return content.replace(regex, `$1"${value}"`);
}

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	console.log(`Creating Oracle on ${network}...`);
	console.log(`Deployer: ${address}`);
	console.log(`Expiry:   ${new Date(Number(EXPIRY_MS)).toISOString()}`);

	const tx = new Transaction();

	tx.moveCall({
		target: `${predictPackageID[network]}::registry::create_oracle`,
		typeArguments: [UNDERLYING_TYPE],
		arguments: [
			tx.object(predictRegistryID[network]),
			tx.object(predictAdminCapID[network]),
			tx.object(predictOracleCapID[network]),
			tx.pure.u64(EXPIRY_MS),
		],
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
		console.error('CreateOracle failed:', result.effects?.status);
		process.exit(1);
	}

	let oracleId = '';
	const created = result.objectChanges?.filter((c) => c.type === 'created') ?? [];
	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('::oracle::OracleSVI')) oracleId = obj.objectId;
	}

	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'predictOracleID', network, oracleId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log(`\nOracle: ${oracleId}`);
	console.log(`Tx Digest: ${result.digest}`);
	console.log('\nConstants written to config/constants.ts');
})();
