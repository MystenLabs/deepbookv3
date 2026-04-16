// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
    predictPackageID,
    predictObjectID,
    dusdcPackageID,
    dusdcTreasuryCapID,
} from '../../config/constants.js';

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = '0x6';
const DEPOSIT_AMOUNT = BigInt(process.env.AMOUNT ?? 1_000_000) * 1_000_000n;

(async () => {
    const client = getClient(network);
    const signer = getSigner();
    const address = getActiveAddress();

    const tx = new Transaction();
    const coin = tx.moveCall({
        target: '0x2::coin::mint',
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(dusdcTreasuryCapID[network]), tx.pure.u64(DEPOSIT_AMOUNT)],
    });
    // Move signature: supply<Quote>(predict, coin, clock, ctx)
    const lpCoin = tx.moveCall({
        target: `${predictPackageID[network]}::predict::supply`,
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(predictObjectID[network]), coin, tx.object(CLOCK)],
    });
    tx.transferObjects([lpCoin], tx.pure.address(address));

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true },
    });
    if (result.effects?.status.status !== 'success') {
        console.error('Supply failed:', result.effects?.status);
        process.exit(1);
    }
    console.log(`Supplied ${Number(DEPOSIT_AMOUNT) / 1e6} DUSDC. Digest: ${result.digest}`);
})();
