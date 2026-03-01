// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unified predict redeployment script.
/// Runs the full deployment pipeline end-to-end:
///   1. Discover expiry dates from BlockScholes API
///   2. Publish predict package
///   3. Init predict (create_predict<DUSDC>)
///   4. Create oracle cap
///   5. Deploy oracles for each expiry
///   6. Deposit DUSDC into vault
///   7. Update indexer package ID
///   8. Reset database
///
/// Usage: pnpm predict-redeploy

import { Transaction } from "@mysten/sui/transactions";
import {
  getClient,
  getSigner,
  publishPackage,
} from "../../utils/utils";
import { dusdcPackageID, dusdcTreasuryCapID } from "../../config/constants";
import {
  fetchSVIParams,
  fetchForwardPrice,
} from "../../services/blockscholes-oracle";
import type { OracleEntry } from "../../config/predict-oracles";
import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PREDICT_PATH = path.resolve(__dirname, "../../../packages/predict");
const CONSTANTS_PATH = path.resolve(__dirname, "../../config/constants.ts");
const ORACLES_CONFIG_PATH = path.resolve(
  __dirname,
  "../../config/predict-oracles.ts",
);
const INDEXER_LIB_PATH = path.resolve(
  __dirname,
  "../../../crates/predict-indexer/src/lib.rs",
);

const network = "testnet" as const;
const UNDERLYING_TYPE = "0x2::sui::SUI";
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const DEPOSIT_AMOUNT = BigInt(process.env.AMOUNT ?? 1_000_000) * 1_000_000n;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function updateConstant(
  content: string,
  name: string,
  net: string,
  value: string,
): string {
  const regex = new RegExp(
    `(export const ${name} = \\{[^}]*${net}:\\s*)"[^"]*"`,
  );
  return content.replace(regex, `$1"${value}"`);
}

function nextThursdays(count: number): Date[] {
  const dates: Date[] = [];
  const now = new Date();
  const d = new Date(
    Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth(),
      now.getUTCDate(),
      8,
      0,
      0,
      0,
    ),
  );
  // Advance to next Thursday (4)
  const day = d.getUTCDay();
  const daysUntilThursday = ((4 - day + 7) % 7) || 7;
  d.setUTCDate(d.getUTCDate() + daysUntilThursday);
  for (let i = 0; i < count; i++) {
    dates.push(new Date(d.getTime()));
    d.setUTCDate(d.getUTCDate() + 7);
  }
  return dates;
}

function nextFridays(count: number): Date[] {
  const dates: Date[] = [];
  const now = new Date();
  const d = new Date(
    Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth(),
      now.getUTCDate(),
      8,
      0,
      0,
      0,
    ),
  );
  const day = d.getUTCDay();
  const daysUntilFriday = ((5 - day + 7) % 7) || 7;
  d.setUTCDate(d.getUTCDate() + daysUntilFriday);
  for (let i = 0; i < count; i++) {
    dates.push(new Date(d.getTime()));
    d.setUTCDate(d.getUTCDate() + 7);
  }
  return dates;
}

// ---------------------------------------------------------------------------
// Step 1: Discover expiry dates
// ---------------------------------------------------------------------------

async function discoverExpiries(): Promise<string[]> {
  console.log("\n[1/8] Discovering expiry dates from BlockScholes API...");

  const TARGET = 5;
  const valid: string[] = [];

  const candidates = nextThursdays(12);
  for (const d of candidates) {
    if (valid.length >= TARGET) break;
    const iso = d.toISOString();
    try {
      await fetchSVIParams(iso);
      await fetchForwardPrice(iso);
      valid.push(iso);
      console.log(`  ✓ ${iso}`);
    } catch {
      console.log(`  ✗ ${iso} (no data)`);
    }
  }

  // Fallback to Fridays if we don't have enough
  if (valid.length < TARGET) {
    console.log("  Trying Fridays as fallback...");
    const fridays = nextFridays(12);
    for (const d of fridays) {
      if (valid.length >= TARGET) break;
      const iso = d.toISOString();
      if (valid.includes(iso)) continue;
      try {
        await fetchSVIParams(iso);
        await fetchForwardPrice(iso);
        valid.push(iso);
        console.log(`  ✓ ${iso} (Friday)`);
      } catch {
        console.log(`  ✗ ${iso} (no data)`);
      }
    }
  }

  if (valid.length === 0) {
    console.error("No valid expiry dates found!");
    process.exit(1);
  }

  console.log(`  Found ${valid.length} valid expiries`);
  return valid;
}

// ---------------------------------------------------------------------------
// Step 2: Publish predict package
// ---------------------------------------------------------------------------

async function publishPredict(
  client: ReturnType<typeof getClient>,
  signer: ReturnType<typeof getSigner>,
  address: string,
) {
  console.log("\n[2/8] Publishing predict package...");

  const tx = new Transaction();
  publishPackage(tx, PREDICT_PATH);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  if (result.effects?.status.status !== "success") {
    console.error("Publish failed:", result.effects?.status);
    process.exit(1);
  }

  // Wait for the publish tx to finalize so the package is available on RPC
  const waitResult = await client.waitForTransaction({ digest: result.digest });
  const publishCheckpoint = waitResult.checkpoint;

  const objectChanges = result.objectChanges ?? [];
  const created = objectChanges.filter((c) => c.type === "created");
  const published = objectChanges.filter((c) => c.type === "published");

  let registryId = "";
  let adminCapId = "";
  let upgradeCapId = "";
  let packageId = "";

  for (const obj of created) {
    if (obj.type !== "created") continue;
    if (obj.objectType.includes("::registry::Registry"))
      registryId = obj.objectId;
    if (obj.objectType.includes("::registry::AdminCap"))
      adminCapId = obj.objectId;
    if (obj.objectType.includes("UpgradeCap")) upgradeCapId = obj.objectId;
  }

  for (const p of published) {
    if (p.type !== "published") continue;
    if (p.modules?.some((m: string) => m === "registry")) {
      packageId = p.packageId;
    }
  }

  // Write to constants.ts
  let constants = fs.readFileSync(CONSTANTS_PATH, "utf-8");
  constants = updateConstant(constants, "predictPackageID", network, packageId);
  constants = updateConstant(
    constants,
    "predictRegistryID",
    network,
    registryId,
  );
  constants = updateConstant(
    constants,
    "predictAdminCapID",
    network,
    adminCapId,
  );
  constants = updateConstant(
    constants,
    "predictUpgradeCapID",
    network,
    upgradeCapId,
  );
  fs.writeFileSync(CONSTANTS_PATH, constants);

  console.log(`  Package:    ${packageId}`);
  console.log(`  Registry:   ${registryId}`);
  console.log(`  AdminCap:   ${adminCapId}`);
  console.log(`  UpgradeCap: ${upgradeCapId}`);
  console.log(`  Checkpoint: ${publishCheckpoint}`);
  console.log(`  Digest:     ${result.digest}`);

  return { packageId, registryId, adminCapId, upgradeCapId, publishCheckpoint };
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
) {
  console.log("\n[3/8] Initializing predict (create_predict<DUSDC>)...");

  const tx = new Transaction();
  tx.moveCall({
    target: `${packageId}::registry::create_predict`,
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(registryId), tx.object(adminCapId)],
  });

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  if (result.effects?.status.status !== "success") {
    console.error("Init failed:", result.effects?.status);
    process.exit(1);
  }

  await client.waitForTransaction({ digest: result.digest });

  let predictId = "";
  const created =
    result.objectChanges?.filter((c) => c.type === "created") ?? [];
  for (const obj of created) {
    if (obj.type !== "created") continue;
    if (obj.objectType.includes("::predict::Predict")) {
      predictId = obj.objectId;
    }
  }

  let constants = fs.readFileSync(CONSTANTS_PATH, "utf-8");
  constants = updateConstant(constants, "predictObjectID", network, predictId);
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
  console.log("\n[4/8] Creating oracle cap...");

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

  if (result.effects?.status.status !== "success") {
    console.error("CreateOracleCap failed:", result.effects?.status);
    process.exit(1);
  }

  await client.waitForTransaction({ digest: result.digest });

  let oracleCapId = "";
  const created =
    result.objectChanges?.filter((c) => c.type === "created") ?? [];
  for (const obj of created) {
    if (obj.type !== "created") continue;
    if (obj.objectType.includes("::oracle::OracleCapSVI"))
      oracleCapId = obj.objectId;
  }

  let constants = fs.readFileSync(CONSTANTS_PATH, "utf-8");
  constants = updateConstant(
    constants,
    "predictOracleCapID",
    network,
    oracleCapId,
  );
  fs.writeFileSync(CONSTANTS_PATH, constants);

  console.log(`  OracleCapSVI: ${oracleCapId}`);
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
  adminCapId: string,
  oracleCapId: string,
  expiries: string[],
) {
  console.log(`\n[5/8] Deploying ${expiries.length} oracles...`);

  const entries: OracleEntry[] = [];

  for (const expiryIso of expiries) {
    const expiryMs = new Date(expiryIso).getTime();
    console.log(`  Creating oracle for ${expiryIso} (${expiryMs})...`);

    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId}::registry::create_oracle`,
      typeArguments: [UNDERLYING_TYPE],
      arguments: [
        tx.object(registryId),
        tx.object(adminCapId),
        tx.object(oracleCapId),
        tx.pure.u64(expiryMs),
      ],
    });

    const result = await client.signAndExecuteTransaction({
      transaction: tx,
      signer,
      options: { showEffects: true, showObjectChanges: true },
    });

    // Wait for finalization to avoid stale shared objects
    await client.waitForTransaction({ digest: result.digest });

    if (result.effects?.status.status !== "success") {
      console.error(`  FAILED:`, result.effects?.status);
      process.exit(1);
    }

    let oracleId = "";
    const created =
      result.objectChanges?.filter((c) => c.type === "created") ?? [];
    for (const obj of created) {
      if (obj.type !== "created") continue;
      if (obj.objectType.includes("::oracle::OracleSVI")) {
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
      underlying: UNDERLYING_TYPE,
    });
  }

  // Write oracle config
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

  console.log(
    `  Written ${entries.length} oracle entries to config/predict-oracles.ts`,
  );
  return entries;
}

// ---------------------------------------------------------------------------
// Step 6: Deposit DUSDC
// ---------------------------------------------------------------------------

async function depositDUSDC(
  client: ReturnType<typeof getClient>,
  signer: ReturnType<typeof getSigner>,
  packageId: string,
  adminCapId: string,
  predictId: string,
) {
  console.log(
    `\n[6/8] Depositing ${Number(DEPOSIT_AMOUNT) / 1e6} DUSDC into vault...`,
  );

  const tx = new Transaction();

  const coin = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [DUSDC_TYPE],
    arguments: [
      tx.object(dusdcTreasuryCapID[network]),
      tx.pure.u64(DEPOSIT_AMOUNT),
    ],
  });

  tx.moveCall({
    target: `${packageId}::registry::admin_deposit`,
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(predictId), tx.object(adminCapId), coin],
  });

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true },
  });

  if (result.effects?.status.status !== "success") {
    console.error("Deposit failed:", result.effects?.status);
    process.exit(1);
  }

  console.log(
    `  Deposited ${Number(DEPOSIT_AMOUNT) / 1e6} DUSDC. Digest: ${result.digest}`,
  );
}

// ---------------------------------------------------------------------------
// Step 7: Update indexer package ID
// ---------------------------------------------------------------------------

function updateIndexerPackageId(packageId: string) {
  console.log("\n[7/8] Updating indexer package ID...");

  let content = fs.readFileSync(INDEXER_LIB_PATH, "utf-8");
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
  console.log("\n[8/8] Resetting predict database...");

  const pgPort = process.env.PGPORT ?? "5433";
  try {
    execSync(
      `psql -p ${pgPort} postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'predict' AND pid <> pg_backend_pid()" -c "DROP DATABASE IF EXISTS predict" -c "CREATE DATABASE predict"`,
      { stdio: "inherit" },
    );
    console.log("  Database reset complete (predict dropped & recreated)");
  } catch (e) {
    console.error("  Database reset failed:", e);
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

  console.log("=".repeat(60));
  console.log("Predict Redeployment — Full Pipeline");
  console.log("=".repeat(60));
  console.log(`Network:  ${network}`);
  console.log(`Deployer: ${address}`);

  // Step 1
  const expiries = await discoverExpiries();

  // Step 2
  const { packageId, registryId, adminCapId, upgradeCapId, publishCheckpoint } =
    await publishPredict(client, signer, address);

  // Step 3
  const { predictId } = await initPredict(
    client,
    signer,
    packageId,
    registryId,
    adminCapId,
  );

  // Step 4
  const { oracleCapId } = await createOracleCap(
    client,
    signer,
    address,
    packageId,
    adminCapId,
  );

  // Step 5
  const oracles = await deployOracles(
    client,
    signer,
    packageId,
    registryId,
    adminCapId,
    oracleCapId,
    expiries,
  );

  // Step 6
  await depositDUSDC(client, signer, packageId, adminCapId, predictId);

  // Step 7
  updateIndexerPackageId(packageId);

  // Step 8
  resetDatabase();

  // Final summary
  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log(`Package:      ${packageId}`);
  console.log(`Registry:     ${registryId}`);
  console.log(`AdminCap:     ${adminCapId}`);
  console.log(`UpgradeCap:   ${upgradeCapId}`);
  console.log(`Predict:      ${predictId}`);
  console.log(`OracleCap:    ${oracleCapId}`);
  console.log(`Oracles:      ${oracles.length}`);
  for (const o of oracles) {
    console.log(`  ${o.expiry} → ${o.oracleId}`);
  }
  console.log(`DUSDC:        ${Number(DEPOSIT_AMOUNT) / 1e6} deposited`);
  console.log(`Indexer:      package ID updated`);
  console.log(`Database:     reset`);
  console.log(`Checkpoint:   ${publishCheckpoint}`);
  console.log("=".repeat(60));
  console.log("\nStart the indexer with:");
  console.log(
    `  cargo run -p predict-indexer -- --database-url postgres://localhost:5433/predict --first-checkpoint ${publishCheckpoint}`,
  );
})();
