// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Clean predict redeployment — fresh package + core shared objects.
///
/// Pipeline:
///   1. Publish predict package
///   2. Init predict (create_predict<DUSDC>)
///   3. Update indexer TESTNET_PREDICT_PACKAGES
///   4. Reset local predict_v2 database
///
/// The oracle-feed service owns oracle cap creation, oracle creation,
/// registration, activation, settlement, and compaction — so this script
/// no longer runs createOracleCap / deployOracles. Initial DUSDC vault
/// supply is a separate operator step (pnpm predict-deposit).
///
/// Usage: pnpm predict-redeploy
///   PGPORT=5433    # local postgres port (default 5433)
///
/// Precondition: DUSDC must already be published.
///   pnpm dusdc-publish

import { Transaction } from '@mysten/sui/transactions';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
    getClient,
    getSigner,
    publishPackage,
    updateConstant,
} from '../../utils/utils.js';
import {
    dusdcPackageID,
    dusdcCurrencyID,
    dusdcTreasuryCapID,
} from '../../config/constants.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_PATH = path.resolve(__dirname, '../../../packages/predict');
const CONSTANTS_PATH = path.resolve(__dirname, '../../config/constants.ts');
const INDEXER_LIB_PATH = path.resolve(__dirname, '../../../crates/predict-indexer/src/lib.rs');

const network = 'testnet' as const;
const CLOCK = '0x6';

// ---------------------------------------------------------------------------
// Step 1: Publish predict package
// ---------------------------------------------------------------------------

async function publishPredict(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
) {
    if (!dusdcPackageID[network] || !dusdcCurrencyID[network] || !dusdcTreasuryCapID[network]) {
        console.error(
            'DUSDC constants missing (dusdcPackageID / dusdcCurrencyID / dusdcTreasuryCapID). Run pnpm dusdc-publish first.',
        );
        process.exit(1);
    }

    console.log('\n[1/4] Publishing predict package...');

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

    const changes = result.objectChanges ?? [];
    const created = changes.filter((c) => c.type === 'created');
    const published = changes.filter((c) => c.type === 'published');

    let registryId = '';
    let adminCapId = '';
    let upgradeCapId = '';
    let packageId = '';

    for (const p of published) {
        if (p.type !== 'published') continue;
        if (p.modules?.some((m: string) => m === 'registry')) packageId = p.packageId;
    }

    for (const obj of created) {
        if (obj.type !== 'created') continue;
        if (obj.objectType.includes('::registry::Registry')) registryId = obj.objectId;
        if (obj.objectType.includes('::registry::AdminCap')) adminCapId = obj.objectId;
        if (obj.objectType.includes('UpgradeCap')) upgradeCapId = obj.objectId;
    }

    // plp::init mints a TreasuryCap<PLP> and transfers it to the publisher.
    // registry::create_predict<DUSDC> consumes it.
    const plpCapType = `0x2::coin::TreasuryCap<${packageId}::plp::PLP>`;
    let plpTreasuryCapId = '';
    for (const obj of created) {
        if (obj.type !== 'created') continue;
        if (obj.objectType === plpCapType) {
            plpTreasuryCapId = obj.objectId;
            break;
        }
    }
    if (!plpTreasuryCapId) {
        console.error(`Could not find TreasuryCap<PLP> (${plpCapType}) in objectChanges.`);
        process.exit(1);
    }

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictPackageID', network, packageId);
    constants = updateConstant(constants, 'predictRegistryID', network, registryId);
    constants = updateConstant(constants, 'predictAdminCapID', network, adminCapId);
    constants = updateConstant(constants, 'predictUpgradeCapID', network, upgradeCapId);
    constants = updateConstant(constants, 'plpTreasuryCapID', network, plpTreasuryCapId);
    // Clear stale oracle cap ID — the oracle-feed service will create fresh caps.
    constants = updateConstant(constants, 'predictOracleCapID', network, '');
    constants = updateConstant(constants, 'predictObjectID', network, '');
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`  Package:       ${packageId}`);
    console.log(`  Registry:      ${registryId}`);
    console.log(`  AdminCap:      ${adminCapId}`);
    console.log(`  UpgradeCap:    ${upgradeCapId}`);
    console.log(`  PLPTreasuryCap:${plpTreasuryCapId}`);
    console.log(`  Checkpoint:    ${publishCheckpoint}`);
    console.log(`  Digest:        ${result.digest}`);

    return { packageId, registryId, adminCapId, upgradeCapId, plpTreasuryCapId, publishCheckpoint };
}

// ---------------------------------------------------------------------------
// Step 2: Init predict
// ---------------------------------------------------------------------------

async function initPredict(
    client: ReturnType<typeof getClient>,
    signer: ReturnType<typeof getSigner>,
    packageId: string,
    registryId: string,
    adminCapId: string,
    plpTreasuryCapId: string,
) {
    console.log('\n[2/4] Initializing predict (create_predict<DUSDC>)...');

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

    const predictCreated = (result.objectChanges ?? []).find(
        (c) => c.type === 'created' && 'objectType' in c && c.objectType.includes('::predict::Predict'),
    );
    const predictId = predictCreated && 'objectId' in predictCreated ? predictCreated.objectId : '';
    if (!predictId) {
        console.error('Could not find Predict<DUSDC> in objectChanges.');
        process.exit(1);
    }

    let constants = fs.readFileSync(CONSTANTS_PATH, 'utf-8');
    constants = updateConstant(constants, 'predictObjectID', network, predictId);
    fs.writeFileSync(CONSTANTS_PATH, constants);

    console.log(`  Predict<DUSDC>: ${predictId}`);
    console.log(`  Digest:         ${result.digest}`);

    return { predictId };
}

// ---------------------------------------------------------------------------
// Step 3: Update indexer package ID
// ---------------------------------------------------------------------------

function updateIndexerPackageId(packageId: string) {
    console.log('\n[3/4] Updating indexer package ID...');

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
// Step 4: Reset database
// ---------------------------------------------------------------------------

function resetDatabase() {
    console.log('\n[4/4] Resetting predict_v2 database...');

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
    console.log('Predict Redeployment — Publish + Init Only');
    console.log('='.repeat(60));
    console.log(`Network:  ${network}`);
    console.log(`Deployer: ${address}`);

    const {
        packageId,
        registryId,
        adminCapId,
        upgradeCapId,
        plpTreasuryCapId,
        publishCheckpoint,
    } = await publishPredict(client, signer);

    const { predictId } = await initPredict(
        client,
        signer,
        packageId,
        registryId,
        adminCapId,
        plpTreasuryCapId,
    );

    updateIndexerPackageId(packageId);
    resetDatabase();

    console.log('\n' + '='.repeat(60));
    console.log('DEPLOYMENT COMPLETE');
    console.log('='.repeat(60));
    console.log(`Package:        ${packageId}`);
    console.log(`Registry:       ${registryId}`);
    console.log(`AdminCap:       ${adminCapId}`);
    console.log(`UpgradeCap:     ${upgradeCapId}`);
    console.log(`PLPTreasuryCap: ${plpTreasuryCapId}`);
    console.log(`Predict:        ${predictId}`);
    console.log(`Indexer:        package ID updated`);
    console.log(`Database:       predict_v2 reset`);
    console.log(`Checkpoint:     ${publishCheckpoint}`);
    console.log('='.repeat(60));
    console.log('\nNext steps:');
    console.log('  - Start the oracle-feed service to create caps + oracles:');
    console.log(`      pnpm oracle-feed  # or via Pulumi`);
    console.log('  - Seed initial LP liquidity (optional):');
    console.log('      pnpm predict-deposit');
    console.log('  - Start the indexer:');
    console.log(`      cargo run -p predict-indexer -- --first-checkpoint ${publishCheckpoint}`);
})();
