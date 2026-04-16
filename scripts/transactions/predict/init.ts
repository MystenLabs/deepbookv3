// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner, updateConstant } from '../../utils/utils.js';
import {
    predictPackageID,
    predictRegistryID,
    predictAdminCapID,
    dusdcPackageID,
    dusdcCurrencyID,
    plpTreasuryCapID,
} from '../../config/constants.js';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');
const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';

(async () => {
    const client = getClient(network);
    const signer = getSigner();

    const tx = new Transaction();
    tx.moveCall({
        target: `${predictPackageID[network]}::registry::create_predict`,
        typeArguments: [DUSDC_TYPE],
        arguments: [
            tx.object(predictRegistryID[network]),
            tx.object(predictAdminCapID[network]),
            tx.object(dusdcCurrencyID[network]),
            tx.object(plpTreasuryCapID[network]),
            tx.object(CLOCK),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showObjectChanges: true },
    });
    if (result.effects?.status.status !== 'success') {
        console.error('Init failed:', result.effects?.status);
        process.exit(1);
    }
    const allChanges = result.objectChanges ?? [];
    const predictCreated = allChanges.find(
        (c: (typeof allChanges)[number]) =>
            c.type === 'created' && 'objectType' in c && c.objectType.includes('::predict::Predict'),
    );
    const predictId =
        predictCreated && 'objectId' in predictCreated ? (predictCreated as { objectId: string }).objectId : '';

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictObjectID', network, predictId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`Predict<DUSDC>: ${predictId}`);
    console.log(`Digest:         ${result.digest}`);
})();
