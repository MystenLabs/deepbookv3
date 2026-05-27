// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 5: mint a vertical range — a bet that the settlement lands
// inside (lower, higher]. Single ask covers the whole band.

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

// === Edit these for your trade =====================================
// Values are human units. Strikes scale by 1e9 (price), DUSDC by 1e6.
const CONFIG = {
	MANAGER_ID:    'PASTE_YOUR_MANAGER_ID',
	ORACLE_ID:     '0xec05af6806cc08ffb2656ad1b21e7510493fe499b8992167e61e39529d851d2d', // BTC 2026-05-28 08:00 UTC
	EXPIRY:        1779955200000,    // ms since epoch
	LOWER_STRIKE:  70_000,           // $70,000
	HIGHER_STRIKE: 80_000,           // $80,000
	QUANTITY:      1,                // $1 face
	TOPUP:         1,                // DUSDC to deposit before mint
	SKIP_TOPUP:    false,
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
	const address = getActiveAddress();

	const managerId = process.env.MANAGER_ID ?? CONFIG.MANAGER_ID;
	const oracleId = process.env.ORACLE_ID ?? CONFIG.ORACLE_ID;
	const expiry = BigInt(process.env.EXPIRY ?? CONFIG.EXPIRY);
	const lowerDollars = BigInt(process.env.LOWER_STRIKE ?? CONFIG.LOWER_STRIKE);
	const higherDollars = BigInt(process.env.HIGHER_STRIKE ?? CONFIG.HIGHER_STRIKE);
	const quantityDollars = BigInt(process.env.QUANTITY ?? CONFIG.QUANTITY);
	const topupDollars = BigInt(process.env.TOPUP ?? CONFIG.TOPUP);
	const skipTopup = process.env.SKIP_TOPUP ? process.env.SKIP_TOPUP === '1' : CONFIG.SKIP_TOPUP;

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
	const topup = topupDollars * DUSDC_SCALE;

	console.log(`Trader:    ${address}`);
	console.log(`Manager:   ${managerId}`);
	console.log(`Oracle:    ${oracleId}`);
	console.log(`Band:      ($${lowerDollars}, $${higherDollars}]`);
	console.log(`Quantity:  $${quantityDollars} face`);
	console.log(`Top-up:    ${skipTopup ? 'skipped' : `$${topupDollars} DUSDC`}\n`);

	const tx = new Transaction();

	if (!skipTopup) {
		const coins = await client.getCoins({ owner: address, coinType: DUSDC_TYPE });
		if (coins.data.length === 0) {
			console.error(`No DUSDC found for ${address}. Ask the host to mint you DUSDC.`);
			process.exit(1);
		}
		const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);
		if (total < topup) {
			console.error(`Insufficient DUSDC: have $${Number(total) / 1e6}, need $${topupDollars}`);
			process.exit(1);
		}

		const primary = tx.object(coins.data[0].coinObjectId);
		if (coins.data.length > 1) {
			tx.mergeCoins(
				primary,
				coins.data.slice(1).map((c) => tx.object(c.coinObjectId)),
			);
		}
		const [depositCoin] = tx.splitCoins(primary, [tx.pure.u64(topup)]);
		tx.moveCall({
			target: `${predictPackageID[network]}::predict_manager::deposit`,
			typeArguments: [DUSDC_TYPE],
			arguments: [tx.object(managerId), depositCoin],
		});
	}

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
