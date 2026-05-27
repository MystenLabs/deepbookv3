// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 4: redeem a directional position back into the manager.
//
// Two modes:
//   - default (oracle still live):  predict::redeem
//   - SETTLED=1 (oracle settled):   predict::redeem_permissionless
//
// Required env: MANAGER_ID, ORACLE_ID, EXPIRY, STRIKE, DIRECTION, QUANTITY.
// Optional env: SETTLED=1 to use the permissionless settled redemption.

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../../utils/utils.js';
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

	const managerId = required('MANAGER_ID');
	const oracleId = required('ORACLE_ID');
	const expiry = BigInt(required('EXPIRY'));
	const strike = BigInt(required('STRIKE'));
	const direction = required('DIRECTION').toLowerCase();
	const quantity = BigInt(required('QUANTITY'));
	const settled = process.env.SETTLED === '1';

	if (direction !== 'up' && direction !== 'down') {
		console.error('DIRECTION must be "up" or "down"');
		process.exit(1);
	}

	const target = settled ? 'redeem_permissionless' : 'redeem';
	console.log(`Calling predict::${target} for ${direction.toUpperCase()} @ ${Number(strike) / 1e9}, qty=${Number(quantity) / 1e6}`);

	const tx = new Transaction();
	const keyFn = direction === 'up' ? 'up' : 'down';
	const key = tx.moveCall({
		target: `${predictPackageID[network]}::market_key::${keyFn}`,
		arguments: [tx.pure.id(oracleId), tx.pure.u64(expiry), tx.pure.u64(strike)],
	});

	tx.moveCall({
		target: `${predictPackageID[network]}::predict::${target}`,
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
		console.error('redeem failed:', result.effects?.status);
		process.exit(1);
	}

	const redeemed = result.events?.find((e) => e.type.endsWith('::predict::PositionRedeemed'));
	if (redeemed) {
		console.log('PositionRedeemed event:');
		console.dir(redeemed.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
