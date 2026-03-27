/**
 * Simulation orchestrator.
 *
 * Coordinates oracle data feeding and fuzz trading against a deployed
 * predict package. Works with any OracleDataSource (CSV, parquet, or live).
 *
 * Usage:
 *   npx tsx src/simulate.ts --source csv \
 *     --prices-csv /path/to/prices.csv --svi-csv /path/to/svi.csv \
 *     --expiry "2026-03-13T08:00:00Z"
 *
 *   npx tsx src/simulate.ts --source parquet \
 *     --data-dir /path/to/gap_up
 *
 *   npx tsx src/simulate.ts --source live
 */

import { Transaction } from "@mysten/sui/transactions";
import {
  FLOAT_SCALING,
  RISK_FREE_RATE,
  TARGET_NOTIONAL_MIN,
  TARGET_NOTIONAL_MAX,
  getDusdcType,
} from "./config.js";
import {
  getOracleKeypair,
  getMinterKeypair,
  executeTransaction,
  findEvents,
} from "./sui-helpers.js";
import { readManifest } from "./manifest.js";
import { scaleToU64, scaleExpiryData } from "./oracle-data-source.js";
import type { OracleDataSource, OracleSnapshot } from "./oracle-data-source.js";
import type { PackageEntry, OracleEntry, DigestEntry } from "./types.js";
import { CsvOracleSource } from "./csv-oracle-source.js";
import { ParquetOracleSource } from "./parquet-oracle-source.js";
import { LiveOracleSource } from "./live-oracle-source.js";
import { Logger } from "./logger.js";

const log = new Logger("simulate");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

interface SimConfig {
  maxEvents: number;
  tradeEvery: number;
  mintPerTrade: number;
  seed: number;
  removeProbability: number;
}

const DEFAULT_CONFIG: SimConfig = {
  maxEvents: 2_000_000,
  tradeEvery: 200,
  mintPerTrade: 3,
  seed: 42,
  removeProbability: 0.3,
};

// ---------------------------------------------------------------------------
// Gas tracking
// ---------------------------------------------------------------------------

interface GasRecord {
  operation: string;
  gas: number;
  timestamp: number;
}

interface SimStats {
  oracleUpdates: number;
  mints: number;
  redeems: number;
  mintSuccesses: number;
  mintFailures: number;
  gasRecords: GasRecord[];
  startTime: number;
}

function newStats(): SimStats {
  return {
    oracleUpdates: 0,
    mints: 0,
    redeems: 0,
    mintSuccesses: 0,
    mintFailures: 0,
    gasRecords: [],
    startTime: Date.now(),
  };
}

// ---------------------------------------------------------------------------
// Oracle feeding
// ---------------------------------------------------------------------------

async function feedOracleSnapshot(
  snapshot: OracleSnapshot,
  pkg: PackageEntry,
  stats: SimStats,
): Promise<void> {
  const oracleKeypair = getOracleKeypair();
  const spotScaled = scaleToU64(snapshot.spot);

  // Build PTB with updates for each expiry
  const tx = new Transaction();
  let commandCount = 0;

  for (const expiryData of snapshot.expiries) {
    // Find matching oracle in manifest
    const oracle = pkg.oracles.find(
      (o) => o.expiry_iso === expiryData.expiry_iso && o.state === "active",
    );
    if (!oracle) continue;

    const scaled = scaleExpiryData(expiryData);

    // Price update
    const priceData = tx.moveCall({
      target: `${pkg.package_id}::oracle::new_price_data`,
      arguments: [tx.pure.u64(spotScaled), tx.pure.u64(scaled.forward)],
    });
    tx.moveCall({
      target: `${pkg.package_id}::oracle::update_prices`,
      arguments: [
        tx.object(oracle.oracle_id),
        tx.object(pkg.oracle_cap_id),
        priceData,
        tx.object("0x6"),
      ],
    });
    commandCount += 2;

    // SVI update (if this snapshot includes SVI)
    if (scaled.svi) {
      const sviParams = tx.moveCall({
        target: `${pkg.package_id}::oracle::new_svi_params`,
        arguments: [
          tx.pure.u64(scaled.svi.a),
          tx.pure.u64(scaled.svi.b),
          tx.pure.u64(scaled.svi.rho),
          tx.pure.bool(scaled.svi.rho_negative),
          tx.pure.u64(scaled.svi.m),
          tx.pure.bool(scaled.svi.m_negative),
          tx.pure.u64(scaled.svi.sigma),
        ],
      });
      tx.moveCall({
        target: `${pkg.package_id}::oracle::update_svi`,
        arguments: [
          tx.object(oracle.oracle_id),
          tx.object(pkg.oracle_cap_id),
          sviParams,
          tx.pure.u64(scaled.risk_free_rate),
          tx.object("0x6"),
        ],
      });
      commandCount += 2;
    }
  }

  if (commandCount === 0) return;

  const result = await executeTransaction(tx, oracleKeypair);
  const gasUsed = result.effects?.gasUsed;
  const totalGas = gasUsed
    ? Number(gasUsed.computationCost) +
      Number(gasUsed.storageCost) -
      Number(gasUsed.storageRebate)
    : 0;

  stats.oracleUpdates++;
  stats.gasRecords.push({
    operation: "oracle_update",
    gas: totalGas,
    timestamp: snapshot.timestamp,
  });
}

// ---------------------------------------------------------------------------
// Trade execution
// ---------------------------------------------------------------------------

function randomFloat(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

async function executeTrade(
  snapshot: OracleSnapshot,
  pkg: PackageEntry,
  stats: SimStats,
): Promise<void> {
  const minterKeypair = getMinterKeypair();
  const dusdcType = getDusdcType();

  // Pick a random active oracle with matching expiry data
  const eligibleOracles = pkg.oracles.filter(
    (o) =>
      o.state === "active" &&
      o.first_update_ts !== null &&
      snapshot.expiries.some((e) => e.expiry_iso === o.expiry_iso),
  );

  if (eligibleOracles.length === 0) return;

  const oracle = eligibleOracles[Math.floor(Math.random() * eligibleOracles.length)];

  // Random strike near spot
  const multiplier = randomFloat(0.5, 1.5);
  const strikeUsd = snapshot.spot * multiplier;
  const strike = Math.round(strikeUsd * 1e9);
  const isUp = Math.random() < 0.5;

  // Random quantity from target notional
  const moneyness = isUp
    ? (snapshot.spot - strikeUsd) / snapshot.spot
    : (strikeUsd - snapshot.spot) / snapshot.spot;
  const approxPrice = Math.max(0.01, Math.min(0.99, 0.5 + moneyness * 1.5));
  const targetNotional = randomFloat(TARGET_NOTIONAL_MIN, TARGET_NOTIONAL_MAX);
  const quantity = Math.max(
    1_000_000,
    Math.round(targetNotional / approxPrice / 1_000_000) * 1_000_000,
  );

  // Build mint PTB
  const tx = new Transaction();
  const key = tx.moveCall({
    target: `${pkg.package_id}::market_key::new`,
    arguments: [
      tx.pure.id(oracle.oracle_id),
      tx.pure.u64(oracle.expiry_ms),
      tx.pure.u64(strike),
      tx.pure.bool(isUp),
    ],
  });
  tx.moveCall({
    target: `${pkg.package_id}::predict::mint`,
    typeArguments: [dusdcType],
    arguments: [
      tx.object(pkg.predict_id),
      tx.object(pkg.manager_id),
      tx.object(oracle.oracle_id),
      key,
      tx.pure.u64(quantity),
      tx.object("0x6"),
    ],
  });

  try {
    const result = await executeTransaction(tx, minterKeypair);
    const gasUsed = result.effects?.gasUsed;
    const totalGas = gasUsed
      ? Number(gasUsed.computationCost) +
        Number(gasUsed.storageCost) -
        Number(gasUsed.storageRebate)
      : 0;

    stats.mints++;
    stats.mintSuccesses++;
    stats.gasRecords.push({
      operation: "mint",
      gas: totalGas,
      timestamp: snapshot.timestamp,
    });
  } catch (err: any) {
    stats.mints++;
    stats.mintFailures++;
    log.debug("Mint failed", { error: err.message?.slice(0, 200) });
  }
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

function printReport(stats: SimStats): void {
  const elapsed = (Date.now() - stats.startTime) / 1000;

  console.log("\n=== Simulation Summary ===");
  console.log(`Duration: ${elapsed.toFixed(1)}s`);
  console.log(`Oracle updates: ${stats.oracleUpdates}`);
  console.log(
    `Mints: ${stats.mints} (${stats.mintSuccesses} success, ${stats.mintFailures} failed)`,
  );
  console.log(`Redeems: ${stats.redeems}`);

  // Gas stats by operation
  const byOp = new Map<string, number[]>();
  for (const r of stats.gasRecords) {
    const arr = byOp.get(r.operation) ?? [];
    arr.push(r.gas);
    byOp.set(r.operation, arr);
  }

  if (byOp.size > 0) {
    console.log("\n=== Gas Profile ===");
    console.log(
      `${"Operation".padEnd(20)} ${"Count".padStart(8)} ${"Avg".padStart(12)} ${"P99".padStart(12)} ${"Max".padStart(12)}`,
    );
    for (const [op, costs] of byOp) {
      costs.sort((a, b) => a - b);
      const count = costs.length;
      const avg = Math.round(costs.reduce((a, b) => a + b, 0) / count);
      const p99 = costs[Math.floor(count * 0.99)];
      const max = costs[count - 1];
      console.log(
        `${op.padEnd(20)} ${String(count).padStart(8)} ${String(avg).padStart(12)} ${String(p99).padStart(12)} ${String(max).padStart(12)}`,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

async function runSimulation(
  source: OracleDataSource,
  config: SimConfig,
): Promise<void> {
  const manifest = readManifest();
  const activePkgs = manifest.filter((p) => p.active);
  if (activePkgs.length === 0) {
    throw new Error("No active packages in manifest. Run deploy first.");
  }
  const pkg = activePkgs[0];

  const total = source.totalSnapshots();
  const totalStr = total !== null ? `/${total}` : "";
  const stats = newStats();
  let step = 0;

  log.info("Starting simulation", {
    package: pkg.label,
    maxEvents: config.maxEvents,
    tradeEvery: config.tradeEvery,
    totalSnapshots: total,
  });

  while (step < config.maxEvents) {
    const snapshot = await source.next();
    if (!snapshot) break;

    // Feed oracle update
    try {
      await feedOracleSnapshot(snapshot, pkg, stats);
    } catch (err: any) {
      log.warn("Oracle update failed", { error: err.message?.slice(0, 200) });
    }

    // Trade every N events
    if (step % config.tradeEvery === 0 && step > 0) {
      for (let i = 0; i < config.mintPerTrade; i++) {
        await executeTrade(snapshot, pkg, stats);
      }
    }

    step++;
    if (step % 500 === 0) {
      const rate = (step / ((Date.now() - stats.startTime) / 1000)).toFixed(1);
      log.info(
        `Progress: ${step}${totalStr} events (${rate}/s, ${stats.mintSuccesses} mints ok, ${stats.mintFailures} failed)`,
      );
    }
  }

  log.info(`Simulation complete: ${step} events processed`);
  printReport(stats);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(): { source: OracleDataSource; config: SimConfig } {
  const args = process.argv.slice(2);
  const config = { ...DEFAULT_CONFIG };

  let sourceType = "csv";
  let pricesCsv = "";
  let sviCsv = "";
  let expiry = "";
  let dataDir = "";

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--source":
        sourceType = args[++i];
        break;
      case "--prices-csv":
        pricesCsv = args[++i];
        break;
      case "--svi-csv":
        sviCsv = args[++i];
        break;
      case "--expiry":
        expiry = args[++i];
        break;
      case "--data-dir":
        dataDir = args[++i];
        break;
      case "--max-events":
        config.maxEvents = Number(args[++i]);
        break;
      case "--trade-every":
        config.tradeEvery = Number(args[++i]);
        break;
      case "--mints-per-trade":
        config.mintPerTrade = Number(args[++i]);
        break;
      case "--seed":
        config.seed = Number(args[++i]);
        break;
    }
  }

  let source: OracleDataSource;
  switch (sourceType) {
    case "csv":
      if (!pricesCsv || !sviCsv || !expiry) {
        console.error(
          "CSV source requires: --prices-csv <path> --svi-csv <path> --expiry <iso>",
        );
        process.exit(1);
      }
      source = new CsvOracleSource(pricesCsv, sviCsv, expiry);
      break;
    case "parquet":
      if (!dataDir) {
        console.error("Parquet source requires: --data-dir <path>");
        process.exit(1);
      }
      source = new ParquetOracleSource(dataDir, expiry ? [expiry] : undefined);
      break;
    case "live":
      source = new LiveOracleSource(expiry ? [expiry] : []);
      break;
    default:
      console.error(`Unknown source type: ${sourceType}. Use csv, parquet, or live.`);
      process.exit(1);
  }

  return { source, config };
}

async function main(): Promise<void> {
  const { source, config } = parseArgs();
  await runSimulation(source, config);
}

main().catch((err) => {
  log.error("Simulation failed", { error: err.message, stack: err.stack });
  process.exit(1);
});
