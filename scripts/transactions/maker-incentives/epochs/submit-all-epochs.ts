#!/usr/bin/env tsx
/**
 * Submit epoch results for ALL active funds, automatically backfilling
 * any missed epochs within the lookback window.
 *
 * For each fund discovered from the indexer, checks the last N days
 * (default 7) on-chain via is_epoch_submitted and submits any missing
 * epochs. This makes the script fully idempotent — safe to run as a
 * daily cron AND as a one-off to recover missed days.
 *
 * Usage:
 *   npx tsx transactions/maker-incentives/epochs/submit-all-epochs.ts \
 *     --network testnet --indexer-url http://localhost:3000
 *
 *   npx tsx transactions/maker-incentives/epochs/submit-all-epochs.ts \
 *     --network testnet --indexer-url http://localhost:3000 --lookback-days 14
 *
 * Options:
 *   --network, -n       testnet | mainnet                        (default: testnet)
 *   --indexer-url       URL of the deepbook indexer/server API    (required)
 *   --enclave-url       URL of the incentives server              (default: http://localhost:3000)
 *   --test              Use /test_process_data endpoint (dummy)   (default: false)
 *   --lookback-days     How many days back to check for gaps      (default: 7)
 *   --dry-run           just print what would be submitted        (default: false)
 */

import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { execSync } from "child_process";
import { Transaction } from "@mysten/sui/transactions";
import { getClient } from "../lib/sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DAY_MS = 86_400_000;

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    "indexer-url": { type: "string" },
    "enclave-url": { type: "string", default: "http://localhost:3000" },
    test: { type: "boolean", default: false },
    "lookback-days": { type: "string", default: "7" },
    "dry-run": { type: "boolean", default: false },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, "..", `deployed.${NETWORK}.json`);
const INDEXER_URL = args["indexer-url"];
const LOOKBACK_DAYS = Number(args["lookback-days"]);
const SUBMIT_SCRIPT = path.resolve(__dirname, "submit-epoch.ts");

function log(msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${msg}`);
}

function utcMidnight(d: Date): Date {
  return new Date(
    Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()),
  );
}

function buildEpochRange(): Array<{ start: number; end: number }> {
  const endMs = utcMidnight(new Date()).getTime();
  const startMs = endMs - LOOKBACK_DAYS * DAY_MS;
  const epochs: Array<{ start: number; end: number }> = [];
  for (let t = startMs; t + DAY_MS <= endMs; t += DAY_MS) {
    epochs.push({ start: t, end: t + DAY_MS });
  }
  return epochs;
}

interface FundCreatedEvent {
  fund_id: string;
  pool_id: string;
  reward_per_epoch: number;
  creator: string;
  checkpoint_timestamp_ms: number;
  [key: string]: unknown;
}

async function fetchFunds(
  indexerUrl: string,
): Promise<Map<string, { poolId: string }>> {
  const url = new URL("/maker_incentive_fund_created", indexerUrl);
  url.searchParams.set("start_time", "0");
  url.searchParams.set("end_time", String(Date.now() + DAY_MS));
  url.searchParams.set("limit", "1000");

  log(`Fetching funds from ${url.toString()}`);
  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Indexer returned ${res.status}: ${await res.text()}`);
  }

  const events: FundCreatedEvent[] = await res.json();
  log(`Got ${events.length} FundCreated events from indexer`);

  const funds = new Map<string, { poolId: string }>();
  for (const ev of events) {
    funds.set(ev.fund_id, { poolId: ev.pool_id });
  }
  return funds;
}

async function checkEpochSubmitted(
  client: ReturnType<typeof getClient>,
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
      sender:
        "0x0000000000000000000000000000000000000000000000000000000000000000",
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

function submitEpoch(
  fundId: string,
  epochStartMs: number,
  epochEndMs: number,
): boolean {
  const cmdArgs = [
    `--network ${NETWORK}`,
    `--fund-id ${fundId}`,
    `--enclave-url ${args["enclave-url"]}`,
    `--server-url ${INDEXER_URL}`,
    `--epoch-start ${epochStartMs}`,
    `--epoch-end ${epochEndMs}`,
    args.test ? "--test" : "",
  ]
    .filter(Boolean)
    .join(" ");

  try {
    execSync(`npx tsx ${SUBMIT_SCRIPT} ${cmdArgs}`, {
      stdio: "inherit",
      timeout: 120_000,
    });
    return true;
  } catch {
    return false;
  }
}

async function main() {
  if (!INDEXER_URL) {
    console.error("Error: --indexer-url is required.");
    console.error(
      "  npx tsx transactions/maker-incentives/epochs/submit-all-epochs.ts --network testnet --indexer-url http://localhost:3000",
    );
    process.exit(1);
  }

  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const client = getClient(NETWORK);
  const funds = await fetchFunds(INDEXER_URL);
  const fundIds = [...funds.keys()];

  if (fundIds.length === 0) {
    log("No funds discovered from indexer. Nothing to do.");
    return;
  }

  const epochs = buildEpochRange();

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — SUBMIT EPOCHS");
  console.log("=".repeat(60));
  console.log(`  Network:       ${NETWORK}`);
  console.log(`  Indexer:       ${INDEXER_URL}`);
  console.log(`  Enclave:       ${args["enclave-url"]}`);
  console.log(`  Funds:         ${fundIds.length}`);
  console.log(`  Lookback:      ${LOOKBACK_DAYS} days (${epochs.length} epochs)`);
  console.log(
    `  Range:         ${new Date(epochs[0].start).toISOString().split("T")[0]} → ${new Date(epochs[epochs.length - 1].end).toISOString().split("T")[0]}`,
  );
  console.log(`  Test mode:     ${args.test}`);
  console.log(`  Dry run:       ${args["dry-run"]}`);
  console.log();

  for (const [fundId, { poolId }] of funds) {
    log(`  ${fundId} -> pool ${poolId}`);
  }
  console.log();

  let submitted = 0;
  let alreadyDone = 0;
  let failed = 0;

  for (const fundId of fundIds) {
    const { poolId } = funds.get(fundId)!;
    log(`--- Fund ${fundId} (pool: ${poolId}) ---`);

    for (const epoch of epochs) {
      const dateStr = new Date(epoch.start).toISOString().split("T")[0];

      const done = await checkEpochSubmitted(
        client,
        config.packageId,
        fundId,
        epoch.start,
      );

      if (done) {
        log(`  SKIP  ${dateStr} — already on-chain`);
        alreadyDone++;
        continue;
      }

      if (args["dry-run"]) {
        log(`  WOULD ${dateStr} — missing, needs submission (dry-run)`);
        submitted++;
        continue;
      }

      log(`  SUBMIT ${dateStr}...`);
      const ok = submitEpoch(fundId, epoch.start, epoch.end);
      if (ok) {
        submitted++;
      } else {
        log(`  FAILED ${dateStr}`);
        failed++;
      }

      await new Promise((r) => setTimeout(r, 2000));
    }

    console.log();
  }

  console.log("=".repeat(60));
  console.log("  ALL FUNDS PROCESSED");
  console.log("=".repeat(60));
  console.log(`  Submitted: ${submitted}`);
  console.log(`  Skipped:   ${alreadyDone} (already on-chain)`);
  console.log(`  Failed:    ${failed}`);
  if (args["dry-run"]) {
    console.log(`  (dry-run — nothing was actually submitted)`);
  }
  console.log();

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
