#!/usr/bin/env tsx
/**
 * Create an IncentivePool for a DeepBook pool and optionally fund it.
 *
 * Usage:
 *   pnpm incentives:add-pool --network testnet --pool-id 0xabc...
 *   pnpm incentives:add-pool --network mainnet --pool-id 0xabc... --fund 10000
 *   pnpm incentives:add-pool --network testnet --pool-id 0xabc... --alpha-bps 7500 --reward 5000
 *
 * Options:
 *   --network, -n       testnet | mainnet                     (default: testnet)
 *   --pool-id, -p       DeepBook pool address                 (required)
 *   --alpha-bps         spread exponent × 10000               (default: 5000 = 0.5)
 *   --reward            DEEP tokens per epoch (human units)   (default: 1000)
 *   --epoch-duration    epoch length in ms                    (default: 86400000 = 24h)
 *   --window-duration   window length in ms                   (default: 3600000 = 1h)
 *   --fund              initial DEEP to deposit (human units) (default: 0)
 *
 * Requires:
 *   deployed.<network>.json from deploy.ts
 */

import { readFileSync, writeFileSync } from "fs";
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
    "pool-id": { type: "string", short: "p" },
    "alpha-bps": { type: "string", default: "5000" },
    reward: { type: "string", default: "1000" },
    "epoch-duration": { type: "string", default: "86400000" },
    "window-duration": { type: "string", default: "3600000" },
    fund: { type: "string", default: "0" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, `deployed.${NETWORK}.json`);

const DEEP_DECIMALS = 6;
const DEEP_SCALAR = 10 ** DEEP_DECIMALS;

const DEEP_COIN_TYPE =
  "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP";

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
      "  pnpm incentives:add-pool --network testnet --pool-id 0x..."
    );
    process.exit(1);
  }

  const alphaBps = Number(args["alpha-bps"]);
  const rewardPerEpochHuman = Number(args.reward);
  const rewardPerEpoch = BigInt(rewardPerEpochHuman) * BigInt(DEEP_SCALAR);
  const epochDurationMs = Number(args["epoch-duration"]);
  const windowDurationMs = Number(args["window-duration"]);
  const fundAmountHuman = Number(args.fund);

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — ADD POOL");
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
  console.log(`  Epoch duration:   ${epochDurationMs / 3_600_000}h`);
  console.log(`  Window duration:  ${windowDurationMs / 60_000}min`);
  if (fundAmountHuman > 0) {
    console.log(`  Initial funding:  ${fundAmountHuman} DEEP`);
  }
  console.log();

  const tx = new Transaction();

  tx.moveCall({
    target: `${config.packageId}::maker_incentives::create_incentive_pool`,
    arguments: [
      tx.object(config.adminCapId),
      tx.pure.address(poolId),
      tx.pure.u64(rewardPerEpoch.toString()),
      tx.pure.u64(alphaBps),
      tx.pure.u64(epochDurationMs),
      tx.pure.u64(windowDurationMs),
    ],
  });

  tx.setGasBudget(50_000_000);

  log("CREATE", "Creating IncentivePool...");

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

  const incentivePoolId =
    (
      result.objectChanges?.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("IncentivePool")
      ) as any
    )?.objectId ?? "";

  log("CREATE", `IncentivePool: ${incentivePoolId}`);

  if (fundAmountHuman > 0) {
    log("FUND", `Depositing ${fundAmountHuman} DEEP...`);

    const deepCoins = await client.getCoins({
      owner: address,
      coinType: DEEP_COIN_TYPE,
    });

    if (!deepCoins.data.length) {
      log("FUND", "No DEEP coins found in wallet. Skipping funding.");
    } else {
      const fundTx = new Transaction();
      const fundAmount = BigInt(fundAmountHuman) * BigInt(DEEP_SCALAR);

      const primaryCoin = fundTx.object(deepCoins.data[0].coinObjectId);
      if (deepCoins.data.length > 1) {
        fundTx.mergeCoins(
          primaryCoin,
          deepCoins.data.slice(1).map((c) => fundTx.object(c.coinObjectId))
        );
      }

      const [payment] = fundTx.splitCoins(primaryCoin, [
        fundTx.pure.u64(fundAmount.toString()),
      ]);

      fundTx.moveCall({
        target: `${config.packageId}::maker_incentives::fund_pool`,
        arguments: [fundTx.object(incentivePoolId), payment],
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

  config.incentivePools = config.incentivePools ?? {};
  config.incentivePools[poolId] = incentivePoolId;
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  log("CONFIG", "Updated deployed config.");

  console.log("\n" + "=".repeat(60));
  console.log("  POOL ADDED");
  console.log("=".repeat(60));
  console.log(`  IncentivePool: ${incentivePoolId}`);
  console.log(`  DeepBook Pool: ${poolId}`);
  if (fundAmountHuman > 0) {
    console.log(`  Funded:        ${fundAmountHuman} DEEP`);
  } else {
    console.log(
      `  Fund it later: pnpm incentives:add-pool --network ${NETWORK} --pool-id ${poolId} --fund 10000`
    );
  }
  console.log();
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
