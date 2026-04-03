#!/usr/bin/env tsx
/**
 * Submit epoch results for ALL active funds discovered from the indexer.
 *
 * Fetches every FundCreated event from the deepbook-server indexer API,
 * deduplicates by fund_id (latest event wins), then calls submit-epoch.ts
 * for each fund. Skips funds whose epoch has already been submitted
 * (idempotent). This is the script the systemd cron should run.
 *
 * Usage:
 *   npx tsx transactions/maker-incentives/submit-all-epochs.ts --network testnet --indexer-url http://localhost:3000
 *   npx tsx transactions/maker-incentives/submit-all-epochs.ts --network testnet --test
 *   npx tsx transactions/maker-incentives/submit-all-epochs.ts --network testnet --enclave-url http://...:3000
 *
 * Options:
 *   --network, -n       testnet | mainnet                        (default: testnet)
 *   --indexer-url       URL of the deepbook indexer/server API    (required)
 *   --enclave-url       URL of the incentives server              (default: http://localhost:3000)
 *   --test              Use /test_process_data endpoint (dummy)   (default: false)
 *   --epoch-start       explicit start timestamp in ms            (default: yesterday midnight UTC)
 *   --epoch-end         explicit end timestamp in ms              (default: today midnight UTC)
 *   --dry-run           just print what would be submitted        (default: false)
 */

import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function defaultEpochBounds(): { start: number; end: number } {
  const now = new Date();
  const todayMidnight = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
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
    "indexer-url": { type: "string" },
    "enclave-url": { type: "string", default: "http://localhost:3000" },
    test: { type: "boolean", default: false },
    "epoch-start": { type: "string", default: String(defaults.start) },
    "epoch-end": { type: "string", default: String(defaults.end) },
    "dry-run": { type: "boolean", default: false },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const INDEXER_URL = args["indexer-url"];
const SUBMIT_SCRIPT = path.resolve(__dirname, "submit-epoch.ts");

function log(msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${msg}`);
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
  // Use a very wide time range to capture all funds ever created.
  // The start_time of 0 gets all events from genesis.
  url.searchParams.set("start_time", "0");
  url.searchParams.set(
    "end_time",
    String(Date.now() + 86_400_000),
  );
  url.searchParams.set("limit", "1000");

  log(`Fetching funds from ${url.toString()}`);
  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(
      `Indexer returned ${res.status}: ${await res.text()}`,
    );
  }

  const events: FundCreatedEvent[] = await res.json();
  log(`Got ${events.length} FundCreated events from indexer`);

  // Deduplicate by fund_id — keep the latest event per fund
  const funds = new Map<string, { poolId: string }>();
  for (const ev of events) {
    funds.set(ev.fund_id, { poolId: ev.pool_id });
  }
  return funds;
}

async function main() {
  if (!INDEXER_URL) {
    console.error("Error: --indexer-url is required.");
    console.error(
      "  npx tsx transactions/maker-incentives/submit-all-epochs.ts --network testnet --indexer-url http://localhost:3000",
    );
    process.exit(1);
  }

  const funds = await fetchFunds(INDEXER_URL);
  const fundIds = [...funds.keys()];

  if (fundIds.length === 0) {
    log("No funds discovered from indexer. Nothing to do.");
    return;
  }

  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — SUBMIT ALL EPOCHS");
  console.log("=".repeat(60));
  console.log(`  Network:   ${NETWORK}`);
  console.log(`  Indexer:   ${INDEXER_URL}`);
  console.log(`  Enclave:   ${args["enclave-url"]}`);
  console.log(`  Funds:     ${fundIds.length}`);
  console.log(
    `  Epoch:     ${new Date(Number(args["epoch-start"])).toISOString()} -> ${new Date(Number(args["epoch-end"])).toISOString()}`,
  );
  console.log(`  Test mode: ${args.test}`);
  console.log(`  Dry run:   ${args["dry-run"]}`);
  console.log();

  for (const [fundId, { poolId }] of funds) {
    log(`  ${fundId} -> pool ${poolId}`);
  }
  console.log();

  let submitted = 0;
  let failed = 0;
  let skipped = 0;

  for (const fundId of fundIds) {
    const { poolId } = funds.get(fundId)!;
    log(`--- Fund ${fundId} (pool: ${poolId}) ---`);

    if (args["dry-run"]) {
      log("  WOULD submit (dry-run)");
      skipped++;
      continue;
    }

    const cmdArgs = [
      `--network ${NETWORK}`,
      `--fund-id ${fundId}`,
      `--enclave-url ${args["enclave-url"]}`,
      `--epoch-start ${args["epoch-start"]}`,
      `--epoch-end ${args["epoch-end"]}`,
      args.test ? "--test" : "",
    ]
      .filter(Boolean)
      .join(" ");

    try {
      execSync(`npx tsx ${SUBMIT_SCRIPT} ${cmdArgs}`, {
        stdio: "inherit",
        timeout: 120_000,
      });
      submitted++;
    } catch {
      log(`  FAILED for fund ${fundId}`);
      failed++;
    }

    if (fundIds.indexOf(fundId) < fundIds.length - 1) {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("  ALL FUNDS PROCESSED");
  console.log("=".repeat(60));
  console.log(`  Submitted: ${submitted}`);
  console.log(`  Failed:    ${failed}`);
  if (args["dry-run"]) {
    console.log(`  Skipped:   ${skipped} (dry-run)`);
  }
  console.log();

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
