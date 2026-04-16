// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import { dusdcPackageID, dusdcTreasuryCapID } from '../../config/constants.js';

const network = 'testnet' as const;

// Default: mint 1,000,000 DUSDC (6 decimals)
const MINT_AMOUNT = BigInt(process.env.AMOUNT ?? 1_000_000) * 1_000_000n;

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();
	const recipient = process.env.RECIPIENT ?? address;

	console.log(`Minting ${Number(MINT_AMOUNT) / 1e6} DUSDC on ${network}...`);
	console.log(`Recipient: ${recipient}`);

	const tx = new Transaction();

	const coin = tx.moveCall({
		target: '0x2::coin::mint',
		typeArguments: [`${dusdcPackageID[network]}::dusdc::DUSDC`],
		arguments: [tx.object(dusdcTreasuryCapID[network]), tx.pure.u64(MINT_AMOUNT)],
	});

	tx.transferObjects([coin], tx.pure.address(recipient));

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (result.effects?.status.status !== 'success') {
		console.error('Mint failed:', result.effects?.status);
		process.exit(1);
	}

	console.log(`\nMinted successfully. Tx Digest: ${result.digest}`);
})();
