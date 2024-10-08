// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';

import { upgradeCapID } from '../config/constants';

const network = 'mainnet';

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
	// on GH Action, the sui binary is located on root. Referencing that as `/` doesn't work.
    const gasObjectId = process.env.GAS_OBJECT;

	// enabling the gas Object check only on mainnet, to allow testnet multisig tests.
	if (!gasObjectId) throw new Error('No gas object supplied for a mainnet transaction');

    const suiFolder = process.env.ORIGIN === 'gh_action' ? '../sui' : 'sui';
	const upgradeCall = `${suiFolder} client upgrade --upgrade-capability ${upgradeCapID[network]} --gas-budget 3000000000 --gas ${gasObjectId} --skip-dependency-verification --serialize-unsigned-transaction`;

    execSync(`cd $PWD/../packages/deepbook && ${upgradeCall} > $PWD/../../scripts/tx/tx-data.txt`);
};

mainPackageUpgrade();
