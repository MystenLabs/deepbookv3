// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { prepareMultisigTx } from '../utils/utils';
import { adminCapOwner, adminCapID } from '../config/constants';
import { DeepBookClient } from '@mysten/deepbook-v3';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';

(async () => {
	// Update constant for env
	const env = 'mainnet';

	// Initialize with balance managers if needed
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
		adminCap: adminCapID[env],
	});

	const tx = new Transaction();
	// Unregister pools with old tick size
	dbClient.deepBookAdmin.unregisterPoolAdmin('DEEP_SUI')(tx);
	dbClient.deepBookAdmin.unregisterPoolAdmin('DEEP_USDC')(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'SUI',
		tickSize: 0.00001,
		lotSize: 100,
		minSize: 1000,
		whitelisted: true,
		stablePool: false,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'DEEP',
		quoteCoinKey: 'USDC',
		tickSize: 0.00001,
		lotSize: 100,
		minSize: 1000,
		whitelisted: true,
		stablePool: false,
	})(tx);

	let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

	console.dir(res, { depth: null });
})();
