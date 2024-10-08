// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { prepareMultisigTx } from '../utils/utils';
import { adminCapOwner } from '../config/constants';
import { DeepBookClient } from '@mysten/deepbook-v3';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';

(async () => {
	// Update constant for env
	const env = 'mainnet';
	const adminCap = '0xd542cd47d94009452de200032ac80ff1ceb31bb5f9ed6df5d97c9ae54a1976dd';

	// Initialize with balance managers if created
	const balanceManagers = {
		MANAGER_1: {
			address: '',
			tradeCap: '',
		},
	};

	const dbClient = new DeepBookClient({
		address: '0x0',
		env: env,
		client: new SuiClient({
			url: getFullnodeUrl(env),
		}),
		balanceManagers: balanceManagers,
		adminCap: adminCap,
	});

	const tx = new Transaction();

	// Testnet
	// mmClient.deepBookAdmin.createPoolAdmin({
	// 	baseCoinKey: 'DEEP',
	// 	quoteCoinKey: 'SUI',
	// 	tickSize: 0.001,
	// 	lotSize: 1,
	// 	minSize: 10,
	// 	whitelisted: true,
	// 	stablePool: false,
	// })(tx);

	// mmClient.deepBookAdmin.createPoolAdmin({
	// 	baseCoinKey: 'SUI',
	// 	quoteCoinKey: 'DBUSDC',
	// 	tickSize: 0.001,
	// 	lotSize: 0.1,
	// 	minSize: 1,
	// 	whitelisted: false,
	// 	stablePool: false,
	// })(tx);

	// mmClient.deepBookAdmin.createPoolAdmin({
	// 	baseCoinKey: 'DEEP',
	// 	quoteCoinKey: 'DBUSDC',
	// 	tickSize: 0.001,
	// 	lotSize: 1,
	// 	minSize: 10,
	// 	whitelisted: true,
	// 	stablePool: false,
	// })(tx);

	// mmClient.deepBookAdmin.createPoolAdmin({
	// 	baseCoinKey: 'DBUSDT',
	// 	quoteCoinKey: 'DBUSDC',
	// 	tickSize: 0.001,
	// 	lotSize: 0.1,
	// 	minSize: 1,
	// 	whitelisted: false,
	// 	stablePool: true,
	// })(tx);

	// let res = await mmClient.signAndExecute(tx);

	// console.dir(res, { depth: null });

	// mainnet
	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'SUI',
		tickSize: 0.001,
		lotSize: 1,
		minSize: 10,
		whitelisted: true,
		stablePool: false,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'SUI',
		quoteCoinKey: 'USDC',
		tickSize: 0.001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: false,
		stablePool: false,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'USDC',
		tickSize: 0.001,
		lotSize: 1,
		minSize: 10,
		whitelisted: true,
		stablePool: false,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'WUSDT',
		quoteCoinKey: 'USDC',
		tickSize: 0.001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: false,
		stablePool: true,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
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
})();
