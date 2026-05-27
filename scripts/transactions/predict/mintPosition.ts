// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 3: mint a directional binary position (UP or DOWN bet on a
// strike). One PTB:
//   1. take DUSDC from the user's existing balance (merge + split)
//   2. deposit it into the caller's PredictManager
//   3. build a MarketKey from (oracle_id, expiry, strike, direction)
//   4. call predict::mint<DUSDC>
//
// The user's active sui-client address must already hold DUSDC. This script
// does NOT touch the treasury cap.
//
// Required env:
//   MANAGER_ID   the user's PredictManager id (from createManager.ts)
//   ORACLE_ID    target OracleSVI id (from listMarkets.ts)
//   EXPIRY       oracle expiry in ms (from listMarkets.ts)
//   STRIKE       strike, 1e9-scaled. e.g. 75000_000_000_000 = $75,000
//   DIRECTION    "up" or "down"
// Optional:
//   QUANTITY     contract count in DUSDC units (1e6). default 1_000_000 = $1.
//   TOPUP        DUSDC to deposit into the manager before mint, in DUSDC
//                units. default = QUANTITY (enough to cover up to a $1 ask).
//   SKIP_TOPUP   set to 1 to skip the deposit step (use manager balance).

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
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
	const strike = BigInt(required('STRIKE'));
	const direction = required('DIRECTION').toLowerCase();
	const quantity = BigInt(process.env.QUANTITY ?? 1_000_000); // $1 face
	const topup = BigInt(process.env.TOPUP ?? quantity);
	const skipTopup = process.env.SKIP_TOPUP === '1';

	if (direction !== 'up' && direction !== 'down') {
		console.error('DIRECTION must be "up" or "down"');
		process.exit(1);
	}

	console.log(`Trader:   ${address}`);
	console.log(`Manager:  ${managerId}`);
	console.log(`Oracle:   ${oracleId}`);
	console.log(`Expiry:   ${new Date(Number(expiry)).toISOString()}`);
	console.log(`Strike:   ${Number(strike) / 1e9}`);
	console.log(`Direction: ${direction.toUpperCase()}`);
	console.log(`Quantity: ${Number(quantity) / 1e6} contracts ($${Number(quantity) / 1e6} face)`);
	console.log(`Top-up:   ${skipTopup ? 'skipped' : `${Number(topup) / 1e6} DUSDC`}\n`);

	const tx = new Transaction();

	// 1. Take DUSDC from the user's wallet and 2. deposit it into the manager.
	if (!skipTopup) {
		const coins = await client.getCoins({ owner: address, coinType: DUSDC_TYPE });
		if (coins.data.length === 0) {
			console.error(`No DUSDC found for ${address}. Ask the host to mint you DUSDC.`);
			process.exit(1);
		}
		const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);
		if (total < topup) {
			console.error(`Insufficient DUSDC: have ${Number(total) / 1e6}, need ${Number(topup) / 1e6}`);
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

	// 3. Build the MarketKey.
	const keyFn = direction === 'up' ? 'up' : 'down';
	const key = tx.moveCall({
		target: `${predictPackageID[network]}::market_key::${keyFn}`,
		arguments: [tx.pure.id(oracleId), tx.pure.u64(expiry), tx.pure.u64(strike)],
	});

	// 4. Mint the position. Cost is debited from the manager's DUSDC balance.
	tx.moveCall({
		target: `${predictPackageID[network]}::predict::mint`,
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
		console.error('mint failed:', result.effects?.status);
		process.exit(1);
	}

	const minted = result.events?.find((e) => e.type.endsWith('::predict::PositionMinted'));
	if (minted) {
		console.log('PositionMinted event:');
		console.dir(minted.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
