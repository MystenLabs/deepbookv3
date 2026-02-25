// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Mints DUSDC and deposits into the predict vault.
/// Usage: AMOUNT=1000000 pnpm predict-deposit (default 1M DUSDC)

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils';
import {
	predictPackageID,
	predictAdminCapID,
	predictObjectID,
	dusdcPackageID,
	dusdcTreasuryCapID,
} from '../../config/constants';

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

// Default: 1,000,000 DUSDC (6 decimals)
const DEPOSIT_AMOUNT = BigInt(process.env.AMOUNT ?? 1_000_000) * 1_000_000n;

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	console.log(`Depositing ${Number(DEPOSIT_AMOUNT) / 1e6} DUSDC into vault on ${network}...`);
	console.log(`Deployer: ${address}`);

	const tx = new Transaction();

	const coin = tx.moveCall({
		target: '0x2::coin::mint',
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(dusdcTreasuryCapID[network]), tx.pure.u64(DEPOSIT_AMOUNT)],
	});

	tx.moveCall({
		target: `${predictPackageID[network]}::registry::admin_deposit`,
		typeArguments: [DUSDC_TYPE],
		arguments: [
			tx.object(predictObjectID[network]),
			tx.object(predictAdminCapID[network]),
			coin,
		],
	});

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true },
	});

	if (result.effects?.status.status !== 'success') {
		console.error('Deposit failed:', result.effects?.status);
		process.exit(1);
	}

	console.log(`\nDeposited ${Number(DEPOSIT_AMOUNT) / 1e6} DUSDC. Tx Digest: ${result.digest}`);
})();
