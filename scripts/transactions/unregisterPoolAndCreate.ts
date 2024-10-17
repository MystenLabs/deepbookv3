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
	dbClient.deepBookAdmin.unregisterPoolAdmin('WUSDC_USDC')(tx);
	dbClient.deepBookAdmin.unregisterPoolAdmin('WUSDT_USDC')(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'WUSDC',
		quoteCoinKey: 'USDC',
		tickSize: 0.00001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: true,
		stablePool: false,
	})(tx);

	dbClient.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'WUSDT',
		quoteCoinKey: 'USDC',
		tickSize: 0.00001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: false,
		stablePool: true,
	})(tx);

	let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

	console.dir(res, { depth: null });
})();
