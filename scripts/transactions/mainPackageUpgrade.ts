// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';

import { upgradeCapID } from '../config/constants';

const network = 'mainnet';
const gasObject = '0xb76abcaefff13813adfa61768fac06a13a9bdbe7c86fb75118885364452286cb'

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
	// on GH Action, the sui binary is located on root. Referencing that as `/` doesn't work.
	const upgradeCall = `sui client upgrade --upgrade-capability ${upgradeCapID[network]} --gas-budget 3000000000 --gas ${gasObject} --skip-dependency-verification --serialize-unsigned-transaction`;

    execSync(`cd $PWD/../packages/deepbook && ${upgradeCall} > $PWD/../../scripts/tx/tx-data.txt`);
};

mainPackageUpgrade();
