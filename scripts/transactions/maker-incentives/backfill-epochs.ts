#!/usr/bin/env tsx
/**
 * Backfill missed epoch submissions over a date range.
 *
 * For each 24h epoch in [start-date, end-date), calls submit-epoch.ts.
 * Skips epochs that were already submitted on-chain (checks via
 * is_epoch_submitted view function).
 *
 * Usage:
 *   npx tsx transactions/maker-incentives/backfill-epochs.ts \
 *     --network testnet --fund-id 0xabc... --enclave-url http://...:3000
 *
 *   npx tsx transactions/maker-incentives/backfill-epochs.ts \
 *     --network testnet --fund-id 0xabc... \
 *     --start-date 2026-03-20 --end-date 2026-03-26
 *
 * Defaults:
 *   --start-date   7 days ago (UTC midnight)
 *   --end-date     today (UTC midnight)  — i.e. yesterday's epoch is the last one submitted
 */

import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "./sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DAY_MS = 86_400_000;

function utcMidnight(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
}

function defaultStartDate(): string {
  const d = new Date(Date.now() - 7 * DAY_MS);
  return d.toISOString().split("T")[0];
}

function defaultEndDate(): string {
  return new Date().toISOString().split("T")[0];
}

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    "fund-id": { type: "string", short: "f" },
    "enclave-url": { type: "string", default: "http://localhost:3000" },
    test: { type: "boolean", default: false },
    "start-date": { type: "string", default: defaultStartDate() },
    "end-date": { type: "string", default: defaultEndDate() },
    "dry-run": { type: "boolean", default: false },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, `deployed.${NETWORK}.json`);

function log(msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${msg}`);
}

async function checkEpochSubmitted(
  client: any,
  packageId: string,
  fundId: string,
  epochStartMs: number,
): Promise<boolean> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${packageId}::maker_incentives::is_epoch_submitted`,
    arguments: [tx.object(fundId), tx.pure.u64(epochStartMs)],
  });

  try {
    const result = await client.devInspectTransactionBlock({
      transactionBlock: tx,
      sender: "0x0000000000000000000000000000000000000000000000000000000000000000",
    });
    const returnValues = result.results?.[0]?.returnValues;
    if (returnValues && returnValues.length > 0) {
      const bytes = returnValues[0][0];
      return bytes[0] === 1;
    }
  } catch {
    // If devInspect fails, assume not submitted (safe to attempt)
  }
  return false;
}

async function submitEpoch(
  epochStartMs: number,
  epochEndMs: number,
): Promise<boolean> {
  const { execSync } = await import("child_process");
  const scriptPath = path.resolve(__dirname, "submit-epoch.ts");

  const cmdArgs = [
    `--network ${NETWORK}`,
    `--fund-id ${args["fund-id"]}`,
    `--enclave-url ${args["enclave-url"]}`,
    `--epoch-start ${epochStartMs}`,
    `--epoch-end ${epochEndMs}`,
    args.test ? "--test" : "",
  ]
    .filter(Boolean)
    .join(" ");

  try {
    execSync(`npx tsx ${scriptPath} ${cmdArgs}`, {
      stdio: "inherit",
      timeout: 120_000,
    });
    return true;
  } catch (err: any) {
    log(`  ERROR: submit-epoch failed for ${new Date(epochStartMs).toISOString().split("T")[0]}`);
    return false;
  }
}

async function main() {
  const fundId = args["fund-id"];
  if (!fundId) {
    console.error("Error: --fund-id is required.");
    process.exit(1);
  }

  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const client = getClient(NETWORK);
  const fundConfig = config.funds?.[fundId];
  if (!fundConfig) {
    console.error(`No fund config found for ${fundId}. Run create-fund first.`);
    process.exit(1);
  }

  const startMs = utcMidnight(new Date(args["start-date"]!)).getTime();
  const endMs = utcMidnight(new Date(args["end-date"]!)).getTime();

  if (endMs <= startMs) {
    console.error("Error: --end-date must be after --start-date.");
    process.exit(1);
  }

  const epochs: Array<{ start: number; end: number }> = [];
  for (let t = startMs; t + DAY_MS <= endMs; t += DAY_MS) {
    epochs.push({ start: t, end: t + DAY_MS });
  }

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — BACKFILL EPOCHS");
  console.log("=".repeat(60));
  console.log(`  Network:        ${NETWORK}`);
  console.log(`  Fund:           ${fundId}`);
  console.log(`  Pool:           ${fundConfig.poolId}`);
  console.log(`  Range:          ${args["start-date"]} → ${args["end-date"]}`);
  console.log(`  Epochs to check: ${epochs.length}`);
  console.log(`  Dry run:        ${args["dry-run"]}`);
  console.log();

  let submitted = 0;
  let skipped = 0;
  let failed = 0;

  for (const epoch of epochs) {
    const dateStr = new Date(epoch.start).toISOString().split("T")[0];

    const alreadySubmitted = await checkEpochSubmitted(
      client,
      config.packageId,
      fundId,
      epoch.start,
    );

    if (alreadySubmitted) {
      log(`SKIP  ${dateStr} — already submitted on-chain`);
      skipped++;
      continue;
    }

    if (args["dry-run"]) {
      log(`WOULD ${dateStr} — not yet submitted (dry-run)`);
      submitted++;
      continue;
    }

    log(`SUBMIT ${dateStr}...`);
    const ok = await submitEpoch(epoch.start, epoch.end);
    if (ok) {
      submitted++;
    } else {
      failed++;
    }

    // Brief pause between submissions to avoid rate limits
    await new Promise((r) => setTimeout(r, 2000));
  }

  console.log("\n" + "=".repeat(60));
  console.log("  BACKFILL COMPLETE");
  console.log("=".repeat(60));
  console.log(`  Submitted: ${submitted}`);
  console.log(`  Skipped:   ${skipped} (already on-chain)`);
  console.log(`  Failed:    ${failed}`);
  console.log();

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
