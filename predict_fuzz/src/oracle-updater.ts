import { Transaction } from "@mysten/sui/transactions";
import { mkdirSync, appendFileSync, existsSync } from "fs";
import path from "path";
import {
  FLOAT_SCALING,
  RISK_FREE_RATE,
  ORACLE_DATA_DIR,
} from "./config.js";
import type {
  PackageEntry,
  OracleEntry,
  OracleDataEntry,
  ScaledSVIParams,
} from "./types.js";
import {
  getOracleKeypair,
  executeTransaction,
  findEvents,
} from "./sui-helpers.js";
import {
  readManifest,
  withManifestLock,
} from "./manifest.js";
import {
  fetchSpotPrice,
  fetchForwardPrice,
  fetchSVIParams,
  scaleToU64,
  scaleSVIParams,
} from "./blockscholes.js";
import { Logger } from "./logger.js";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const TICK_INTERVAL_MS = 2000; // 2s ticks to avoid API rate limits
const SVI_INTERVAL_MS = 20_000;
const MAX_COMMANDS_PER_PTB = 500;

// Each oracle update uses 2 commands (new_price_data + update_prices).
// With SVI it uses 4 commands (+ new_svi_params + update_svi).
const COMMANDS_PER_PRICE_UPDATE = 2;
const COMMANDS_PER_SVI_UPDATE = 2;

const log = new Logger("oracle-updater");

// ---------------------------------------------------------------------------
// In-memory state
// ---------------------------------------------------------------------------

let lastSviUpdateMs = 0;
const quarantinedOracles = new Set<string>();

let running = true;

// ---------------------------------------------------------------------------
// Oracle data logging
// ---------------------------------------------------------------------------

function appendOracleData(entry: OracleDataEntry): void {
  const date = new Date().toISOString().slice(0, 10);
  if (!existsSync(ORACLE_DATA_DIR)) mkdirSync(ORACLE_DATA_DIR, { recursive: true });
  const filePath = path.join(ORACLE_DATA_DIR, `${date}.jsonl`);
  appendFileSync(filePath, JSON.stringify(entry) + "\n");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface OracleJob {
  packageEntry: PackageEntry;
  oracle: OracleEntry;
}

/** Collect all oracles that need price updates (active or pending_settlement). */
function collectOracleJobs(manifest: PackageEntry[]): OracleJob[] {
  const jobs: OracleJob[] = [];
  for (const pkg of manifest) {
    if (!pkg.active) continue;
    for (const oracle of pkg.oracles) {
      if (oracle.state !== "active" && oracle.state !== "pending_settlement") continue;
      if (quarantinedOracles.has(oracle.oracle_id)) continue;
      jobs.push({ packageEntry: pkg, oracle });
    }
  }
  return jobs;
}

/** Retire expired oracles: flip active → pending_settlement if now > expiry_ms. */
function retireExpiredOracles(manifest: PackageEntry[]): { manifest: PackageEntry[]; retired: string[] } {
  const now = Date.now();
  const retired: string[] = [];
  for (const pkg of manifest) {
    for (const oracle of pkg.oracles) {
      if (oracle.state === "active" && now > oracle.expiry_ms) {
        oracle.state = "pending_settlement";
        retired.push(oracle.oracle_id);
      }
    }
  }
  return { manifest, retired };
}

/** Unique expiries across a set of jobs. */
function uniqueExpiries(jobs: OracleJob[]): string[] {
  return [...new Set(jobs.map((j) => j.oracle.expiry_iso))];
}

// ---------------------------------------------------------------------------
// Market data fetching
// ---------------------------------------------------------------------------

interface MarketData {
  spot: number;
  forwards: Map<string, number>;
  sviMap: Map<string, ScaledSVIParams> | null;
  sviRawMap: Map<string, { a: number; b: number; rho: number; m: number; sigma: number }> | null;
}

async function fetchMarketData(expiries: string[], includeSvi: boolean): Promise<MarketData> {
  // Fetch spot first
  const spot = await fetchSpotPrice();

  // Fetch forwards sequentially to avoid rate limits; skip failures
  const forwards = new Map<string, number>();
  for (const exp of expiries) {
    try {
      const fwd = await fetchForwardPrice(exp);
      forwards.set(exp, fwd);
    } catch {
      // Forward not available for this expiry (expired or missing data).
      // Fall back to synthetic forward: F = S * e^(r*T)
      const ttm = (new Date(exp).getTime() - Date.now()) / (365.25 * 24 * 60 * 60 * 1000);
      if (ttm > 0) {
        const rfr = Number(RISK_FREE_RATE) / Number(FLOAT_SCALING);
        forwards.set(exp, spot * Math.exp(rfr * ttm));
      }
      // If ttm <= 0, skip (expired oracle — will be retired)
    }
  }

  let sviMap: Map<string, ScaledSVIParams> | null = null;
  let sviRawMap: Map<string, { a: number; b: number; rho: number; m: number; sigma: number }> | null = null;

  if (includeSvi) {
    sviMap = new Map();
    sviRawMap = new Map();
    const sviResults = await Promise.all(expiries.map((exp) => fetchSVIParams(exp)));
    for (let i = 0; i < expiries.length; i++) {
      sviRawMap.set(expiries[i], sviResults[i]);
      sviMap.set(expiries[i], scaleSVIParams(sviResults[i]));
    }
  }

  return { spot, forwards, sviMap, sviRawMap };
}

// ---------------------------------------------------------------------------
// PTB construction
// ---------------------------------------------------------------------------

interface PTBBatch {
  tx: Transaction;
  oracleIds: string[]; // oracle IDs included in this batch, for error attribution
  commandCount: number;
}

function buildPTBs(
  jobs: OracleJob[],
  marketData: MarketData,
  includeSvi: boolean,
): PTBBatch[] {
  const spotScaled = scaleToU64(marketData.spot);
  const batches: PTBBatch[] = [];

  let currentTx = new Transaction();
  let currentIds: string[] = [];
  let currentCommands = 0;

  function flush() {
    if (currentCommands > 0) {
      batches.push({ tx: currentTx, oracleIds: currentIds, commandCount: currentCommands });
      currentTx = new Transaction();
      currentIds = [];
      currentCommands = 0;
    }
  }

  for (const job of jobs) {
    const { packageEntry, oracle } = job;
    const forward = marketData.forwards.get(oracle.expiry_iso);
    if (forward === undefined) {
      log.warn("No forward price for expiry, skipping", { expiry: oracle.expiry_iso, oracle_id: oracle.oracle_id });
      continue;
    }
    const forwardScaled = scaleToU64(forward);

    // Calculate commands needed for this oracle
    const sviForOracle = includeSvi && oracle.state === "active" ? marketData.sviMap?.get(oracle.expiry_iso) : undefined;
    const commandsNeeded = COMMANDS_PER_PRICE_UPDATE + (sviForOracle ? COMMANDS_PER_SVI_UPDATE : 0);

    // If adding this oracle would exceed the limit, flush
    if (currentCommands + commandsNeeded > MAX_COMMANDS_PER_PTB) {
      flush();
    }

    const packageId = packageEntry.package_id;
    const oracleId = oracle.oracle_id;
    const oracleCapId = packageEntry.oracle_cap_id;

    // Price update
    const priceData = currentTx.moveCall({
      target: `${packageId}::oracle::new_price_data`,
      arguments: [currentTx.pure.u64(spotScaled), currentTx.pure.u64(forwardScaled)],
    });
    currentTx.moveCall({
      target: `${packageId}::oracle::update_prices`,
      arguments: [
        currentTx.object(oracleId),
        currentTx.object(oracleCapId),
        priceData,
        currentTx.object("0x6"),
      ],
    });
    currentCommands += COMMANDS_PER_PRICE_UPDATE;

    // SVI update (only for active oracles, not pending_settlement)
    if (sviForOracle) {
      const sviParams = currentTx.moveCall({
        target: `${packageId}::oracle::new_svi_params`,
        arguments: [
          currentTx.pure.u64(sviForOracle.a),
          currentTx.pure.u64(sviForOracle.b),
          currentTx.pure.u64(sviForOracle.rho),
          currentTx.pure.bool(sviForOracle.rho_negative),
          currentTx.pure.u64(sviForOracle.m),
          currentTx.pure.bool(sviForOracle.m_negative),
          currentTx.pure.u64(sviForOracle.sigma),
        ],
      });
      currentTx.moveCall({
        target: `${packageId}::oracle::update_svi`,
        arguments: [
          currentTx.object(oracleId),
          currentTx.object(oracleCapId),
          sviParams,
          currentTx.pure.u64(RISK_FREE_RATE),
          currentTx.object("0x6"),
        ],
      });
      currentCommands += COMMANDS_PER_SVI_UPDATE;
    }

    currentIds.push(oracleId);
  }

  flush();
  return batches;
}

// ---------------------------------------------------------------------------
// PTB execution with quarantine + manifest updates
// ---------------------------------------------------------------------------

async function executeBatches(batches: PTBBatch[], marketData: MarketData): Promise<void> {
  const keypair = getOracleKeypair();

  for (const batch of batches) {
    try {
      const result = await executeTransaction(batch.tx, keypair);

      // Check for OracleSettled events and update manifest accordingly
      const settledEvents = findEvents(result, "OracleSettled");
      if (settledEvents.length > 0) {
        const settledIds = new Set(
          settledEvents.map((e: any) => e.parsedJson?.oracle_id as string).filter(Boolean),
        );

        await withManifestLock((entries) => {
          for (const pkg of entries) {
            for (const oracle of pkg.oracles) {
              if (settledIds.has(oracle.oracle_id)) {
                oracle.state = "settled";
                log.info("Oracle settled on-chain", { oracle_id: oracle.oracle_id });
              }
            }
          }
          return { entries, result: undefined };
        });
      }

      // Set first_update_ts for any oracle that doesn't have one yet
      const now = new Date().toISOString();
      await withManifestLock((entries) => {
        for (const pkg of entries) {
          for (const oracle of pkg.oracles) {
            if (batch.oracleIds.includes(oracle.oracle_id) && !oracle.first_update_ts) {
              oracle.first_update_ts = now;
            }
          }
        }
        return { entries, result: undefined };
      });

      log.debug("PTB executed successfully", {
        oracles: batch.oracleIds.length,
        commands: batch.commandCount,
      });
    } catch (err: any) {
      log.error("PTB execution failed, quarantining oracles", {
        oracles: batch.oracleIds,
        error: err.message?.slice(0, 500),
      });
      for (const id of batch.oracleIds) {
        quarantinedOracles.add(id);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Oracle data logging per tick
// ---------------------------------------------------------------------------

function logOracleData(marketData: MarketData, expiries: string[]): void {
  const ts = Date.now();
  for (const expiry of expiries) {
    const forward = marketData.forwards.get(expiry);
    if (forward === undefined) continue;

    const sviRaw = marketData.sviRawMap?.get(expiry) ?? null;

    const entry: OracleDataEntry = {
      ts,
      spot: marketData.spot,
      expiry,
      forward,
      svi: sviRaw,
      rfr: Number(RISK_FREE_RATE) / Number(FLOAT_SCALING),
    };
    appendOracleData(entry);
  }
}

// ---------------------------------------------------------------------------
// Main tick
// ---------------------------------------------------------------------------

async function tick(): Promise<void> {
  // 1. Read manifest and retire expired oracles
  const retireResult = await withManifestLock((entries) => {
    const { manifest, retired } = retireExpiredOracles(entries);
    return { entries: manifest, result: { retired } };
  });

  if (retireResult.retired.length > 0) {
    log.info("Retired expired oracles", { oracle_ids: retireResult.retired });
  }

  // 2. Collect active oracle jobs
  const manifest = readManifest();
  const jobs = collectOracleJobs(manifest);
  if (jobs.length === 0) {
    log.debug("No active oracles to update");
    return;
  }

  const expiries = uniqueExpiries(jobs);

  // 3. Determine if we should include SVI this tick
  const now = Date.now();
  const includeSvi = now - lastSviUpdateMs >= SVI_INTERVAL_MS;

  // 4. Fetch market data
  const marketData = await fetchMarketData(expiries, includeSvi);

  log.debug("Market data fetched", {
    spot: marketData.spot,
    expiries: expiries.length,
    includeSvi,
  });

  // 5. Build PTBs
  const batches = buildPTBs(jobs, marketData, includeSvi);
  if (batches.length === 0) {
    log.warn("No PTBs built despite having jobs");
    return;
  }

  log.info("Executing oracle update", {
    oracles: jobs.length,
    batches: batches.length,
    includeSvi,
  });

  // 6. Execute
  await executeBatches(batches, marketData);

  if (includeSvi) {
    lastSviUpdateMs = now;
  }

  // 7. Log oracle data
  logOracleData(marketData, expiries);

  // 8. Heartbeat
  log.heartbeat();
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  log.info("Oracle updater starting", {
    tickInterval: TICK_INTERVAL_MS,
    sviInterval: SVI_INTERVAL_MS,
    oracleAddress: getOracleKeypair().getPublicKey().toSuiAddress(),
  });

  while (running) {
    const tickStart = Date.now();

    try {
      await tick();
    } catch (err: any) {
      log.error("Tick failed", { error: err.message?.slice(0, 1000), stack: err.stack?.slice(0, 500) });
    }

    // Sleep for remainder of tick interval
    const elapsed = Date.now() - tickStart;
    const sleepMs = Math.max(0, TICK_INTERVAL_MS - elapsed);
    if (sleepMs > 0) {
      await new Promise((r) => setTimeout(r, sleepMs));
    }
  }

  log.info("Oracle updater stopped");
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

function shutdown(signal: string) {
  log.info(`Received ${signal}, shutting down gracefully...`);
  running = false;
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

main().catch((err) => {
  log.error("Fatal error in oracle updater", { error: err.message, stack: err.stack });
  process.exit(1);
});
