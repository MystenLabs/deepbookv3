// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 5: mint a vertical range — a bet that the settlement lands
// inside (lower, higher]. Single ask covers the whole band.
//
// Required env:
//   MANAGER_ID, ORACLE_ID, EXPIRY
//   LOWER_STRIKE   1e9-scaled
//   HIGHER_STRIKE  1e9-scaled, must be > LOWER_STRIKE
// Optional:
//   QUANTITY  default 1_000_000 ($1 face)
//   DEPOSIT   default = QUANTITY

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	dusdcTreasuryCapID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';

const required = (name: string): string => {
	const v = process.env[name];
	if (!v) {
		console.error(`Missing required env var: ${name}`);
		process.exit(1);
	}
	return v;
};

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	const managerId = required('MANAGER_ID');
	const oracleId = required('ORACLE_ID');
	const expiry = BigInt(required('EXPIRY'));
	const lower = BigInt(required('LOWER_STRIKE'));
	const higher = BigInt(required('HIGHER_STRIKE'));
	const quantity = BigInt(process.env.QUANTITY ?? 1_000_000);
	const deposit = BigInt(process.env.DEPOSIT ?? quantity);

	if (lower >= higher) {
		console.error('LOWER_STRIKE must be < HIGHER_STRIKE');
		process.exit(1);
	}

	console.log(`Trader:   ${address}`);
	console.log(`Manager:  ${managerId}`);
	console.log(`Oracle:   ${oracleId}`);
	console.log(`Band:     (${Number(lower) / 1e9}, ${Number(higher) / 1e9}]`);
	console.log(`Quantity: ${Number(quantity) / 1e6} contracts ($${Number(quantity) / 1e6} face)\n`);

	const tx = new Transaction();

	const dusdc = tx.moveCall({
		target: '0x2::coin::mint',
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(dusdcTreasuryCapID[network]), tx.pure.u64(deposit)],
	});
	tx.moveCall({
		target: `${predictPackageID[network]}::predict_manager::deposit`,
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(managerId), dusdc],
	});

	const key = tx.moveCall({
		target: `${predictPackageID[network]}::range_key::new`,
		arguments: [
			tx.pure.id(oracleId),
			tx.pure.u64(expiry),
			tx.pure.u64(lower),
			tx.pure.u64(higher),
		],
	});

	tx.moveCall({
		target: `${predictPackageID[network]}::predict::mint_range`,
		typeArguments: [DUSDC_TYPE],
		arguments: [
			tx.object(predictObjectID[network]),
			tx.object(managerId),
			tx.object(oracleId),
			key,
			tx.pure.u64(quantity),
			tx.object(CLOCK),
		],
	});

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showEvents: true },
	});

	if (result.effects?.status.status !== 'success') {
		console.error('mint_range failed:', result.effects?.status);
		process.exit(1);
	}

	const minted = result.events?.find((e) => e.type.endsWith('::predict::RangeMinted'));
	if (minted) {
		console.log('RangeMinted event:');
		console.dir(minted.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
