// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import {
	getActiveAddress,
	getClient,
	getSigner,
	publishPackage,
	updateConstant,
} from '../../utils/utils.js';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_PATH = path.resolve(__dirname, '../../../packages/predict');
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');
const INDEXER_LIB_PATH = path.resolve(__dirname, '../../../crates/predict-indexer/src/lib.rs');

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
	const created = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'created');
	const published = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'published');

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

	// PLP TreasuryCap is minted during plp::init and transferred to the
	// publisher. `registry::create_predict<DUSDC>` takes this cap as an input,
	// so the standalone `pnpm predict-publish && pnpm predict-init` flow
	// requires it to be captured here.
	const plpCapObjectType = `0x2::coin::TreasuryCap<${predictPackageId}::plp::PLP>`;
	let plpTreasuryCapId = '';
	for (const obj of created) {
		if (obj.type !== 'created') continue;
		if (obj.objectType === plpCapObjectType) {
			plpTreasuryCapId = obj.objectId;
			break;
		}
	}
	if (!plpTreasuryCapId) {
		console.error(`Could not find TreasuryCap<PLP> (${plpCapObjectType}) in objectChanges.`);
		process.exit(1);
	}

	// Write IDs into constants.ts
	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'predictPackageID', network, predictPackageId);
	constants = updateConstant(constants, 'predictRegistryID', network, registryId);
	constants = updateConstant(constants, 'predictAdminCapID', network, adminCapId);
	constants = updateConstant(constants, 'predictUpgradeCapID', network, upgradeCapId);
	constants = updateConstant(constants, 'plpTreasuryCapID', network, plpTreasuryCapId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	// Mirror the package ID into the indexer's hardcoded TESTNET_PREDICT_PACKAGES
	// so `cargo run -p predict-indexer` picks it up without a CLI flag.
	let indexerLib = fs.readFileSync(INDEXER_LIB_PATH, 'utf-8');
	const indexerLibUpdated = indexerLib.replace(
		/const TESTNET_PREDICT_PACKAGES: &\[&str\] = &\[\s*"0x[0-9a-f]+",?\s*\];/,
		`const TESTNET_PREDICT_PACKAGES: &[&str] = &[\n    "${predictPackageId}",\n];`,
	);
	if (indexerLibUpdated === indexerLib) {
		throw new Error(
			'publish: failed to update TESTNET_PREDICT_PACKAGES in crates/predict-indexer/src/lib.rs — regex did not match',
		);
	}
	fs.writeFileSync(INDEXER_LIB_PATH, indexerLibUpdated);

	console.log('\n========== PUBLISH SUMMARY ==========');
	console.log(`Package ID:        ${predictPackageId}`);
	console.log(`Registry:          ${registryId}`);
	console.log(`AdminCap:          ${adminCapId}`);
	console.log(`UpgradeCap:        ${upgradeCapId}`);
	console.log(`plpTreasuryCapID:  ${plpTreasuryCapId}`);
	console.log(`Deployer:          ${address}`);
	console.log(`Tx Digest:         ${result.digest}`);
	console.log('======================================');
	console.log('\nConstants written to config/constants.ts');
	console.log('Indexer TESTNET_PREDICT_PACKAGES updated in crates/predict-indexer/src/lib.rs');
})();
