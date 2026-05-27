// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// LP supply: take DUSDC from the active wallet's existing balance and call
// predict::supply<DUSDC>, then transfer the resulting PLP coin back.
//
// The active sui-client address must already hold ≥ AMOUNT DUSDC. This script
// does NOT use the treasury cap.

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	predictPackageID,
	predictObjectID,
	dusdcPackageID,
} from '../../config/constants.js';

// === Edit this to choose how much to supply =========================
// AMOUNT is in DUSDC dollars (×1e6 internally).
const CONFIG = {
	AMOUNT: 1,  // $1 DUSDC
};
// Env var AMOUNT overrides CONFIG.AMOUNT.
// ====================================================================

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';
const DUSDC_SCALE = 1_000_000n;

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	const supplyDollars = BigInt(process.env.AMOUNT ?? CONFIG.AMOUNT);
	const supplyAmount = supplyDollars * DUSDC_SCALE;

	const coins = await client.getCoins({ owner: address, coinType: DUSDC_TYPE });
	if (coins.data.length === 0) {
		console.error(`No DUSDC found for ${address}. Ask the host to mint you DUSDC.`);
		process.exit(1);
	}
	const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);
	if (total < supplyAmount) {
		console.error(`Insufficient DUSDC: have $${Number(total) / 1e6}, need $${supplyDollars}`);
		process.exit(1);
	}

	console.log(`LP:     ${address}`);
	console.log(`Supply: $${supplyDollars} DUSDC\n`);

	const tx = new Transaction();
	const primary = tx.object(coins.data[0].coinObjectId);
	if (coins.data.length > 1) {
		tx.mergeCoins(
			primary,
			coins.data.slice(1).map((c) => tx.object(c.coinObjectId)),
		);
	}
	const [supplyCoin] = tx.splitCoins(primary, [tx.pure.u64(supplyAmount)]);

	const lpCoin = tx.moveCall({
		target: `${predictPackageID[network]}::predict::supply`,
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(predictObjectID[network]), supplyCoin, tx.object(CLOCK)],
	});
	tx.transferObjects([lpCoin], tx.pure.address(address));

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showEvents: true, showObjectChanges: true },
	});
	if (result.effects?.status.status !== 'success') {
		console.error('Supply failed:', result.effects?.status);
		process.exit(1);
	}

	const supplied = result.events?.find((e) => e.type.endsWith('::predict::Supplied'));
	if (supplied) {
		console.log('Supplied event:');
		console.dir(supplied.parsedJson, { depth: null });
	}
	const plp = result.objectChanges?.find(
		(c) => c.type === 'created' && c.objectType.includes('::plp::PLP'),
	);
	if (plp && plp.type === 'created') {
		console.log(`\nPLP coin received: ${plp.objectId}`);
		console.log(`Paste into withdraw.ts CONFIG to redeem it:`);
		console.log(`  PLP_COIN: '${plp.objectId}',`);
	}
	console.log(`\nDigest: ${result.digest}`);
})();
