// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';
import { upgradeCapID } from '../config/constants';
import path from 'path';
import fs from 'fs';

const network = 'mainnet';

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
    const gasObjectId = process.env.GAS_OBJECT;

    // Enabling the gas Object check only on mainnet, to allow testnet multisig tests.
    if (!gasObjectId) throw new Error('No gas object supplied for a mainnet transaction');

    const packagesDir = path.resolve(__dirname, '../../packages/deepbook');
    const txFilePath = path.resolve(__dirname, '../../scripts/tx/tx-data.txt');

    // Construct the command
    const upgradeCall = `sui client upgrade --upgrade-capability ${upgradeCapID[network]} --gas-budget 3000000000 --gas ${gasObjectId} --skip-dependency-verification --serialize-unsigned-transaction`;

    try {
        // Execute the command with the specified working directory and capture the output
        const output = execSync(upgradeCall, { cwd: packagesDir });

        // Write the output to the tx-data.txt file
        fs.writeFileSync(txFilePath, output.toString());
        console.log('Upgrade transaction successfully created and saved to tx-data.txt');
    } catch (error: any) {
        console.error('Error during protocol upgrade:', error.message);
        console.error('stderr:', error.stderr?.toString());
        console.error('stdout:', error.stdout?.toString());
        console.error('Command:', error.cmd);
        process.exit(1); // Exit with an error code
    }
};

mainPackageUpgrade();
