// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { config } from 'dotenv';

import { DeepBookMarketMaker } from './deepbookMarketMaker.js';

// Load private key from .env file
config();

(async () => {
	const privateKey = process.env.PRIVATE_KEY;
	if (!privateKey) {
		throw new Error('Private key not found');
	}

	// Initialize with balance managers if created
	const balanceManagers = {
		MANAGER_1: {
			address: '',
			tradeCap: '',
		},
	};
	const mmClient = new DeepBookMarketMaker(
		privateKey,
		'testnet',
		balanceManagers,
		process.env.ADMIN_CAP,
	);

	const tx = new Transaction();

	// WIP, to finalize after security design

	let res = await mmClient.signAndExecute(tx);

	console.dir(res, { depth: null });
})();
