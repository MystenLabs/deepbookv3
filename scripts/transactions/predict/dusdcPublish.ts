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

// On-chain shared CoinRegistry system object. Matches COIN_REGISTRY_ID used in
// packages/predict/simulations/src/runtime.ts.
const COIN_REGISTRY_ID = '0xc';

function updateConstant(content: string, name: string, network: string, value: string): string {
	const regex = new RegExp(`(export const ${name} = \\{[^}]*${network}:\\s*)"[^"]*"`);
	const result = content.replace(regex, `$1"${value}"`);
	if (result === content) {
		throw new Error(
			`updateConstant: no match for ${name}[${network}] in constants.ts — check that the constant exists and the file format hasn't drifted`,
		);
	}
	return result;
}

(async () => {
	const network = 'testnet' as const;
	const client = getClient(network);
	const signer = getSigner();
	const address = signer.toSuiAddress();

	console.log(`Publishing dusdc package to ${network}...`);
	console.log(`Deployer: ${address}`);

	// -------------------------------------------------------------------------
	// Tx 1: publish dusdc package.
	//
	// `coin_registry::new_currency_with_otw` + `builder.finalize(ctx)` in the
	// module `init` transfers the initial `Currency<DUSDC>` to
	// `object::sui_coin_registry_address()` as a TTO-owned object. We capture
	// that initial Currency ID here so we can pass it into
	// `coin_registry::finalize_registration` below, which promotes it into a
	// shared object at a derived address with a new object ID.
	// -------------------------------------------------------------------------
	const publishTx = new Transaction();
	publishPackage(publishTx, DUSDC_PATH);

	const publishResult = await client.signAndExecuteTransaction({
		transaction: publishTx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (publishResult.effects?.status.status !== 'success') {
		console.error('Publish failed:', publishResult.effects?.status);
		process.exit(1);
	}

	const publishChanges = publishResult.objectChanges ?? [];
	const publishCreated = publishChanges.filter(
		(c: (typeof publishChanges)[number]) => c.type === 'created',
	);
	const published = publishChanges.filter(
		(c: (typeof publishChanges)[number]) => c.type === 'published',
	);

	let dusdcPackageId = '';
	let treasuryCapId = '';
	let initialCurrencyId = '';

	for (const p of published) {
		if (p.type !== 'published') continue;
		if (p.modules?.some((m: string) => m === 'dusdc')) {
			dusdcPackageId = p.packageId;
		}
	}

	for (const obj of publishCreated) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('TreasuryCap')) treasuryCapId = obj.objectId;
		// Initial (pre-finalize) coin_registry::Currency<PKG::dusdc::DUSDC>.
		if (
			obj.objectType.includes('::coin_registry::Currency<') &&
			obj.objectType.includes('::dusdc::DUSDC')
		) {
			initialCurrencyId = obj.objectId;
		}
	}

	if (!dusdcPackageId || !treasuryCapId || !initialCurrencyId) {
		console.error(
			'Could not resolve DUSDC publish outputs (package / TreasuryCap / initial Currency):',
			{ dusdcPackageId, treasuryCapId, initialCurrencyId },
		);
		process.exit(1);
	}

	// -------------------------------------------------------------------------
	// Tx 2: finalize the Currency<DUSDC> registration.
	//
	// This promotes the TTO-owned Currency to a shared object at a derived
	// address with a NEW object ID. `registry::create_predict<DUSDC>` needs a
	// reference to this shared Currency, so we capture the new ID and write
	// that (not the initial one) to constants.ts.
	//
	// Pattern mirrors `finalizeDusdcCurrencyRegistrationTx` in
	// packages/predict/simulations/src/runtime.ts (lines 83-91) and the
	// setupSimulation flow in packages/predict/simulations/src/sim.ts
	// (lines 101-115).
	// -------------------------------------------------------------------------
	const DUSDC_TYPE = `${dusdcPackageId}::dusdc::DUSDC`;

	const finalizeTx = new Transaction();
	finalizeTx.moveCall({
		target: '0x2::coin_registry::finalize_registration',
		typeArguments: [DUSDC_TYPE],
		arguments: [finalizeTx.object(COIN_REGISTRY_ID), finalizeTx.object(initialCurrencyId)],
	});

	const finalizeResult = await client.signAndExecuteTransaction({
		transaction: finalizeTx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (finalizeResult.effects?.status.status !== 'success') {
		console.error('Finalize registration failed:', finalizeResult.effects?.status);
		process.exit(1);
	}

	const finalizeChanges = finalizeResult.objectChanges ?? [];
	let sharedCurrencyId = '';
	for (const obj of finalizeChanges) {
		if (obj.type !== 'created') continue;
		if (
			obj.objectType.includes('::coin_registry::Currency<') &&
			obj.objectType.includes('::dusdc::DUSDC>')
		) {
			sharedCurrencyId = obj.objectId;
			break;
		}
	}

	if (!sharedCurrencyId) {
		console.error(
			'Could not find shared Currency<DUSDC> in finalize_registration objectChanges.',
		);
		process.exit(1);
	}

	// Write the NEW (post-finalize) shared Currency ID — that's what
	// create_predict<DUSDC> expects.
	let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
	constants = updateConstant(constants, 'dusdcPackageID', network, dusdcPackageId);
	constants = updateConstant(constants, 'dusdcTreasuryCapID', network, treasuryCapId);
	constants = updateConstant(constants, 'dusdcCurrencyID', network, sharedCurrencyId);
	fs.writeFileSync(CONSTANTS_PATH, constants);

	console.log('\n========== DUSDC PUBLISH SUMMARY ==========');
	console.log(`Package ID:          ${dusdcPackageId}`);
	console.log(`TreasuryCap:         ${treasuryCapId}`);
	console.log(`Initial Currency:    ${initialCurrencyId} (TTO-owned, pre-finalize)`);
	console.log(`Shared Currency:     ${sharedCurrencyId} (post-finalize — written to constants)`);
	console.log(`Deployer:            ${address}`);
	console.log(`Publish Tx Digest:   ${publishResult.digest}`);
	console.log(`Finalize Tx Digest:  ${finalizeResult.digest}`);
	console.log('============================================');
	console.log('\nConstants written to config/constants.ts');
})();
