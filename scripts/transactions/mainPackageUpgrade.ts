// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';

import { upgradeCapID } from '../config/constants';

const network = 'testnet';
const gasObject = '0x015c81bb048561bedbf687920c1a623ecdf3df4e91236d086dde8b564c3a3f61'

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
	// on GH Action, the sui binary is located on root. Referencing that as `/` doesn't work.
	const upgradeCall = `sui client upgrade --upgrade-capability ${upgradeCapID[network]} --gas-budget 3000000000 --gas ${gasObject} --skip-dependency-verification --serialize-unsigned-transaction`;

	execSync(`cd packages/deepbook && ${upgradeCall} > ../../scripts/tx/tx-data.txt`);
};

mainPackageUpgrade();
