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
			address: '0xc873b1639903ab279b3d20bdb4497c67739e1cb9c4acd6df9be4e6330c9ca8a6',
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

	// Read only call
	// console.log(await mmClient.checkManagerBalance('MANAGER_1', 'SUI'));
	// console.log(await mmClient.getLevel2Range('SUI_DBUSDC', 0.1, 100, true));

	// // Balance manager contract call
	mmClient.balanceManager.depositIntoManager('MANAGER_1', 'SUI', 1)(tx);

	// // Example PTB call
	// mmClient.placeLimitOrderExample(tx);
	// mmClient.flashLoanExample(tx);

	let res = await mmClient.signAndExecute(tx);

	console.dir(res, { depth: null });
})();
