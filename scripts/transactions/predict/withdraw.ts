// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 6 (LP demo): redeem PLP shares back to DUSDC via predict::withdraw.

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

// === Edit these to burn your PLP back to DUSDC ======================
// PLP_COIN is printed by pnpm predict-deposit. Find existing PLP coins
// with: sui client objects --json | jq '... ::plp::PLP ...'
// AMOUNT is in PLP units (1e6 scaling, like DUSDC). null burns the full coin.
const CONFIG = {
	PLP_COIN: 'PASTE_YOUR_PLP_COIN',
	AMOUNT:   null as number | null,  // e.g. 50 for 50 PLP shares; null = burn entire coin
};
// Env vars override CONFIG if set (PLP_COIN, AMOUNT).
// ====================================================================

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';
const PLP_SCALE = 1_000_000n;  // PLP shares share the 6-decimal scaling

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	const plpCoin = process.env.PLP_COIN ?? CONFIG.PLP_COIN;
	const amountUnits = process.env.AMOUNT
		? BigInt(process.env.AMOUNT)
		: CONFIG.AMOUNT === null
			? null
			: BigInt(CONFIG.AMOUNT);

	if (plpCoin === 'PASTE_YOUR_PLP_COIN') {
		console.error('Set PLP_COIN in the CONFIG block (or as an env var). Run pnpm predict-deposit first.');
		process.exit(1);
	}

	const amountScaled = amountUnits === null ? null : amountUnits * PLP_SCALE;

	console.log(`LP:       ${address}`);
	console.log(`PLP coin: ${plpCoin}`);
	console.log(`Burn:     ${amountScaled === null ? 'entire balance' : `${amountUnits} PLP`}\n`);

	const tx = new Transaction();

	const coinArg = amountScaled === null
		? tx.object(plpCoin)
		: tx.splitCoins(tx.object(plpCoin), [tx.pure.u64(amountScaled)]);

	const dusdcOut = tx.moveCall({
		target: `${predictPackageID[network]}::predict::withdraw`,
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(predictObjectID[network]), coinArg as any, tx.object(CLOCK)],
	});
	tx.transferObjects([dusdcOut], tx.pure.address(address));

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showEvents: true },
	});

	if (result.effects?.status.status !== 'success') {
		console.error('withdraw failed:', result.effects?.status);
		process.exit(1);
	}

	const withdrawn = result.events?.find((e) => e.type.endsWith('::predict::Withdrawn'));
	if (withdrawn) {
		console.log('Withdrawn event:');
		console.dir(withdrawn.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
