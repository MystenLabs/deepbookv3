// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner, publishPackage } from '../../utils/utils';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_PATH = path.resolve(__dirname, '../../../packages/predict');
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

function updateConstant(content: string, name: string, network: string, value: string): string {
	const regex = new RegExp(
		`(export const ${name} = \\{[^}]*${network}:\\s*)"[^"]*"`,
	);
	return content.replace(regex, `$1"${value}"`);
}

(async () => {
	const network = 'testnet' as const;
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	console.log(`Publishing predict package to ${network}...`);
	console.log(`Deployer: ${address}`);

	const tx = new Transaction();
	publishPackage(tx, PREDICT_PATH);

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
	const created = objectChanges.filter((c) => c.type === 'created');
	const published = objectChanges.filter((c) => c.type === 'published');

	let registryId = '';
	let adminCapId = '';
	let upgradeCapId = '';
	let predictPackageId = '';

	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('::registry::Registry')) registryId = obj.objectId;
		if (obj.objectType.includes('::registry::AdminCap')) adminCapId = obj.objectId;
		if (obj.objectType.includes('UpgradeCap')) upgradeCapId = obj.objectId;
	}

	for (const p of published) {
		if (p.type !== 'published') continue;
		if (p.modules?.some((m: string) => m === 'registry')) {
			predictPackageId = p.packageId;
		}
	}

	// Write IDs into constants.ts
	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'predictPackageID', network, predictPackageId);
	constants = updateConstant(constants, 'predictRegistryID', network, registryId);
	constants = updateConstant(constants, 'predictAdminCapID', network, adminCapId);
	constants = updateConstant(constants, 'predictUpgradeCapID', network, upgradeCapId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log('\n========== PUBLISH SUMMARY ==========');
	console.log(`Package ID:   ${predictPackageId}`);
	console.log(`Registry:     ${registryId}`);
	console.log(`AdminCap:     ${adminCapId}`);
	console.log(`UpgradeCap:   ${upgradeCapId}`);
	console.log(`Deployer:     ${address}`);
	console.log(`Tx Digest:    ${result.digest}`);
	console.log('======================================');
	console.log('\nConstants written to config/constants.ts');
})();
