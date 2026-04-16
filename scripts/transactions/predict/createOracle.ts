// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Creates an OracleSVI shared object for the given underlying + expiry.
/// Usage: EXPIRY=1742515200000 UNDERLYING=SUI MIN_STRIKE=100000000 TICK_SIZE=10000000 pnpm predict-create-oracle

import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../../utils/utils.js';
import {
    predictPackageID,
    predictRegistryID,
    predictObjectID,
    predictAdminCapID,
    predictOracleCapID,
} from '../../config/constants.js';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');

const network = 'testnet' as const;
const UNDERLYING_ASSET = process.env.UNDERLYING ?? 'SUI';
const MIN_STRIKE = BigInt(process.env.MIN_STRIKE ?? 100_000_000n);
const TICK_SIZE = BigInt(process.env.TICK_SIZE ?? 10_000_000n);
const EXPIRY_MS = process.env.EXPIRY
    ? BigInt(process.env.EXPIRY)
    : BigInt(Date.now()) + 30n * 24n * 60n * 60n * 1000n;

function updateConstant(content: string, name: string, net: string, value: string): string {
    const regex = new RegExp(`(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`);
    return content.replace(regex, `$1"${value}"`);
}

(async () => {
    const client = getClient(network);
    const signer = getSigner();

    console.log(`Creating Oracle on ${network}...`);
    console.log(`Underlying: ${UNDERLYING_ASSET}`);
    console.log(`Expiry:     ${new Date(Number(EXPIRY_MS)).toISOString()}`);
    console.log(`MinStrike:  ${MIN_STRIKE}`);
    console.log(`TickSize:   ${TICK_SIZE}`);

    const tx = new Transaction();
    tx.moveCall({
        target: `${predictPackageID[network]}::registry::create_oracle`,
        arguments: [
            tx.object(predictRegistryID[network]),
            tx.object(predictObjectID[network]),
            tx.object(predictAdminCapID[network]),
            tx.object(predictOracleCapID[network]),
            tx.pure.string(UNDERLYING_ASSET),
            tx.pure.u64(EXPIRY_MS),
            tx.pure.u64(MIN_STRIKE),
            tx.pure.u64(TICK_SIZE),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showObjectChanges: true },
    });
    if (result.effects?.status.status !== 'success') {
        console.error('CreateOracle failed:', result.effects?.status);
        process.exit(1);
    }

    const allChanges = result.objectChanges ?? [];
    const created = allChanges.find(
        (c: (typeof allChanges)[number]) =>
            c.type === 'created' && 'objectType' in c && c.objectType.includes('::oracle::OracleSVI'),
    );
    const oracleId = created && 'objectId' in created ? (created as { objectId: string }).objectId : '';

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictOracleID', network, oracleId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`\nOracle: ${oracleId}`);
    console.log(`Digest: ${result.digest}`);
})();
