// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 3: mint a directional binary position (UP or DOWN bet on a
// strike). One PTB:
//   1. mint DUSDC from the test treasury cap
//   2. deposit it into the caller's PredictManager
//   3. build a MarketKey from (oracle_id, expiry, strike, direction)
//   4. call predict::mint<DUSDC>
//
// Required env:
//   MANAGER_ID   the user's PredictManager id (from createManager.ts)
//   ORACLE_ID    target OracleSVI id (from listMarkets.ts)
//   EXPIRY       oracle expiry in ms (from listMarkets.ts)
//   STRIKE       strike, 1e9-scaled. e.g. 75000_000_000_000 = $75,000
//   DIRECTION    "up" or "down"
// Optional:
//   QUANTITY     contract count in DUSDC units (1e6). default 1_000_000 = $1.
//   DEPOSIT      DUSDC to top up the manager before mint, in DUSDC units.
//                default = QUANTITY (enough to cover up to a $1 ask).

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
	const strike = BigInt(required('STRIKE'));
	const direction = required('DIRECTION').toLowerCase();
	const quantity = BigInt(process.env.QUANTITY ?? 1_000_000); // $1 face
	const deposit = BigInt(process.env.DEPOSIT ?? quantity); // top up at least the qty

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
	console.log(`Top-up:   ${Number(deposit) / 1e6} DUSDC\n`);

	const tx = new Transaction();

	// 1. Mint DUSDC for the trader and 2. deposit it into the PredictManager.
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
