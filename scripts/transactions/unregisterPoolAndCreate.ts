// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { prepareMultisigTx } from '../utils/utils.js';
import { adminCapOwner, adminCapID } from '../config/constants.js';
import { deepbook } from '@mysten/deepbook-v3';
import { SuiGrpcClient } from '@mysten/sui/grpc';

(async () => {
	// Update constant for env
	const env = 'mainnet';

	const client = new SuiGrpcClient({
		url: 'https://sui-mainnet.mystenlabs.com',
		network: 'mainnet',
	}).$extend(
		deepbook({
			address: '0x0',
			adminCap: adminCapID[env],
		}),
	);

	const tx = new Transaction();
	// Unregister pools with old tick size
	client.deepbook.deepBookAdmin.unregisterPoolAdmin('WUSDC_USDC')(tx);
	client.deepbook.deepBookAdmin.unregisterPoolAdmin('WUSDT_USDC')(tx);

	client.deepbook.deepBookAdmin.createPoolAdmin({
		baseCoinKey: 'WUSDC',
		quoteCoinKey: 'USDC',
		tickSize: 0.00001,
		lotSize: 0.1,
		minSize: 1,
		whitelisted: true,
		stablePool: false,
	})(tx);

	client.deepbook.deepBookAdmin.createPoolAdmin({
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
