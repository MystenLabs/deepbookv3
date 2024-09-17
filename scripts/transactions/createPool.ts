// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { prepareMultisigTx } from '../utils/utils';
import { adminCapOwner } from '../config/constants';

import { config } from 'dotenv';

import { DeepBookMarketMaker } from './deepbookMarketMaker.js';

// Load private key from .env file
config();

(async () => {
	const env = 'testnet';
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
		env,
		balanceManagers,
		process.env.ADMIN_CAP,
	);

	const tx = new Transaction();

	// Creating Pools
	mmClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'SUI',
		tickSize: 0.001,
		lotSize: 1,
		minSize: 10,
		whitelisted: true,
		stablePool: false,
	})(tx);

	mmClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'SUI',
		quoteCoinKey: 'DBUSDC',
		tickSize: 0.001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: false,
		stablePool: false,
	})(tx);

	mmClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'DBUSDC',
		tickSize: 0.001,
		lotSize: 1,
		minSize: 10,
		whitelisted: true,
		stablePool: false,
	})(tx);

	mmClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DBUSDT',
		quoteCoinKey: 'DBUSDC',
		tickSize: 0.001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: false,
		stablePool: true,
	})(tx);

	let res = await prepareMultisigTx(tx, 'testnet', adminCapOwner.testnet[env]);

	console.dir(res, { depth: null });
})();
