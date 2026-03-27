import { existsSync, mkdirSync, appendFileSync } from "fs";
import path from "path";
import { Transaction } from "@mysten/sui/transactions";
import {
  FLOAT_SCALING,
  DIGESTS_DIR,
  ORACLES_PER_PACKAGE,
  MINTS_PER_ORACLE,
  TARGET_NOTIONAL_MIN,
  TARGET_NOTIONAL_MAX,
  getDusdcType,
} from "./config.js";
import {
  getClient,
  getMinterKeypair,
  executeTransaction,
  findEvents,
} from "./sui-helpers.js";
import { readManifest } from "./manifest.js";
import { fetchSpotPrice } from "./blockscholes.js";
import { Logger } from "./logger.js";
import type { FuzzMint, DigestEntry, PackageEntry, OracleEntry } from "./types.js";
import type { SpotPriceSource } from "./spot-price-source.js";
import { LiveSpotSource, CsvSpotSource } from "./spot-price-source.js";

const logger = new Logger("fuzz-worker");

// ---------------------------------------------------------------------------
// Spot price state
// ---------------------------------------------------------------------------

let currentSpot: number | null = null;
let spotFetchedAt = 0;
let spotSource: SpotPriceSource | null = null;
let spotExhausted = false;

const SPOT_POLL_INTERVAL_MS = 5_000;
const SPOT_STALE_THRESHOLD_MS = 30_000;
const TICK_INTERVAL_MS = 500;

// ---------------------------------------------------------------------------
// Random helpers
// ---------------------------------------------------------------------------

function randomFloat(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

function randomBool(): boolean {
  return Math.random() < 0.5;
}

function randomInt(min: number, max: number): number {
  return Math.floor(randomFloat(min, max + 1));
}

// ---------------------------------------------------------------------------
// Mint generation
// ---------------------------------------------------------------------------

function generateMint(pkg: PackageEntry, oracle: OracleEntry, spotPrice: number): FuzzMint {
  // Strike: spot * random multiplier, scaled to FLOAT_SCALING (1e9)
  let multiplier: number;
  if (Math.random() < 0.05) {
    // 5% adversarial extremes
    multiplier = Math.random() < 0.5
      ? 0.1 + Math.random() * 0.2   // 0.1x-0.3x
      : 2.0 + Math.random() * 1.0;  // 2.0x-3.0x
  } else {
    multiplier = randomFloat(0.5, 1.5);
  }

  const strikeUsd = spotPrice * multiplier;
  const strike = Math.round(strikeUsd * Number(FLOAT_SCALING));

  const isUp = randomBool();

  // Estimate approximate contract price (0.01 to 0.99) based on moneyness
  const moneyness = isUp
    ? (spotPrice - strikeUsd) / spotPrice
    : (strikeUsd - spotPrice) / spotPrice;
  const approxPrice = Math.max(0.01, Math.min(0.99, 0.5 + moneyness * 1.5));

  // Target notional: $5-$200 in DUSDC base units (6 decimals)
  const targetNotional = randomFloat(TARGET_NOTIONAL_MIN, TARGET_NOTIONAL_MAX);

  // Quantity = notional / approxPrice, rounded to nearest 1_000_000 (= $1 contract)
  const quantity = Math.max(
    1_000_000,
    Math.round(targetNotional / approxPrice / 1_000_000) * 1_000_000,
  );

  return {
    package_id: pkg.package_id,
    predict_id: pkg.predict_id,
    manager_id: pkg.manager_id,
    oracle_id: oracle.oracle_id,
    expiry_ms: oracle.expiry_ms,
    strike,
    is_up: isUp,
    quantity,
  };
}

// ---------------------------------------------------------------------------
// PTB builder
// ---------------------------------------------------------------------------

function buildMintPtb(mint: FuzzMint, packageId: string, dusdcType: string): Transaction {
  const tx = new Transaction();
  const key = tx.moveCall({
    target: `${packageId}::market_key::new`,
    arguments: [
      tx.pure.id(mint.oracle_id),
      tx.pure.u64(mint.expiry_ms),
      tx.pure.u64(mint.strike),
      tx.pure.bool(mint.is_up),
    ],
  });
  tx.moveCall({
    target: `${packageId}::predict::mint`,
    typeArguments: [dusdcType],
    arguments: [
      tx.object(mint.predict_id),
      tx.object(mint.manager_id),
      tx.object(mint.oracle_id),
      key,
      tx.pure.u64(mint.quantity),
      tx.object("0x6"), // Clock
    ],
  });
  return tx;
}

// ---------------------------------------------------------------------------
// Digest storage
// ---------------------------------------------------------------------------

function appendDigests(entries: DigestEntry[]): void {
  if (entries.length === 0) return;

  if (!existsSync(DIGESTS_DIR)) mkdirSync(DIGESTS_DIR, { recursive: true });

  // Group by package_id for batch writes
  const byPackage = new Map<string, DigestEntry[]>();
  for (const entry of entries) {
    const group = byPackage.get(entry.package_id) ?? [];
    group.push(entry);
    byPackage.set(entry.package_id, group);
  }

  for (const [packageId, group] of byPackage) {
    const filePath = path.join(DIGESTS_DIR, `${packageId}.jsonl`);
    const lines = group.map((e) => JSON.stringify(e)).join("\n") + "\n";
    appendFileSync(filePath, lines);
  }
}

// ---------------------------------------------------------------------------
// Single mint execution
// ---------------------------------------------------------------------------

async function executeMint(mint: FuzzMint): Promise<DigestEntry> {
  const ts = Date.now();
  const baseEntry: DigestEntry = {
    digest: "",
    ts,
    package_id: mint.package_id,
    oracle_id: mint.oracle_id,
    expiry_ms: mint.expiry_ms,
    strike: mint.strike,
    is_up: mint.is_up,
    qty: mint.quantity,
    status: "failure",
    gas_used: 0,
    actual_cost: null,
    ask_price: null,
    error: null,
  };

  try {
    const dusdcType = getDusdcType();
    const tx = buildMintPtb(mint, mint.package_id, dusdcType);
    const keypair = getMinterKeypair();
    const result = await executeTransaction(tx, keypair);

    const digest = result.digest ?? "";
    const gasUsed = result.effects?.gasUsed;
    const totalGas = gasUsed
      ? Number(gasUsed.computationCost) + Number(gasUsed.storageCost) - Number(gasUsed.storageRebate)
      : 0;

    // Parse PositionMinted event for actual cost
    let actualCost: number | null = null;
    let askPrice: number | null = null;
    const mintEvents = findEvents(result, "PositionMinted");
    if (mintEvents.length > 0) {
      const evt = mintEvents[0].parsedJson;
      if (evt) {
        actualCost = evt.cost !== undefined ? Number(evt.cost) : null;
        askPrice = evt.ask_price !== undefined ? Number(evt.ask_price) : null;
      }
    }

    return {
      ...baseEntry,
      digest,
      status: "success",
      gas_used: totalGas,
      actual_cost: actualCost,
      ask_price: askPrice,
    };
  } catch (err: any) {
    const errorMsg = err?.message ?? String(err);
    logger.debug("Mint failed", {
      oracle_id: mint.oracle_id,
      error: errorMsg.slice(0, 200),
    });
    return {
      ...baseEntry,
      error: errorMsg.slice(0, 500),
    };
  }
}

// ---------------------------------------------------------------------------
// Spot price poller
// ---------------------------------------------------------------------------

async function pollSpot(): Promise<void> {
  if (!spotSource || spotExhausted) return;

  try {
    const price = await spotSource.next();
    if (price === null) {
      spotExhausted = true;
      logger.info("Spot price source exhausted");
      running = false;
      return;
    }
    currentSpot = price;
    spotFetchedAt = Date.now();
    logger.debug("Spot price updated", { spot: price });
  } catch (err: any) {
    logger.warn("Failed to fetch spot price", { error: err?.message?.slice(0, 200) });
  }
}

async function waitForFirstSpot(): Promise<void> {
  logger.info("Waiting for first spot price fetch...");
  while (currentSpot === null && !spotExhausted) {
    await pollSpot();
    if (currentSpot !== null) break;
    await sleep(1_000);
  }
  if (currentSpot !== null) {
    logger.info("Initial spot price fetched", { spot: currentSpot });
  }
}

// ---------------------------------------------------------------------------
// Main tick
// ---------------------------------------------------------------------------

async function tick(): Promise<void> {
  // Check spot freshness (for live source, enforce staleness; for CSV, always fresh)
  if (currentSpot === null) {
    logger.warn("Spot price missing, pausing minting");
    return;
  }
  if (spotSource instanceof LiveSpotSource && Date.now() - spotFetchedAt > SPOT_STALE_THRESHOLD_MS) {
    logger.warn("Spot price stale, pausing minting");
    return;
  }

  const spotPrice = currentSpot;

  // Read manifest and filter active packages
  const packages = readManifest().filter((p) => p.active);
  if (packages.length === 0) {
    logger.debug("No active packages found");
    return;
  }

  // Collect all mints to fire
  const allMints: FuzzMint[] = [];

  for (const pkg of packages) {
    // Filter oracles: state="active" AND first_update_ts is set
    const eligibleOracles = pkg.oracles.filter(
      (o) => o.state === "active" && o.first_update_ts !== null,
    );

    if (eligibleOracles.length === 0) continue;

    // Sample up to ORACLES_PER_PACKAGE oracles
    const sampled = sampleArray(eligibleOracles, ORACLES_PER_PACKAGE);

    for (const oracle of sampled) {
      for (let i = 0; i < MINTS_PER_ORACLE; i++) {
        allMints.push(generateMint(pkg, oracle, spotPrice));
      }
    }
  }

  if (allMints.length === 0) {
    logger.debug("No eligible oracles for minting");
    return;
  }

  logger.info(`Firing ${allMints.length} mints across ${packages.length} packages`);

  // Group mints by package. Within a package, mints touch the same shared objects
  // (&mut Predict, &mut PredictManager) so they're sequenced at consensus anyway.
  // Fire mints sequentially within a package, parallel across packages.
  const mintsByPackage = new Map<string, FuzzMint[]>();
  for (const mint of allMints) {
    const group = mintsByPackage.get(mint.package_id) ?? [];
    group.push(mint);
    mintsByPackage.set(mint.package_id, group);
  }

  const packageResults = await Promise.allSettled(
    [...mintsByPackage.values()].map(async (mints) => {
      const results: DigestEntry[] = [];
      for (const mint of mints) {
        results.push(await executeMint(mint));
      }
      return results;
    }),
  );

  const entries: DigestEntry[] = [];
  let successCount = 0;
  let failCount = 0;

  for (const result of packageResults) {
    if (result.status === "fulfilled") {
      for (const entry of result.value) {
        entries.push(entry);
        if (entry.status === "success") successCount++;
        else failCount++;
      }
    } else {
      failCount++;
      logger.error("Unexpected package rejection", { reason: String(result.reason).slice(0, 200) });
    }
  }

  // Batch write digests grouped by package_id
  appendDigests(entries);

  logger.info(`Tick complete: ${successCount} success, ${failCount} failed`, {
    total: allMints.length,
    successCount,
    failCount,
  });

  logger.heartbeat();
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function sampleArray<T>(arr: T[], n: number): T[] {
  if (arr.length <= n) return arr;
  // Fisher-Yates partial shuffle
  const copy = [...arr];
  for (let i = 0; i < n; i++) {
    const j = i + Math.floor(Math.random() * (copy.length - i));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy.slice(0, n);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// CLI arg parsing
// ---------------------------------------------------------------------------

function parseSpotSource(): SpotPriceSource {
  const args = process.argv.slice(2);
  let csvPath = "";
  let priceColumn = "";

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--spot-csv":
        csvPath = args[++i];
        break;
      case "--price-column":
        priceColumn = args[++i];
        break;
    }
  }

  if (csvPath) {
    logger.info("Using CSV spot price source", { path: csvPath, column: priceColumn || "auto" });
    return new CsvSpotSource(csvPath, priceColumn || undefined);
  }

  logger.info("Using live Block Scholes spot price source");
  return new LiveSpotSource(fetchSpotPrice);
}

// ---------------------------------------------------------------------------
// Main loop with graceful shutdown
// ---------------------------------------------------------------------------

let running = true;

function handleShutdown(signal: string) {
  logger.info(`Received ${signal}, shutting down gracefully...`);
  running = false;
}

async function main(): Promise<void> {
  process.on("SIGINT", () => handleShutdown("SIGINT"));
  process.on("SIGTERM", () => handleShutdown("SIGTERM"));

  logger.info("Fuzz worker starting");

  // Initialize spot price source
  spotSource = parseSpotSource();

  // Block until we have a spot price
  await waitForFirstSpot();

  // Start background spot price polling (for live source)
  const spotInterval = spotSource instanceof LiveSpotSource
    ? setInterval(pollSpot, SPOT_POLL_INTERVAL_MS)
    : null;

  try {
    while (running) {
      // For CSV source, advance spot price each tick
      if (!(spotSource instanceof LiveSpotSource)) {
        await pollSpot();
        if (spotExhausted) break;
      }

      try {
        await tick();
      } catch (err: any) {
        logger.error("Tick error", { error: err?.message?.slice(0, 500) });
      }
      if (running) await sleep(TICK_INTERVAL_MS);
    }
  } finally {
    if (spotInterval) clearInterval(spotInterval);
    logger.info("Fuzz worker stopped");
  }
}

main().catch((err) => {
  logger.error("Fatal error", { error: err?.message ?? String(err) });
  process.exit(1);
});
