// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Redeem a SETTLED directional position permissionlessly.
//
// predict::redeem_permissionless can be called by ANYONE (not just the
// manager owner) once the oracle has settled. The payout is deposited into
// the manager's DUSDC balance:
//   - settlement inside the winning side → $1 × quantity
//   - losing side                        → $0
//
// Aborts (EOracleNotSettled) if the oracle is still live — use
// redeemPosition.ts (predict::redeem) for pre-settlement exits.

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

// === Edit these to match the settled position you want to close ====
// Defaults point at the settled BTC 2026-05-28 08:00 UTC oracle.
const CONFIG = {
	MANAGER_ID: '0xb7f44301182aeaad54f2e35cbdef164ffa0bbb24aa84a6ab25d6ef05bd5310f0',
	ORACLE_ID:  '0xec05af6806cc08ffb2656ad1b21e7510493fe499b8992167e61e39529d851d2d', // BTC 2026-05-28 08:00 UTC (settled)
	EXPIRY:     1779955200000, // ms since epoch
	STRIKE:     75_000,        // $75,000
	DIRECTION:  'up' as 'up' | 'down',
	QUANTITY:   100,           // $100 face to close
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
	const strikeDollars = BigInt(process.env.STRIKE ?? CONFIG.STRIKE);
	const direction = (process.env.DIRECTION ?? CONFIG.DIRECTION).toLowerCase();
	const quantityDollars = BigInt(process.env.QUANTITY ?? CONFIG.QUANTITY);

	if (managerId === 'PASTE_YOUR_MANAGER_ID') {
		console.error('Set MANAGER_ID in the CONFIG block (or as an env var).');
		process.exit(1);
	}
	if (direction !== 'up' && direction !== 'down') {
		console.error('DIRECTION must be "up" or "down"');
		process.exit(1);
	}

	const strike = strikeDollars * PRICE_SCALE;
	const quantity = quantityDollars * DUSDC_SCALE;
	console.log(`predict::redeem_permissionless for ${direction.toUpperCase()} @ $${strikeDollars}, qty=$${quantityDollars}`);
	console.log(`(anyone can call this once the oracle is settled)\n`);

	const tx = new Transaction();
	const keyFn = direction === 'up' ? 'up' : 'down';
	const key = tx.moveCall({
		target: `${predictPackageID[network]}::market_key::${keyFn}`,
		arguments: [tx.pure.id(oracleId), tx.pure.u64(expiry), tx.pure.u64(strike)],
	});

	tx.moveCall({
		target: `${predictPackageID[network]}::predict::redeem_permissionless`,
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
		console.error('redeem_permissionless failed:', result.effects?.status);
		process.exit(1);
	}

	const redeemed = result.events?.find((e) => e.type.endsWith('::predict::PositionRedeemed'));
	if (redeemed) {
		console.log('PositionRedeemed event:');
		console.dir(redeemed.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
