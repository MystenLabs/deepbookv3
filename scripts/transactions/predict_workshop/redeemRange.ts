// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step: redeem a vertical range back into the manager.
//
// predict::redeem_range handles BOTH pre- and post-settlement automatically:
//   - pre-settlement: payout is the live bid × quantity
//   - post-settlement: payout is $1 × quantity if settlement landed inside
//     (lower, higher], otherwise $0
//
// Unlike directional positions, there is no permissionless variant — only the
// manager owner can redeem a range.

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

// === Edit these to match the range you want to close ===============
// Must mirror the RangeKey of the range you minted.
const CONFIG = {
	MANAGER_ID:    '0x51f082104ca41498acdbd6181786978117ae4cc34a72a9a847083ecffe0011ea',
	ORACLE_ID:     '0x57ab16e132ef0083085d1bdef7ed820892a4d574155f47a3cba168dcb43deb79', // BTC 2026-05-29 08:00 UTC
	EXPIRY:        1780041600000, // ms since epoch
	LOWER_STRIKE:  74_000,        // $74,000
	HIGHER_STRIKE: 76_000,        // $76,000
	QUANTITY:      1,             // $1 face to close
};
// Env vars override CONFIG if set.
// ===================================================================

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';
const PRICE_SCALE = 1_000_000_000n;
const DUSDC_SCALE = 1_000_000n;

(async () => {
	const client = getClient(network);
	const signer = getSigner();

	const managerId = process.env.MANAGER_ID ?? CONFIG.MANAGER_ID;
	const oracleId = process.env.ORACLE_ID ?? CONFIG.ORACLE_ID;
	const expiry = BigInt(process.env.EXPIRY ?? CONFIG.EXPIRY);
	const lowerDollars = BigInt(process.env.LOWER_STRIKE ?? CONFIG.LOWER_STRIKE);
	const higherDollars = BigInt(process.env.HIGHER_STRIKE ?? CONFIG.HIGHER_STRIKE);
	const quantityDollars = BigInt(process.env.QUANTITY ?? CONFIG.QUANTITY);

	if (managerId === 'PASTE_YOUR_MANAGER_ID') {
		console.error('Set MANAGER_ID in the CONFIG block (or as an env var).');
		process.exit(1);
	}
	if (lowerDollars >= higherDollars) {
		console.error('LOWER_STRIKE must be < HIGHER_STRIKE');
		process.exit(1);
	}

	const lower = lowerDollars * PRICE_SCALE;
	const higher = higherDollars * PRICE_SCALE;
	const quantity = quantityDollars * DUSDC_SCALE;

	console.log(`Manager:  ${managerId}`);
	console.log(`Oracle:   ${oracleId}`);
	console.log(`Band:     ($${lowerDollars}, $${higherDollars}]`);
	console.log(`Quantity: $${quantityDollars} face\n`);

	const tx = new Transaction();
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
		target: `${predictPackageID[network]}::predict::redeem_range`,
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
		console.error('redeem_range failed:', result.effects?.status);
		process.exit(1);
	}

	const redeemed = result.events?.find((e) => e.type.endsWith('::predict::RangeRedeemed'));
	if (redeemed) {
		console.log('RangeRedeemed event:');
		console.dir(redeemed.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
