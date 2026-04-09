#!/usr/bin/env tsx
/**
 * Create an IncentiveFund for a DeepBook pool and optionally fund it with DEEP.
 * Permissionless — anyone can create a fund.
 *
 * Usage:
 *   pnpm incentives:create-fund --network testnet --pool-id 0xabc...
 *   pnpm incentives:create-fund --network testnet --pool-id 0xabc... \
 *     --alpha-bps 7500 --reward 5000 --fund 50000
 *
 * Options:
 *   --network, -n       testnet | mainnet                     (default: testnet)
 *   --pool-id, -p       DeepBook pool address                 (required)
 *   --alpha-bps         spread exponent × 10000               (default: 5000 = 0.5)
 *   --reward            DEEP per epoch (human units)          (default: 1000)
 *   --quality-p         quality compression root (>= 1)       (default: 3)
 *   (Epoch length is fixed at 24h and windows at 1h on-chain.)
 *   --fund              initial DEEP deposit (human units)    (default: 0)
 *
 * Requires:
 *   deployed.<network>.json from deploy.ts
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, getActiveAddress } from "../lib/sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEEP_COIN_TYPES: Record<string, string> = {
  testnet:
    "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP",
  mainnet:
    "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
};

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    "pool-id": { type: "string", short: "p" },
    "alpha-bps": { type: "string", default: "5000" },
    reward: { type: "string", default: "1000" },
    "quality-p": { type: "string", default: "3" },
    fund: { type: "string", default: "0" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, '..', `deployed.${NETWORK}.json`);

const DEEP_DECIMALS = 6;
const DEEP_SCALAR = 10 ** DEEP_DECIMALS;

function log(step: string, msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${step.padEnd(12)} | ${msg}`);
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const poolId = args["pool-id"];
  if (!poolId) {
    console.error("Error: --pool-id is required.");
    console.error(
      "  pnpm incentives:create-fund --network testnet --pool-id 0x..."
    );
    process.exit(1);
  }

  const alphaBps = Number(args["alpha-bps"]);
  const rewardPerEpochHuman = Number(args.reward);
  const rewardPerEpoch = BigInt(rewardPerEpochHuman) * BigInt(DEEP_SCALAR);
  const qualityP = BigInt(args["quality-p"]!);
  const fundAmountHuman = Number(args.fund);

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — CREATE FUND");
  console.log("=".repeat(60));

  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const address = getActiveAddress();
  const client = getClient(NETWORK);
  const signer = getSigner();

  console.log(`  Network:          ${NETWORK}`);
  console.log(`  Package:          ${config.packageId}`);
  console.log(`  Pool ID:          ${poolId}`);
  console.log(`  Alpha (bps):      ${alphaBps} (= ${alphaBps / 10_000})`);
  console.log(`  Reward/epoch:     ${rewardPerEpochHuman} DEEP`);
  console.log(`  Epoch / window:   24h / 1h (fixed on-chain)`);
  console.log(`  Quality p:        ${qualityP}`);
  if (fundAmountHuman > 0) {
    console.log(`  Initial funding:  ${fundAmountHuman} DEEP`);
  }
  console.log();

  const tx = new Transaction();

  const [ownerCap] = tx.moveCall({
    target: `${config.packageId}::maker_incentives::create_fund`,
    arguments: [
      tx.pure.address(poolId),
      tx.pure.u64(rewardPerEpoch.toString()),
      tx.pure.u64(alphaBps),
      tx.pure.u64(qualityP.toString()),
      tx.object("0x6"),
    ],
  });

  tx.transferObjects([ownerCap], address);
  tx.setGasBudget(50_000_000);

  log("CREATE", "Creating IncentiveFund...");

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Transaction failed:", result.effects?.status?.error);
    process.exit(1);
  }

  log("CREATE", `Tx: ${result.digest}`);
  await client.waitForTransaction({ digest: result.digest });
  await sleep(2000);

  const changes = result.objectChanges ?? [];

  const fundObjId =
    (
      changes.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("IncentiveFund")
      ) as any
    )?.objectId ?? "";

  const ownerCapId =
    (
      changes.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("FundOwnerCap")
      ) as any
    )?.objectId ?? "";

  log("CREATE", `IncentiveFund: ${fundObjId}`);
  log("CREATE", `FundOwnerCap:  ${ownerCapId}`);

  if (fundAmountHuman > 0) {
    log("FUND", `Depositing ${fundAmountHuman} DEEP...`);

    const coins = await client.getCoins({
      owner: address,
      coinType: DEEP_COIN_TYPES[NETWORK],
    });

    if (!coins.data.length) {
      log("FUND", "No DEEP coins found in wallet. Skipping funding.");
    } else {
      const fundTx = new Transaction();
      const fundAmount = BigInt(fundAmountHuman) * BigInt(DEEP_SCALAR);

      const primaryCoin = fundTx.object(coins.data[0].coinObjectId);
      if (coins.data.length > 1) {
        fundTx.mergeCoins(
          primaryCoin,
          coins.data.slice(1).map((c) => fundTx.object(c.coinObjectId))
        );
      }

      const [payment] = fundTx.splitCoins(primaryCoin, [
        fundTx.pure.u64(fundAmount.toString()),
      ]);

      fundTx.moveCall({
        target: `${config.packageId}::maker_incentives::fund`,
        arguments: [fundTx.object(fundObjId), payment],
      });

      fundTx.setGasBudget(50_000_000);

      const fundResult = await client.signAndExecuteTransaction({
        transaction: fundTx,
        signer,
        options: { showEffects: true },
      });

      if (fundResult.effects?.status?.status !== "success") {
        console.error("Funding failed:", fundResult.effects?.status?.error);
      } else {
        log("FUND", `Funded. Tx: ${fundResult.digest}`);
      }
    }
  }

  config.funds = config.funds ?? {};
  config.funds[fundObjId] = {
    poolId,
    ownerCapId,
  };
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  log("CONFIG", "Updated deployed config.");

  console.log("\n" + "=".repeat(60));
  console.log("  FUND CREATED");
  console.log("=".repeat(60));
  console.log(`  IncentiveFund: ${fundObjId}`);
  console.log(`  FundOwnerCap:  ${ownerCapId}`);
  console.log(`  DeepBook Pool: ${poolId}`);
  if (fundAmountHuman > 0) {
    console.log(`  Funded:        ${fundAmountHuman} DEEP`);
  }
  console.log();
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
