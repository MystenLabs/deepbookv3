// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';

import { upgradeCapID } from '../config/constants';

const network = 'testnet';

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
	// on GH Action, the sui binary is located on root. Referencing that as `/` doesn't work.
	const suiFolder = process.env.ORIGIN === 'gh_action' ? '../../sui' : 'sui';
	const upgradeCall = `${suiFolder} client upgrade --upgrade-capability ${upgradeCapID[network]} --gas-budget 3000000000 --skip-dependency-verification --serialize-unsigned-transaction`;

	// we execute this on `setup/package.json` so we go one level back, access packages folder -> deepbook -> upgrade.
	// we go from scripts/(base)/packages/deepbook, we run the upgrade and then we save the transaction data
	// to deepbook/..(packages)/..(base)/scripts/tx/tx-data.txt
	execSync(`cd $PWD/../packages/deepbook && ${upgradeCall} > $PWD/../../scripts/tx/tx-data.txt`);
};

mainPackageUpgrade();
