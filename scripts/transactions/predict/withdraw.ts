// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 6 (LP demo): redeem PLP shares back to DUSDC via predict::withdraw.
//
// Required env:
//   PLP_COIN     the PLP coin object id to burn.
//                tip: `sui client objects --json` and grep "::plp::PLP"
//                or use the address from supply/deposit.ts output.
// Optional:
//   AMOUNT       amount of PLP shares (1e6 units) to burn. If unset, burns the
//                entire PLP_COIN. If set, splits the coin first.

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

	const plpCoin = required('PLP_COIN');
	const amount = process.env.AMOUNT ? BigInt(process.env.AMOUNT) : undefined;

	console.log(`LP:       ${address}`);
	console.log(`PLP coin: ${plpCoin}`);
	console.log(`Burn:     ${amount === undefined ? 'entire balance' : `${Number(amount) / 1e6} PLP`}\n`);

	const tx = new Transaction();

	// Split off `amount` if specified, otherwise burn the whole PLP coin.
	const coinArg = amount === undefined
		? tx.object(plpCoin)
		: tx.splitCoins(tx.object(plpCoin), [tx.pure.u64(amount)]);

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
