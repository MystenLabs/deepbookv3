/**
 * One-time initialization script: deploys the DUSDC package, mints initial
 * supply, and funds oracle/minter wallets with SUI for gas.
 *
 * Usage: npm run init   (or: npx tsx src/init.ts)
 */

import { execSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { Transaction } from "@mysten/sui/transactions";
import {
  DUSDC_PACKAGE_ID,
  TREASURY_CAP_ID,
  PROJECT_ROOT,
  ENV_PATH_EXPORT as ENV_PATH,
} from "./config.js";
import {
  getDeployerKeypair,
  getDeployerAddress,
  getOracleAddress,
  getMinterAddress,
  executeTransaction,
  findPublishedPackage,
  findCreatedObjects,
} from "./sui-helpers.js";
import { Logger } from "./logger.js";

const log = new Logger("init");

const REPO_ROOT = path.resolve(PROJECT_ROOT, "..");
const DUSDC_PATH = path.join(REPO_ROOT, "packages", "dusdc");

// 10 billion DUSDC with 6 decimals = 10_000_000_000 * 1e6 base units
const MINT_AMOUNT = 10_000_000_000_000_000n;

// 2000 SUI in MIST for each funded wallet
const GAS_FUND_AMOUNT = 2_000_000_000_000n;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function updateEnvFile(updates: Record<string, string>): void {
  let content = "";
  try {
    content = readFileSync(ENV_PATH, "utf8");
  } catch {
    // .env may not exist yet
  }

  for (const [key, value] of Object.entries(updates)) {
    const regex = new RegExp(`^${key}=.*$`, "m");
    if (regex.test(content)) {
      content = content.replace(regex, `${key}=${value}`);
    } else {
      content = content.trimEnd() + `\n${key}=${value}\n`;
    }
  }

  writeFileSync(ENV_PATH, content);
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

async function publishDusdc(): Promise<{ packageId: string; treasuryCapId: string }> {
  log.info("Building DUSDC package...", { path: DUSDC_PATH });

  const buildOutput = execSync(
    `sui move build --path ${DUSDC_PATH} --dump-bytecode-as-base64`,
    { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] },
  );

  const { modules, dependencies } = JSON.parse(buildOutput);
  log.info("Build succeeded", {
    moduleCount: modules.length,
    dependencyCount: dependencies.length,
  });

  log.info("Publishing DUSDC package...");
  const deployerAddress = getDeployerAddress();
  const tx = new Transaction();
  const [upgradeCap] = tx.publish({ modules, dependencies });
  tx.transferObjects([upgradeCap], tx.pure.address(deployerAddress));

  const result = await executeTransaction(tx, getDeployerKeypair());

  const packageId = findPublishedPackage(result);
  if (!packageId) {
    throw new Error("Failed to find published package ID in transaction result");
  }

  const treasuryCaps = findCreatedObjects(result, "TreasuryCap");
  if (treasuryCaps.length === 0) {
    throw new Error("Failed to find TreasuryCap in transaction result");
  }
  const treasuryCapId = treasuryCaps[0].objectId;

  log.info("DUSDC published", { packageId, treasuryCapId });
  return { packageId, treasuryCapId };
}

async function mintDusdc(packageId: string, treasuryCapId: string): Promise<void> {
  log.info("Minting 10B DUSDC to deployer...", {
    amount: MINT_AMOUNT.toString(),
  });

  const deployerAddress = getDeployerAddress();
  const tx = new Transaction();
  const dusdcType = `${packageId}::dusdc::DUSDC`;

  const [coin] = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [dusdcType],
    arguments: [tx.object(treasuryCapId), tx.pure.u64(MINT_AMOUNT)],
  });
  tx.transferObjects([coin], tx.pure.address(deployerAddress));

  await executeTransaction(tx, getDeployerKeypair());
  log.info("Minted 10B DUSDC to deployer");
}

async function fundWallets(): Promise<void> {
  const oracleAddress = getOracleAddress();
  const minterAddress = getMinterAddress();

  log.info("Funding oracle and minter wallets with SUI...", {
    oracleAddress,
    minterAddress,
    amountPerWallet: GAS_FUND_AMOUNT.toString(),
  });

  const tx = new Transaction();
  const [oracleCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(GAS_FUND_AMOUNT)]);
  const [minterCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(GAS_FUND_AMOUNT)]);
  tx.transferObjects([oracleCoin], tx.pure.address(oracleAddress));
  tx.transferObjects([minterCoin], tx.pure.address(minterAddress));

  await executeTransaction(tx, getDeployerKeypair());
  log.info("Funded oracle and minter wallets");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  log.info("=== predict_fuzz init ===");
  log.info("Deployer address", { address: getDeployerAddress() });

  let packageId = DUSDC_PACKAGE_ID;
  let treasuryCapId = TREASURY_CAP_ID;

  // Step 1: Deploy DUSDC if not already deployed
  if (packageId && treasuryCapId) {
    log.info("DUSDC already deployed, skipping publish", {
      packageId,
      treasuryCapId,
    });
  } else {
    const deployed = await publishDusdc();
    packageId = deployed.packageId;
    treasuryCapId = deployed.treasuryCapId;

    // Step 2: Update .env
    log.info("Updating .env with DUSDC config...");
    updateEnvFile({
      DUSDC_PACKAGE_ID: packageId,
      TREASURY_CAP_ID: treasuryCapId,
    });
    log.info(".env updated");
  }

  // Step 3: Mint initial DUSDC supply
  await mintDusdc(packageId, treasuryCapId);

  // Step 4: Fund oracle and minter wallets
  await fundWallets();

  log.info("=== init complete ===");
}

main().catch((err) => {
  log.error("Init failed", { error: String(err) });
  process.exit(1);
});
