// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner, publishPackage } from '../../utils/utils.js';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DUSDC_PATH = path.resolve(__dirname, '../../../packages/dusdc');
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

function updateConstant(content: string, name: string, network: string, value: string): string {
	const regex = new RegExp(`(export const ${name} = \\{[^}]*${network}:\\s*)"[^"]*"`);
	return content.replace(regex, `$1"${value}"`);
}

(async () => {
	const network = 'testnet' as const;
	const client = getClient(network);
	const signer = getSigner();
	const address = signer.toSuiAddress();

	console.log(`Publishing dusdc package to ${network}...`);
	console.log(`Deployer: ${address}`);

	const tx = new Transaction();
	publishPackage(tx, DUSDC_PATH);

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (result.effects?.status.status !== 'success') {
		console.error('Publish failed:', result.effects?.status);
		process.exit(1);
	}

	const objectChanges = result.objectChanges ?? [];
	const created = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'created');
	const published = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'published');

	let dusdcPackageId = '';
	let treasuryCapId = '';

	for (const p of published) {
		if (p.type !== 'published') continue;
		if (p.modules?.some((m: string) => m === 'dusdc')) {
			dusdcPackageId = p.packageId;
		}
	}

	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('TreasuryCap')) treasuryCapId = obj.objectId;
	}

	// Write IDs into constants.ts
	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'dusdcPackageID', network, dusdcPackageId);
	constants = updateConstant(constants, 'dusdcTreasuryCapID', network, treasuryCapId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log('\n========== DUSDC PUBLISH SUMMARY ==========');
	console.log(`Package ID:    ${dusdcPackageId}`);
	console.log(`TreasuryCap:   ${treasuryCapId}`);
	console.log(`Deployer:      ${address}`);
	console.log(`Tx Digest:     ${result.digest}`);
	console.log('============================================');
	console.log('\nConstants written to config/constants.ts');
})();
