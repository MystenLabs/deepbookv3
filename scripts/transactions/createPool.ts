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
	// Update constant for env
	const env = 'mainnet';
	const privateKey = process.env.PRIVATE_KEY || '';

	// Initialize with balance managers if created
	const balanceManagers = {
		MANAGER_1: {
			address: '',
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

	if (env == "testnet") {
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

		let res = await mmClient.signAndExecute(tx);

		console.dir(res, { depth: null });
	} else if (env == "mainnet") {
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
			quoteCoinKey: 'USDC',
			tickSize: 0.001,
			lotSize: 0.1,
			minSize: 1,
			whitelisted: false,
			stablePool: false,
		})(tx);

		mmClient.deepBookAdmin.createPoolAdmin({
			baseCoinKey: 'DEEP',
			quoteCoinKey: 'USDC',
			tickSize: 0.001,
			lotSize: 1,
			minSize: 10,
			whitelisted: true,
			stablePool: false,
		})(tx);

		mmClient.deepBookAdmin.createPoolAdmin({
			baseCoinKey: 'USDT',
			quoteCoinKey: 'USDC',
			tickSize: 0.001,
			lotSize: 0.1,
			minSize: 1,
			whitelisted: false,
			stablePool: true,
		})(tx);

		mmClient.deepBookAdmin.createPoolAdmin({
			baseCoinKey: 'WUSDC',
			quoteCoinKey: 'USDC',
			tickSize: 0.001,
			lotSize: 0.1,
			minSize: 1,
			whitelisted: false, // Optionally whitelist this pool
			stablePool: true,
		})(tx);

		let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

		console.dir(res, { depth: null });
	}
})();
