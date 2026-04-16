// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Deploys one OracleSVI per expiry on testnet.
/// Usage: EXPIRIES="2026-05-29T08:00:00.000Z,..." pnpm tsx transactions/predict/deployOracles.ts
/// If EXPIRIES is not set, uses next N Thursdays at 08:00 UTC (N = NUM_EXPIRIES, default 5).

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
    predictPackageID,
    predictRegistryID,
    predictObjectID,
    predictAdminCapID,
    predictOracleCapID,
} from '../../config/constants.js';
import {
    predictOracles,
    type OracleEntry,
} from '../../config/predict-oracles.js';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ORACLES_CONFIG_PATH = path.resolve(__dirname, '../../config/predict-oracles.ts');

const network = 'testnet' as const;
const UNDERLYING_ASSET = process.env.UNDERLYING ?? 'BTC';
const MIN_STRIKE = BigInt(process.env.MIN_STRIKE ?? 50_000_000_000_000n);
const TICK_SIZE = BigInt(process.env.TICK_SIZE ?? 1_000_000_000n);
const NUM_EXPIRIES = Number(process.env.NUM_EXPIRIES ?? 5);

function resolveExpiries(): string[] {
    const raw = process.env.EXPIRIES;
    if (raw && raw.trim()) {
        const list = raw.split(',').map((s) => s.trim()).filter(Boolean);
        for (const iso of list) {
            if (isNaN(new Date(iso).getTime())) {
                console.error(`EXPIRIES contains invalid ISO 8601: ${iso}`);
                process.exit(1);
            }
        }
        if (list.length === 0) {
            console.error('EXPIRIES env var is empty after split.');
            process.exit(1);
        }
        return list;
    }
    const dates: string[] = [];
    const d = new Date();
    d.setUTCHours(8, 0, 0, 0);
    const dow = d.getUTCDay();
    const daysUntilThursday = ((4 - dow + 7) % 7) || 7;
    d.setUTCDate(d.getUTCDate() + daysUntilThursday);
    for (let i = 0; i < NUM_EXPIRIES; i++) {
        dates.push(new Date(d.getTime()).toISOString());
        d.setUTCDate(d.getUTCDate() + 7);
    }
    return dates;
}

(async () => {
    const client = getClient(network);
    const signer = getSigner();
    const address = getActiveAddress();

    const expiries = resolveExpiries();

    console.log(`Deploying ${expiries.length} oracles on ${network}`);
    console.log(`Deployer:   ${address}`);
    console.log(`Package:    ${predictPackageID[network]}`);
    console.log(`Cap:        ${predictOracleCapID[network]}`);
    console.log(`Underlying: ${UNDERLYING_ASSET}\n`);

    const entries: OracleEntry[] = [];

    for (const expiryIso of expiries) {
        const expiryMs = new Date(expiryIso).getTime();

        console.log(`Creating oracle for ${expiryIso} (${expiryMs})...`);

        const tx = new Transaction();
        tx.moveCall({
            target: `${predictPackageID[network]}::registry::create_oracle`,
            arguments: [
                tx.object(predictRegistryID[network]),
                tx.object(predictObjectID[network]),
                tx.object(predictAdminCapID[network]),
                tx.object(predictOracleCapID[network]),
                tx.pure.string(UNDERLYING_ASSET),
                tx.pure.u64(expiryMs),
                tx.pure.u64(MIN_STRIKE),
                tx.pure.u64(TICK_SIZE),
            ],
        });

        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer,
            options: { showEffects: true, showObjectChanges: true },
        });

        // Wait for finalization so shared-object versions advance before the next tx.
        await client.waitForTransaction({ digest: result.digest });

        if (result.effects?.status.status !== 'success') {
            console.error(`  FAILED:`, result.effects?.status);
            process.exit(1);
        }

        let oracleId = '';
        const allChanges = result.objectChanges ?? [];
        const created = allChanges.filter((c: (typeof allChanges)[number]) => c.type === 'created');
        for (const obj of created) {
            if (obj.type !== 'created') continue;
            if (obj.objectType.includes('::oracle::OracleSVI')) {
                oracleId = obj.objectId;
            }
        }

        if (!oracleId) {
            console.error(`  Could not find OracleSVI in objectChanges`);
            process.exit(1);
        }

        console.log(`  Oracle: ${oracleId}`);
        console.log(`  Digest: ${result.digest}\n`);

        entries.push({
            oracleId,
            expiry: expiryIso,
            expiryMs,
            underlying: UNDERLYING_ASSET,
        });
    }

    // Merge with existing non-expired oracles
    const now = Date.now();
    const existing = (predictOracles[network] ?? []).filter((o: OracleEntry) => o.expiryMs > now);
    const allOracles = [...existing, ...entries].sort((a, b) => a.expiryMs - b.expiryMs);

    const configContent = `// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OracleEntry {
    oracleId: string;
    expiry: string; // ISO 8601
    expiryMs: number; // on-chain milliseconds
    underlying: string; // Move type arg
}

export const predictOracles: Record<string, OracleEntry[]> = {
    testnet: ${JSON.stringify(allOracles, null, 4)},
    mainnet: [],
};
`;

    fs.writeFileSync(ORACLES_CONFIG_PATH, configContent);
    console.log(
        `Written ${allOracles.length} oracle entries to config/predict-oracles.ts (${existing.length} existing + ${entries.length} new)`,
    );
})();
