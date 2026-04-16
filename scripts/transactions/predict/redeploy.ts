// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unified predict redeployment script (deployment-only).
///
/// Runs the full deployment pipeline end-to-end:
///   1. Resolve expiry dates (EXPIRIES env var or next N Thursdays)
///   2. Publish predict package
///   3. Init predict (create_predict<DUSDC>)
///   4. Create oracle cap
///   5. Deploy oracles for each expiry
///   6. Supply initial DUSDC into vault
///   7. Update indexer package ID
///   8. Reset local database (predict_v2)
///
/// Oracle service (BlockScholes feed, lane setup) is out of scope for this
/// script — it lives in a separate branch and reads constants.ts +
/// predict-oracles.ts as source of truth.
///
/// Usage: pnpm predict-redeploy
///   EXPIRIES="2026-05-29T08:00:00.000Z,..."  # optional, comma-separated ISO 8601
///   NUM_EXPIRIES=5                            # default when EXPIRIES unset
///   UNDERLYING=SUI                            # default
///   MIN_STRIKE=100000000                      # default
///   TICK_SIZE=10000000                        # default
///   AMOUNT=1000000                            # DUSDC whole units to supply
///   PGPORT=5433                               # local postgres port

import { Transaction } from '@mysten/sui/transactions';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
    getClient,
    getSigner,
    publishPackage,
} from '../../utils/utils.js';
import {
    dusdcPackageID,
    dusdcCurrencyID,
    dusdcTreasuryCapID,
} from '../../config/constants.js';
import type { OracleEntry } from '../../config/predict-oracles.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_PATH = path.resolve(__dirname, '../../../packages/predict');
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');
const ORACLES_CONFIG_PATH = path.resolve(__dirname, '../../config/predict-oracles.ts');
const INDEXER_LIB_PATH = path.resolve(__dirname, '../../../crates/predict-indexer/src/lib.rs');

const network = 'testnet' as const;
const UNDERLYING_ASSET = process.env.UNDERLYING ?? 'SUI';
const MIN_STRIKE = BigInt(process.env.MIN_STRIKE ?? 100_000_000n);
const TICK_SIZE = BigInt(process.env.TICK_SIZE ?? 10_000_000n);
const CLOCK = '0x6';
const SUPPLY_AMOUNT = BigInt(process.env.AMOUNT ?? 1_000_000) * 1_000_000n;
const NUM_EXPIRIES = Number(process.env.NUM_EXPIRIES ?? 5);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function updateConstant(content: string, name: string, net: string, value: string): string {
    const regex = new RegExp(`(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`);
    const result = content.replace(regex, `$1"${value}"`);
    if (result === content) {
        throw new Error(
            `updateConstant: no match for ${name}[${net}] in constants.ts — check that the constant exists and the file format hasn't drifted`,
        );
    }
    return result;
}

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

// ---------------------------------------------------------------------------
// Step 2: Publish predict package
// ---------------------------------------------------------------------------

async function publishPredict(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
) {
    // Preconditions: DUSDC must already be published.
    if (!dusdcPackageID[network] || !dusdcCurrencyID[network] || !dusdcTreasuryCapID[network]) {
        console.error(
            'DUSDC constants missing (dusdcPackageID / dusdcCurrencyID / dusdcTreasuryCapID). Run pnpm dusdc-publish first.',
        );
        process.exit(1);
    }

    console.log('\n[2/8] Publishing predict package...');

    const tx = new Transaction();
    publishPackage(tx, PREDICT_PATH);

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showObjectChanges: true },
    });

    if (result.effects?.status.status !== 'success') {
        console.error('Publish failed:', result.effects?.status);
        process.exit(1);
    }

    const waitResult = await client.waitForTransaction({ digest: result.digest });
    const publishCheckpoint = waitResult.checkpoint;

    const objectChanges = result.objectChanges ?? [];
    const created = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'created');
    const published = objectChanges.filter((c: (typeof objectChanges)[number]) => c.type === 'published');

    let registryId = '';
    let adminCapId = '';
    let upgradeCapId = '';
    let packageId = '';

    for (const p of published) {
        if (p.type !== 'published') continue;
        if (p.modules?.some((m: string) => m === 'registry')) {
            packageId = p.packageId;
        }
    }

    for (const obj of created) {
        if (obj.type !== 'created') continue;
        if (obj.objectType.includes('::registry::Registry')) registryId = obj.objectId;
        if (obj.objectType.includes('::registry::AdminCap')) adminCapId = obj.objectId;
        if (obj.objectType.includes('UpgradeCap')) upgradeCapId = obj.objectId;
    }

    // PLP TreasuryCap is minted during plp::init and transferred to the publisher.
    const plpCapObjectType = `0x2::coin::TreasuryCap<${packageId}::plp::PLP>`;
    let plpTreasuryCapId = '';
    for (const obj of created) {
        if (obj.type !== 'created') continue;
        if (obj.objectType === plpCapObjectType) {
            plpTreasuryCapId = obj.objectId;
            break;
        }
    }
    if (!plpTreasuryCapId) {
        console.error(`Could not find TreasuryCap<PLP> (${plpCapObjectType}) in objectChanges.`);
        process.exit(1);
    }

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictPackageID', network, packageId);
    constants = updateConstant(constants, 'predictRegistryID', network, registryId);
    constants = updateConstant(constants, 'predictAdminCapID', network, adminCapId);
    constants = updateConstant(constants, 'predictUpgradeCapID', network, upgradeCapId);
    constants = updateConstant(constants, 'plpTreasuryCapID', network, plpTreasuryCapId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`  Package:       ${packageId}`);
    console.log(`  Registry:      ${registryId}`);
    console.log(`  AdminCap:      ${adminCapId}`);
    console.log(`  UpgradeCap:    ${upgradeCapId}`);
    console.log(`  PLPTreasuryCap:${plpTreasuryCapId}`);
    console.log(`  Checkpoint:    ${publishCheckpoint}`);
    console.log(`  Digest:        ${result.digest}`);

    return {
        packageId,
        registryId,
        adminCapId,
        upgradeCapId,
        plpTreasuryCapId,
        publishCheckpoint,
    };
}

// ---------------------------------------------------------------------------
// Step 3: Init predict (create_predict<DUSDC>)
// ---------------------------------------------------------------------------

async function initPredict(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
    packageId: string,
    registryId: string,
    adminCapId: string,
    plpTreasuryCapId: string,
) {
    console.log('\n[3/8] Initializing predict (create_predict<DUSDC>)...');

    const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

    const tx = new Transaction();
    tx.moveCall({
        target: `${packageId}::registry::create_predict`,
        typeArguments: [DUSDC_TYPE],
        arguments: [
            tx.object(registryId),
            tx.object(adminCapId),
            tx.object(dusdcCurrencyID[network]),
            tx.object(plpTreasuryCapId),
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
    await client.waitForTransaction({ digest: result.digest });

    let predictId = '';
    for (const obj of result.objectChanges ?? []) {
        if (obj.type !== 'created') continue;
        if (obj.objectType.includes('::predict::Predict')) {
            predictId = obj.objectId;
        }
    }

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictObjectID', network, predictId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`  Predict<DUSDC>: ${predictId}`);
    console.log(`  Digest:         ${result.digest}`);

    return { predictId };
}

// ---------------------------------------------------------------------------
// Step 4: Create oracle cap
// ---------------------------------------------------------------------------

async function createOracleCap(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
    address: string,
    packageId: string,
    adminCapId: string,
) {
    console.log('\n[4/8] Creating oracle cap...');

    const tx = new Transaction();
    const oracleCap = tx.moveCall({
        target: `${packageId}::registry::create_oracle_cap`,
        arguments: [tx.object(adminCapId)],
    });
    tx.transferObjects([oracleCap], tx.pure.address(address));

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showObjectChanges: true },
    });

    if (result.effects?.status.status !== 'success') {
        console.error('CreateOracleCap failed:', result.effects?.status);
        process.exit(1);
    }

    await client.waitForTransaction({ digest: result.digest });

    let oracleCapId = '';
    for (const obj of result.objectChanges ?? []) {
        if (obj.type !== 'created') continue;
        if (obj.objectType.includes('::oracle::OracleSVICap')) {
            oracleCapId = obj.objectId;
        }
    }

    if (!oracleCapId) {
        console.error('Could not find OracleSVICap in objectChanges.');
        process.exit(1);
    }

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictOracleCapID', network, oracleCapId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`  OracleSVICap: ${oracleCapId}`);
    console.log(`  Digest:       ${result.digest}`);

    return { oracleCapId };
}

// ---------------------------------------------------------------------------
// Step 5: Deploy oracles
// ---------------------------------------------------------------------------

async function deployOracles(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
    packageId: string,
    registryId: string,
    predictId: string,
    adminCapId: string,
    oracleCapId: string,
    expiries: string[],
): Promise<OracleEntry[]> {
    console.log(`\n[5/8] Deploying ${expiries.length} oracles...`);

    const entries: OracleEntry[] = [];

    for (const expiryIso of expiries) {
        const expiryMs = new Date(expiryIso).getTime();
        console.log(`  Creating oracle for ${expiryIso} (${expiryMs})...`);

        const tx = new Transaction();
        tx.moveCall({
            target: `${packageId}::registry::create_oracle`,
            arguments: [
                tx.object(registryId),
                tx.object(predictId),
                tx.object(adminCapId),
                tx.object(oracleCapId),
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

        await client.waitForTransaction({ digest: result.digest });

        if (result.effects?.status.status !== 'success') {
            console.error(`  FAILED:`, result.effects?.status);
            process.exit(1);
        }

        let oracleId = '';
        for (const obj of result.objectChanges ?? []) {
            if (obj.type !== 'created') continue;
            if (obj.objectType.includes('::oracle::OracleSVI')) {
                oracleId = obj.objectId;
            }
        }

        if (!oracleId) {
            console.error(`  Could not find OracleSVI in objectChanges`);
            process.exit(1);
        }

        console.log(`    Oracle: ${oracleId}`);
        entries.push({
            oracleId,
            expiry: expiryIso,
            expiryMs,
            underlying: UNDERLYING_ASSET,
        });
    }

    const configContent = `// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OracleEntry {
    oracleId: string;
    expiry: string; // ISO 8601
    expiryMs: number; // on-chain milliseconds
    underlying: string; // Move type arg
}

export const predictOracles: Record<string, OracleEntry[]> = {
    testnet: ${JSON.stringify(entries, null, 4)},
    mainnet: [],
};
`;
    fs.writeFileSync(ORACLES_CONFIG_PATH, configContent);

    console.log(`  Written ${entries.length} oracle entries to config/predict-oracles.ts`);
    return entries;
}

// ---------------------------------------------------------------------------
// Step 6: Supply initial DUSDC
// ---------------------------------------------------------------------------

async function supplyDUSDC(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
    address: string,
    packageId: string,
    predictId: string,
) {
    console.log(`\n[6/8] Supplying ${Number(SUPPLY_AMOUNT) / 1e6} DUSDC into vault...`);

    const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

    const tx = new Transaction();

    const coin = tx.moveCall({
        target: '0x2::coin::mint',
        typeArguments: [DUSDC_TYPE],
        arguments: [
            tx.object(dusdcTreasuryCapID[network]),
            tx.pure.u64(SUPPLY_AMOUNT),
        ],
    });

    // Move signature: supply<Quote>(predict, coin, clock, ctx) -> Coin<PLP>
    const lpCoin = tx.moveCall({
        target: `${packageId}::predict::supply`,
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(predictId), coin, tx.object(CLOCK)],
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

    await client.waitForTransaction({ digest: result.digest });

    console.log(`  Supplied ${Number(SUPPLY_AMOUNT) / 1e6} DUSDC. Digest: ${result.digest}`);
}

// ---------------------------------------------------------------------------
// Step 7: Update indexer package ID
// ---------------------------------------------------------------------------

function updateIndexerPackageId(packageId: string) {
    console.log('\n[7/8] Updating indexer package ID...');

    let content = fs.readFileSync(INDEXER_LIB_PATH, 'utf-8');
    content = content.replace(
        /const TESTNET_PREDICT_PACKAGES: &\[&str\] = &\[\s*"0x[0-9a-f]+",?\s*\];/,
        `const TESTNET_PREDICT_PACKAGES: &[&str] = &[\n    "${packageId}",\n];`,
    );
    fs.writeFileSync(INDEXER_LIB_PATH, content);

    console.log(`  Updated crates/predict-indexer/src/lib.rs`);
    console.log(`  New package ID: ${packageId}`);
}

// ---------------------------------------------------------------------------
// Step 8: Reset database
// ---------------------------------------------------------------------------

function resetDatabase() {
    console.log('\n[8/8] Resetting predict_v2 database...');

    const pgPort = process.env.PGPORT ?? '5433';
    try {
        execSync(
            `psql -p ${pgPort} postgres ` +
                `-c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'predict_v2' AND pid <> pg_backend_pid()" ` +
                `-c "DROP DATABASE IF EXISTS predict_v2" ` +
                `-c "CREATE DATABASE predict_v2"`,
            { stdio: 'inherit' },
        );
        console.log('  Database reset complete (predict_v2 dropped & recreated)');
    } catch (e) {
        console.error('  Database reset failed:', e);
        process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

(async () => {
    const client = getClient(network);
    const signer = getSigner();
    const address = signer.toSuiAddress();

    console.log('='.repeat(60));
    console.log('Predict Redeployment — Deployment-Only Pipeline');
    console.log('='.repeat(60));
    console.log(`Network:  ${network}`);
    console.log(`Deployer: ${address}`);

    // Step 1
    console.log('\n[1/8] Resolving expiries...');
    const expiries = resolveExpiries();
    for (const iso of expiries) console.log(`  - ${iso}`);

    // Step 2
    const {
        packageId,
        registryId,
        adminCapId,
        upgradeCapId,
        plpTreasuryCapId,
        publishCheckpoint,
    } = await publishPredict(client, signer);

    // Step 3
    const { predictId } = await initPredict(
        client,
        signer,
        packageId,
        registryId,
        adminCapId,
        plpTreasuryCapId,
    );

    // Step 4
    const { oracleCapId } = await createOracleCap(client, signer, address, packageId, adminCapId);

    // Step 5
    const oracles = await deployOracles(
        client,
        signer,
        packageId,
        registryId,
        predictId,
        adminCapId,
        oracleCapId,
        expiries,
    );

    // Step 6
    await supplyDUSDC(client, signer, address, packageId, predictId);

    // Step 7
    updateIndexerPackageId(packageId);

    // Step 8
    resetDatabase();

    // Final summary
    console.log('\n' + '='.repeat(60));
    console.log('DEPLOYMENT COMPLETE');
    console.log('='.repeat(60));
    console.log(`Package:        ${packageId}`);
    console.log(`Registry:       ${registryId}`);
    console.log(`AdminCap:       ${adminCapId}`);
    console.log(`UpgradeCap:     ${upgradeCapId}`);
    console.log(`PLPTreasuryCap: ${plpTreasuryCapId}`);
    console.log(`Predict:        ${predictId}`);
    console.log(`OracleCap:      ${oracleCapId}`);
    console.log(`Oracles:        ${oracles.length}`);
    for (const o of oracles) {
        console.log(`  ${o.expiry} -> ${o.oracleId}`);
    }
    console.log(`DUSDC supply:   ${Number(SUPPLY_AMOUNT) / 1e6}`);
    console.log(`Indexer:        package ID updated`);
    console.log(`Database:       predict_v2 reset`);
    console.log(`Checkpoint:     ${publishCheckpoint}`);
    console.log('='.repeat(60));
    console.log('\nOracle service inputs ready:');
    console.log('  - scripts/config/constants.ts (predictPackageID, predictObjectID, predictOracleCapID)');
    console.log('  - scripts/config/predict-oracles.ts (predictOracles.testnet)');
    console.log('Start the indexer:');
    console.log(`  cargo run -p predict-indexer -- --first-checkpoint ${publishCheckpoint}`);
})();
