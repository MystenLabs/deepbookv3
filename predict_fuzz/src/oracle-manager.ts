import { mkdirSync, rmSync, writeFileSync, readFileSync } from "fs";
import path from "path";
import { Transaction } from "@mysten/sui/transactions";
import { PROJECT_ROOT, CLOCK_ID } from "./config.js";
import {
  getDeployerKeypair,
  executeTransaction,
  findCreatedObjects,
} from "./sui-helpers.js";
import { withManifestLock, readManifest } from "./manifest.js";
import { discoverExpiries } from "./blockscholes.js";
import { Logger } from "./logger.js";
import type { PackageEntry, OracleEntry } from "./types.js";

// ---------------------------------------------------------------------------
// Deployer lock (same as deploy.ts)
// ---------------------------------------------------------------------------

const DEPLOYER_LOCK_PATH = path.resolve(PROJECT_ROOT, ".deployer.lock");
const DEPLOYER_LOCK_TIMEOUT_MS = 10_000;
const DEPLOYER_LOCK_SPIN_MS = 100;
const DEPLOYER_LOCK_STALE_MS = 300_000; // 5 minutes

interface LockOwner {
  pid: number;
  ts: number;
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function acquireDeployerLock(): Promise<void> {
  const ownerFile = path.join(DEPLOYER_LOCK_PATH, "owner.json");
  const start = Date.now();

  while (true) {
    try {
      mkdirSync(DEPLOYER_LOCK_PATH);
      writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, ts: Date.now() }));
      return;
    } catch (e: any) {
      if (e.code !== "EEXIST") throw e;
    }

    if (Date.now() - start > DEPLOYER_LOCK_TIMEOUT_MS) {
      try {
        const owner: LockOwner = JSON.parse(readFileSync(ownerFile, "utf8"));
        if (!isProcessAlive(owner.pid)) {
          rmSync(DEPLOYER_LOCK_PATH, { recursive: true });
          continue;
        }
        if (Date.now() - owner.ts > DEPLOYER_LOCK_STALE_MS) {
          throw new Error(
            `Deployer lock held by PID ${owner.pid} for ${Math.round((Date.now() - owner.ts) / 1000)}s — investigate`,
          );
        }
      } catch (readErr: any) {
        if (readErr.code === "ENOENT") {
          try { rmSync(DEPLOYER_LOCK_PATH, { recursive: true }); } catch {}
          continue;
        }
        if (readErr.message?.includes("investigate")) throw readErr;
      }
    }

    await new Promise((r) => setTimeout(r, DEPLOYER_LOCK_SPIN_MS));
  }
}

function releaseDeployerLock(): void {
  try {
    rmSync(DEPLOYER_LOCK_PATH, { recursive: true });
  } catch {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const log = new Logger("oracle-manager");

/** Find ALL created objects matching a type substring (any ownership). */
function findAllCreatedOfType(result: any, typeSubstring: string): string[] {
  return findCreatedObjects(result, typeSubstring).map((o) => o.objectId);
}

// ---------------------------------------------------------------------------
// Main oracle-manager flow
// ---------------------------------------------------------------------------

async function main() {
  log.info("Oracle manager starting");

  // Step 1: Acquire deployer lock
  log.info("Acquiring deployer lock...");
  await acquireDeployerLock();
  log.info("Deployer lock acquired");

  try {
    const deployerKeypair = getDeployerKeypair();

    // Step 2: Read packages.json for all active packages
    const packages = readManifest().filter((p) => p.active);
    if (packages.length === 0) {
      log.info("No active packages found in manifest — nothing to do");
      return;
    }
    log.info(`Found ${packages.length} active package(s)`);

    // Step 3: Discover live expiries from Block Scholes
    log.info("Discovering expiries from Block Scholes...");
    const liveExpiries = await discoverExpiries();
    if (liveExpiries.length === 0) {
      log.warn("No live expiries found from Block Scholes — nothing to do");
      return;
    }
    log.info(`Discovered ${liveExpiries.length} live expiries`);

    // Step 4: For each package, determine new expiries and create oracles
    let totalCreated = 0;

    for (const pkg of packages) {
      try {
        await processPackage(pkg, liveExpiries, deployerKeypair);
        totalCreated++;
      } catch (err: any) {
        log.error(`Failed to process package ${pkg.label} (${pkg.package_id}): ${err.message}`, {
          stack: err.stack,
        });
        // Continue with other packages
      }
    }

    log.info(`Oracle manager complete. Processed ${totalCreated}/${packages.length} packages.`);
  } catch (err: any) {
    log.error(`Oracle manager failed: ${err.message}`, { stack: err.stack });
    process.exit(1);
  } finally {
    releaseDeployerLock();
    log.info("Deployer lock released");
  }
}

async function processPackage(
  pkg: PackageEntry,
  liveExpiries: string[],
  deployerKeypair: ReturnType<typeof getDeployerKeypair>,
): Promise<void> {
  // Determine which expiries are new (not already in the package's oracles array)
  const existingExpiries = new Set(pkg.oracles.map((o) => o.expiry_iso));
  const newExpiries = liveExpiries.filter((e) => !existingExpiries.has(e));

  if (newExpiries.length === 0) {
    log.info(`Package ${pkg.label}: no new expiries to add`);
    return;
  }

  log.info(`Package ${pkg.label}: creating ${newExpiries.length} new oracle(s)`, {
    newExpiries,
  });

  // TX1: create_oracle for each new expiry
  log.info(`Package ${pkg.label}: TX1 — creating oracles...`);
  const tx1 = new Transaction();
  for (const expiry of newExpiries) {
    tx1.moveCall({
      target: `${pkg.package_id}::registry::create_oracle`,
      arguments: [
        tx1.object(pkg.registry_id),
        tx1.object(pkg.admin_cap_id),
        tx1.object(pkg.deployer_cap_id),
        tx1.pure.string("BTC"),
        tx1.pure.u64(BigInt(new Date(expiry).getTime())),
      ],
    });
  }

  const tx1Result = await executeTransaction(tx1, deployerKeypair);

  // Parse oracle entries from OracleCreated events (preserves oracle_id → expiry mapping)
  const oracleCreatedEvents = (tx1Result.events ?? []).filter(
    (e: any) => e.type?.includes("OracleCreated"),
  );
  interface OracleCreatedData { oracle_id: string; expiry: string }
  const oracleData: OracleCreatedData[] = oracleCreatedEvents
    .map((e: any) => e.parsedJson as OracleCreatedData)
    .filter((e: any): e is OracleCreatedData => !!e?.oracle_id && !!e?.expiry);

  const newOracleIds = oracleData.length > 0
    ? oracleData.map((d) => d.oracle_id)
    : findAllCreatedOfType(tx1Result, "OracleSVI");

  if (newOracleIds.length === 0) {
    throw new Error("TX1: No OracleSVI objects found in result");
  }

  log.info(`Package ${pkg.label}: TX1 complete — created ${newOracleIds.length} oracle(s)`, {
    oracleIds: newOracleIds,
  });

  // TX2: register both caps on each new oracle, activate with deployer_cap
  log.info(`Package ${pkg.label}: TX2 — registering caps and activating oracles...`);
  const tx2 = new Transaction();
  for (const oracleId of newOracleIds) {
    tx2.moveCall({
      target: `${pkg.package_id}::registry::register_oracle_cap`,
      arguments: [tx2.object(oracleId), tx2.object(pkg.admin_cap_id), tx2.object(pkg.deployer_cap_id)],
    });
    tx2.moveCall({
      target: `${pkg.package_id}::registry::register_oracle_cap`,
      arguments: [tx2.object(oracleId), tx2.object(pkg.admin_cap_id), tx2.object(pkg.oracle_cap_id)],
    });
    tx2.moveCall({
      target: `${pkg.package_id}::oracle::activate`,
      arguments: [tx2.object(oracleId), tx2.object(pkg.deployer_cap_id), tx2.object(CLOCK_ID)],
    });
  }

  await executeTransaction(tx2, deployerKeypair);
  log.info(`Package ${pkg.label}: TX2 complete — oracles activated`);

  // Update packages.json with new oracle entries (use event data for correct mapping)
  const newOracleEntries: OracleEntry[] = oracleData.length > 0
    ? oracleData.map((d) => {
        const expiryMs = Number(d.expiry);
        return {
          oracle_id: d.oracle_id,
          underlying: "BTC",
          expiry_iso: new Date(expiryMs).toISOString(),
          expiry_ms: expiryMs,
          state: "active" as const,
          first_update_ts: null,
        };
      })
    : newOracleIds.map((oracleId, i) => ({
        oracle_id: oracleId,
        underlying: "BTC",
        expiry_iso: newExpiries[i],
        expiry_ms: new Date(newExpiries[i]).getTime(),
        state: "active" as const,
        first_update_ts: null,
      }));

  await withManifestLock((entries) => {
    const target = entries.find((e) => e.package_id === pkg.package_id);
    if (target) {
      target.oracles.push(...newOracleEntries);
    } else {
      log.warn(`Package ${pkg.package_id} not found in manifest during update — skipping`);
    }
    return { entries, result: undefined };
  });

  log.info(`Package ${pkg.label}: manifest updated with ${newOracleEntries.length} new oracle(s)`);
}

main();
