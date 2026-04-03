#!/usr/bin/env tsx
/**
 * Deploy the maker_incentives Move package.
 *
 * Usage:
 *   pnpm incentives:deploy --network testnet
 *   pnpm incentives:deploy --network mainnet
 *
 * Outputs:
 *   scripts/transactions/maker-incentives/deployed.<network>.json
 */

import { execSync } from "child_process";
import { writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, getActiveAddress } from "./sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const MOVE_DIR = path.resolve(__dirname, "../../../packages/maker_incentives");
const CONFIG_FILE = path.resolve(__dirname, `deployed.${NETWORK}.json`);

function log(step: string, msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${step.padEnd(12)} | ${msg}`);
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — DEPLOY");
  console.log("=".repeat(60));

  const address = getActiveAddress();
  const client = getClient(NETWORK);
  const signer = getSigner();

  console.log(`  Network:  ${NETWORK}`);
  console.log(`  Move Dir: ${MOVE_DIR}`);
  console.log(`  Address:  ${address}\n`);

  log("BUILD", "Cleaning & building Move package...");
  try {
    execSync("rm -rf build", { cwd: MOVE_DIR, stdio: "pipe" });
  } catch {}

  try {
    execSync("sui move build --with-unpublished-dependencies", {
      cwd: MOVE_DIR,
      stdio: "pipe",
    });
    log("BUILD", "OK");
  } catch (err: any) {
    console.error("Build failed:", err.stdout?.toString() || err.message);
    process.exit(1);
  }

  log("PUBLISH", "Publishing to chain...");
  const buildOutput = execSync(
    "sui move build --dump-bytecode-as-base64 --with-unpublished-dependencies",
    { cwd: MOVE_DIR, encoding: "utf8" }
  );
  const { modules, dependencies } = JSON.parse(buildOutput);

  const tx = new Transaction();
  const [upgradeCap] = tx.publish({ modules, dependencies });
  tx.transferObjects([upgradeCap], address);
  tx.setGasBudget(500_000_000);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Publish failed:", result.effects?.status?.error);
    process.exit(1);
  }

  log("PUBLISH", `Tx: ${result.digest}`);
  await client.waitForTransaction({ digest: result.digest });
  await sleep(3000);

  const changes = result.objectChanges ?? [];

  const packageId =
    (changes.find((c: any) => c.type === "published") as any)?.packageId ?? "";
  const enclaveCapId =
    (
      changes.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("enclave::Cap")
      ) as any
    )?.objectId ?? "";
  const enclaveConfigId =
    (
      changes.find(
        (c: any) =>
          c.type === "created" && (c as any).objectType?.includes("EnclaveConfig<")
      ) as any
    )?.objectId ?? "";
  const upgradeCapId =
    (
      changes.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("UpgradeCap")
      ) as any
    )?.objectId ?? "";

  log("PUBLISH", `Package:       ${packageId}`);
  log("PUBLISH", `EnclaveCap:    ${enclaveCapId}`);
  log("PUBLISH", `EnclaveConfig: ${enclaveConfigId}`);

  const config = {
    network: NETWORK,
    packageId,
    enclaveCapId,
    enclaveConfigId,
    upgradeCapId,
    deployTx: result.digest,
    deployedAt: new Date().toISOString(),
    deployedBy: address,
    funds: {} as Record<string, { poolId: string; ownerCapId: string }>,
  };

  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  log("CONFIG", `Saved to ${path.basename(CONFIG_FILE)}`);

  console.log("\n" + "=".repeat(60));
  console.log("  DEPLOY COMPLETE");
  console.log("=".repeat(60));
  console.log(`\n  Next: create a fund with`);
  console.log(
    `    pnpm incentives:create-fund --network ${NETWORK} --pool-id 0x...\n`
  );
}

main().catch((err) => {
  console.error("\nDeploy failed:", err.message);
  process.exit(1);
});
