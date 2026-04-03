#!/usr/bin/env tsx
/**
 * Trigger scoring for a completed epoch and submit results on-chain.
 *
 * Flow:
 *   1. POST to the incentives enclave to compute scores and get a signed attestation
 *   2. Build a Sui transaction that calls submit_epoch_results with the signed payload
 *   3. Execute and confirm
 *
 * Usage:
 *   pnpm incentives:submit-epoch --network testnet --fund-id 0xabc...
 *   pnpm incentives:submit-epoch --network mainnet --fund-id 0xabc... --enclave-url http://enclave:3000
 *   pnpm incentives:submit-epoch --network testnet --fund-id 0xabc... --epoch-start 1711929600000 --epoch-end 1712016000000
 *
 * Options:
 *   --network, -n       testnet | mainnet                          (default: testnet)
 *   --fund-id, -f       IncentiveFund object address                (required)
 *   --enclave-url       URL of the incentives server                (default: http://localhost:3000)
 *   --test              Use /test_process_data endpoint (dummy)     (default: false)
 *   --alpha             spread exponent as float                    (default: 0.5)
 *   --window-duration   scoring window size in ms                   (default: 3600000 = 1h)
 *   --epoch-start       explicit start timestamp in ms              (default: yesterday midnight UTC)
 *   --epoch-end         explicit end timestamp in ms                (default: today midnight UTC)
 *
 * Requires:
 *   deployed.<network>.json from deploy.ts (with funds mapping)
 */

import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, getActiveAddress } from "./sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** Default epoch boundaries: previous UTC midnight -> current UTC midnight. */
function defaultEpochBounds(): { start: number; end: number } {
  const now = new Date();
  const todayMidnight = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  );
  const yesterdayMidnight = new Date(todayMidnight.getTime() - 86_400_000);
  return {
    start: yesterdayMidnight.getTime(),
    end: todayMidnight.getTime(),
  };
}

const defaults = defaultEpochBounds();

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    "fund-id": { type: "string", short: "f" },
    "enclave-url": { type: "string", default: "http://localhost:3000" },
    test: { type: "boolean", default: false },
    alpha: { type: "string", default: "0.5" },
    "window-duration": { type: "string", default: "3600000" },
    "epoch-start": { type: "string", default: String(defaults.start) },
    "epoch-end": { type: "string", default: String(defaults.end) },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, `deployed.${NETWORK}.json`);
const ENCLAVE_URL = args["enclave-url"]!;

function log(step: string, msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${step.padEnd(12)} | ${msg}`);
}

async function main() {
  const fundId = args["fund-id"];
  if (!fundId) {
    console.error("Error: --fund-id is required.");
    console.error(
      "  pnpm incentives:submit-epoch --network testnet --fund-id 0x..."
    );
    process.exit(1);
  }

  const epochStartMs = Number(args["epoch-start"]);
  const epochEndMs = Number(args["epoch-end"]);
  const alpha = Number(args.alpha);
  const windowDurationMs = Number(args["window-duration"]);

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — SUBMIT EPOCH");
  console.log("=".repeat(60));

  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const client = getClient(NETWORK);
  const signer = getSigner();

  const fundConfig = config.funds?.[fundId];
  if (!fundConfig) {
    console.error(
      `No fund config found for ${fundId}. Run create-fund first.`
    );
    process.exit(1);
  }

  const poolId = fundConfig.poolId;

  console.log(`  Network:        ${NETWORK}`);
  console.log(`  Enclave:        ${ENCLAVE_URL}`);
  console.log(`  Fund:           ${fundId}`);
  console.log(`  Pool:           ${poolId}`);
  console.log(
    `  Epoch:          ${new Date(epochStartMs).toISOString()} -> ${new Date(epochEndMs).toISOString()}`
  );
  console.log(`  Alpha:          ${alpha}`);
  console.log(`  Window:         ${windowDurationMs / 60_000}min`);
  console.log();

  // Step 1: Call enclave to compute scores.
  log("ENCLAVE", "Requesting scores from enclave...");

  const enclavePayload = {
    payload: {
      pool_id: poolId,
      fund_id: fundId,
      epoch_start_ms: epochStartMs,
      epoch_end_ms: epochEndMs,
      alpha,
      window_duration_ms: windowDurationMs,
    },
  };

  const enclaveEndpoint = args.test ? "test_process_data" : "process_data";
  const enclaveRes = await fetch(`${ENCLAVE_URL}/${enclaveEndpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(enclavePayload),
  });

  if (!enclaveRes.ok) {
    const body = await enclaveRes.text();
    console.error(`Enclave error (${enclaveRes.status}): ${body}`);
    process.exit(1);
  }

  const enclaveData = (await enclaveRes.json()) as {
    response: {
      intent: number;
      timestamp_ms: number;
      data?: {
        pool_id: number[];
        fund_id: number[];
        epoch_start_ms: number;
        epoch_end_ms: number;
        total_score: number;
        maker_rewards: Array<{
          balance_manager_id: number[];
          score: number;
        }>;
      };
      payload?: {
        pool_id: number[];
        fund_id: number[];
        epoch_start_ms: number;
        epoch_end_ms: number;
        total_score: number;
        maker_rewards: Array<{
          balance_manager_id: number[];
          score: number;
        }>;
      };
    };
    signature: string;
  };

  const payload = enclaveData.response.data ?? enclaveData.response.payload!;
  log(
    "ENCLAVE",
    `Got ${payload.maker_rewards.length} maker scores, total_score=${payload.total_score}`
  );

  if (payload.maker_rewards.length === 0) {
    log("ENCLAVE", "No makers scored this epoch. Nothing to submit.");
    return;
  }

  // Step 2: Build the on-chain transaction.
  log("SUBMIT", "Building transaction...");

  const tx = new Transaction();

  const makerEntries = payload.maker_rewards.map((entry) => {
    const addrHex =
      "0x" +
      Array.from(entry.balance_manager_id)
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    return tx.moveCall({
      target: `${config.packageId}::maker_incentives::new_maker_reward_entry`,
      arguments: [tx.pure.address(addrHex), tx.pure.u64(entry.score)],
    });
  });

  const rewardsVec = tx.makeMoveVec({
    type: `${config.packageId}::maker_incentives::MakerRewardEntry`,
    elements: makerEntries,
  });

  const sigHex = enclaveData.signature;
  const sigBytes = new Uint8Array(
    sigHex.match(/.{1,2}/g)!.map((byte) => parseInt(byte, 16))
  );

  tx.moveCall({
    target: `${config.packageId}::maker_incentives::submit_epoch_results`,
    arguments: [
      tx.object(fundId),
      tx.object(config.enclaveObjectId),
      tx.pure.u64(payload.epoch_start_ms),
      tx.pure.u64(payload.epoch_end_ms),
      tx.pure.u64(payload.total_score),
      rewardsVec,
      tx.pure.u64(enclaveData.response.timestamp_ms),
      tx.pure("vector<u8>", Array.from(sigBytes)),
    ],
  });

  tx.setGasBudget(100_000_000);

  // Step 3: Execute.
  log("SUBMIT", "Executing transaction...");

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true, showEvents: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Transaction failed:", result.effects?.status?.error);
    process.exit(1);
  }

  log("SUBMIT", `Tx: ${result.digest}`);
  await client.waitForTransaction({ digest: result.digest });

  const epochRecordId =
    (
      result.objectChanges?.find(
        (c: any) =>
          c.type === "created" &&
          (c as any).objectType?.includes("EpochRecord")
      ) as any
    )?.objectId ?? "";

  log("SUBMIT", `EpochRecord: ${epochRecordId}`);

  if (result.events?.length) {
    log("EVENTS", "Emitted events:");
    for (const ev of result.events) {
      console.log(`           ${ev.type}`);
      console.log(`           ${JSON.stringify(ev.parsedJson, null, 2)}`);
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("  EPOCH SUBMITTED");
  console.log("=".repeat(60));
  console.log(`  EpochRecord:  ${epochRecordId}`);
  console.log(`  Makers:       ${payload.maker_rewards.length}`);
  console.log(`  Total Score:  ${payload.total_score}`);
  console.log(
    `\n  Makers can now call claim_reward with their BalanceManager.\n`
  );
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
