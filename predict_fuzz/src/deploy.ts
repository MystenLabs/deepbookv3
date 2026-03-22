import { execSync } from "child_process";
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from "fs";
import path from "path";
import { Transaction } from "@mysten/sui/transactions";
import {
  PROJECT_ROOT,
  getDusdcConfig,
  getDusdcType,
  CLOCK_ID,
} from "./config.js";
import {
  getClient,
  getDeployerKeypair,
  getMinterKeypair,
  getDeployerAddress,
  getOracleAddress,
  getMinterAddress,
  executeTransaction,
  findCreatedObjects,
  findPublishedPackage,
  findEvents,
  normId,
  waitForObject,
  waitForObjectVersion,
} from "./sui-helpers.js";
import { withManifestLock, readManifest, writeManifest } from "./manifest.js";
import { discoverExpiries } from "./blockscholes.js";
import { Logger } from "./logger.js";
import type { PackageEntry, OracleEntry } from "./types.js";

// ---------------------------------------------------------------------------
// Deployer lock (filesystem lock, same pattern as manifest lock)
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
// Arg parsing
// ---------------------------------------------------------------------------

function parseArgs(): { commit: string; label: string } {
  const args = process.argv.slice(2);
  let commit = "";
  let label = "";

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--commit" && args[i + 1]) {
      commit = args[++i];
    } else if (args[i] === "--label" && args[i + 1]) {
      label = args[++i];
    }
  }

  if (!commit) {
    console.error("Usage: tsx src/deploy.ts --commit <hash> --label <name>");
    process.exit(1);
  }
  if (!label) {
    console.error("Usage: tsx src/deploy.ts --commit <hash> --label <name>");
    process.exit(1);
  }

  return { commit, label };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const log = new Logger("deploy");

/** Find created object matching a type substring that is shared. */
function findSharedObject(result: any, typeSubstring: string): string {
  const objs = findCreatedObjects(result, typeSubstring);
  const shared = objs.find(
    (o) => o.owner && typeof o.owner === "object" && "Shared" in o.owner,
  );
  if (!shared) {
    throw new Error(`No shared object found matching "${typeSubstring}"`);
  }
  return shared.objectId;
}

/** Find created object matching a type substring that is owned by a specific address. */
function findOwnedObject(result: any, typeSubstring: string, ownerAddress: string): string {
  const objs = findCreatedObjects(result, typeSubstring);
  const owned = objs.find(
    (o) =>
      o.owner &&
      typeof o.owner === "object" &&
      "AddressOwner" in o.owner &&
      normId(o.owner.AddressOwner) === normId(ownerAddress),
  );
  if (!owned) {
    throw new Error(
      `No owned object found matching "${typeSubstring}" for owner ${ownerAddress}`,
    );
  }
  return owned.objectId;
}

/** Find ALL created objects matching a type substring (any ownership). */
function findAllCreatedOfType(result: any, typeSubstring: string): string[] {
  return findCreatedObjects(result, typeSubstring).map((o) => o.objectId);
}

/** Find a created Coin object owned by a specific address. */
function findOwnedCoin(result: any, coinTypeSubstring: string, ownerAddress: string): string {
  const changes = result.objectChanges ?? [];
  const match = changes.find(
    (c: any) =>
      c.type === "created" &&
      c.objectType?.includes("Coin") &&
      c.objectType?.includes(coinTypeSubstring) &&
      c.owner &&
      typeof c.owner === "object" &&
      "AddressOwner" in c.owner &&
      normId(c.owner.AddressOwner) === normId(ownerAddress),
  );
  if (!match) {
    throw new Error(`No Coin object matching "${coinTypeSubstring}" found for owner ${ownerAddress}`);
  }
  return match.objectId;
}

/** Verify an object exists on-chain. */
async function verifyObject(objectId: string, label: string): Promise<void> {
  const client = getClient();
  const resp = await client.getObject({ id: objectId, options: { showType: true } });
  if (!(resp as any).data) {
    throw new Error(`Verification failed: ${label} (${objectId}) not found on-chain`);
  }
  log.info(`Verified ${label}: ${objectId}`);
}

/** Get the git repo root (parent of predict_fuzz). */
function getRepoRoot(): string {
  return path.resolve(PROJECT_ROOT, "..");
}

// ---------------------------------------------------------------------------
// Main deploy flow
// ---------------------------------------------------------------------------

async function main() {
  const { commit, label } = parseArgs();
  const repoRoot = getRepoRoot();
  const worktreePath = `/tmp/predict-fuzz-${commit}`;

  log.info(`Starting deploy: label=${label} commit=${commit}`);

  // Step 0: Acquire deployer lock & get DUSDC config
  log.info("Acquiring deployer lock...");
  await acquireDeployerLock();
  log.info("Deployer lock acquired.");

  try {
    const dusdcConfig = getDusdcConfig();
    const dusdcType = getDusdcType();
    const deployerKeypair = getDeployerKeypair();
    const minterKeypair = getMinterKeypair();
    const deployerAddress = getDeployerAddress();
    const minterAddress = getMinterAddress();

    log.info("Config loaded", {
      dusdcPackageId: dusdcConfig.packageId,
      treasuryCapId: dusdcConfig.treasuryCapId,
      deployerAddress,
      minterAddress,
    });

    // Step 1: Create git worktree + build
    log.info("Setting up git worktree...");
    try {
      execSync(`git worktree add ${worktreePath} ${commit}`, {
        cwd: repoRoot,
        stdio: "pipe",
      });
    } catch (e: any) {
      // Worktree may already exist from a previous failed run
      if (e.stderr?.toString().includes("already checked out") || e.stderr?.toString().includes("already exists")) {
        log.warn("Worktree already exists, removing and re-creating...");
        try { execSync(`git worktree remove ${worktreePath} --force`, { cwd: repoRoot, stdio: "pipe" }); } catch {}
        execSync(`git worktree add ${worktreePath} ${commit}`, {
          cwd: repoRoot,
          stdio: "pipe",
        });
      } else {
        throw e;
      }
    }
    log.info(`Worktree created at ${worktreePath}`);

    log.info("Building Move package...");
    const buildOutput = execSync(
      `sui move build --path ${worktreePath}/packages/predict --dump-bytecode-as-base64`,
      { cwd: repoRoot, stdio: "pipe", maxBuffer: 50 * 1024 * 1024 },
    ).toString();

    // The output may have build logs before the JSON. Find the JSON part.
    const jsonStart = buildOutput.indexOf("{");
    if (jsonStart === -1) {
      throw new Error("Build output does not contain JSON. Output:\n" + buildOutput.slice(0, 2000));
    }
    const buildJson = JSON.parse(buildOutput.slice(jsonStart));
    const modules: string[] = buildJson.modules;
    const dependencies: string[] = buildJson.dependencies;

    if (!modules || modules.length === 0) {
      throw new Error("Build produced no modules");
    }
    log.info(`Build complete: ${modules.length} modules, ${dependencies.length} dependencies`);

    // Step 2: TX1 — Publish package
    log.info("TX1: Publishing package...");
    const tx1 = new Transaction();
    const [upgradeCap] = tx1.publish({ modules, dependencies });
    tx1.transferObjects([upgradeCap], tx1.pure.address(deployerAddress));

    const tx1Result = await executeTransaction(tx1, deployerKeypair);
    const packageId = findPublishedPackage(tx1Result);
    if (!packageId) {
      throw new Error("TX1: Could not find published package ID in result");
    }

    const registryId = findSharedObject(tx1Result, "Registry");
    const adminCapId = findOwnedObject(tx1Result, "AdminCap", deployerAddress);

    log.info("TX1 complete", { packageId, registryId, adminCapId });

    // Wait for the published package to be available on RPC
    log.info("Waiting for package to be indexed...");
    await waitForObject(packageId);
    log.info("Package available on RPC");

    // Step 3: TX2 — Setup caps and predict
    log.info("TX2: Setting up caps, predict, and minting DUSDC...");
    const tx2 = new Transaction();

    // Create deployer_cap
    const deployerCap = tx2.moveCall({
      target: `${packageId}::registry::create_oracle_cap`,
      arguments: [tx2.object(adminCapId)],
    });
    // Create oracle_cap
    const oracleCap = tx2.moveCall({
      target: `${packageId}::registry::create_oracle_cap`,
      arguments: [tx2.object(adminCapId)],
    });

    // Transfer deployer_cap to self
    tx2.transferObjects([deployerCap], tx2.pure.address(deployerAddress));
    // Transfer oracle_cap to self (will be shared in TX4)
    tx2.transferObjects([oracleCap], tx2.pure.address(deployerAddress));

    // Create Predict
    tx2.moveCall({
      target: `${packageId}::registry::create_predict`,
      typeArguments: [dusdcType],
      arguments: [tx2.object(registryId), tx2.object(adminCapId)],
    });

    // Mint 10M DUSDC for vault
    const vaultCoin = tx2.moveCall({
      target: "0x2::coin::mint",
      typeArguments: [dusdcType],
      arguments: [tx2.object(dusdcConfig.treasuryCapId), tx2.pure.u64(10_000_000_000_000n)],
    });
    tx2.transferObjects([vaultCoin], tx2.pure.address(deployerAddress));

    // Mint 1M DUSDC for minter
    const minterCoin = tx2.moveCall({
      target: "0x2::coin::mint",
      typeArguments: [dusdcType],
      arguments: [tx2.object(dusdcConfig.treasuryCapId), tx2.pure.u64(1_000_000_000_000n)],
    });
    tx2.transferObjects([minterCoin], tx2.pure.address(minterAddress));

    const tx2Result = await executeTransaction(tx2, deployerKeypair);

    // Parse TX2 results
    // OracleCapSVI objects owned by deployer — we get two, need to distinguish deployer_cap vs oracle_cap
    // They're created in order, so the first is deployer_cap and the second is oracle_cap
    const oracleCapObjs = findCreatedObjects(tx2Result, "OracleCapSVI").filter(
      (o) =>
        o.owner &&
        typeof o.owner === "object" &&
        "AddressOwner" in o.owner &&
        normId(o.owner.AddressOwner) === normId(deployerAddress),
    );
    if (oracleCapObjs.length < 2) {
      throw new Error(`TX2: Expected 2 OracleCapSVI objects owned by deployer, got ${oracleCapObjs.length}`);
    }
    const deployerCapId = oracleCapObjs[0].objectId;
    const oracleCapId = oracleCapObjs[1].objectId;

    const predictId = findSharedObject(tx2Result, "Predict");
    const vaultCoinId = findOwnedCoin(tx2Result, "dusdc::DUSDC", deployerAddress);

    log.info("TX2 complete", { deployerCapId, oracleCapId, predictId, vaultCoinId });

    // Wait for shared objects to be available
    log.info("Waiting for TX2 objects to be indexed...");
    await waitForObject(predictId);
    log.info("TX2 objects available on RPC");

    // Step 4: TX3 — Deposit vault + create oracles
    log.info("Discovering expiries from Block Scholes...");
    const expiries = await discoverExpiries();
    if (expiries.length === 0) {
      throw new Error("No live expiries found from Block Scholes");
    }
    log.info(`Found ${expiries.length} live expiries`);

    log.info("TX3: Depositing vault and creating oracles...");
    const tx3 = new Transaction();

    // Deposit vault
    tx3.moveCall({
      target: `${packageId}::registry::admin_deposit`,
      typeArguments: [dusdcType],
      arguments: [tx3.object(predictId), tx3.object(adminCapId), tx3.object(vaultCoinId)],
    });

    // Create oracles for each expiry
    for (const expiry of expiries) {
      tx3.moveCall({
        target: `${packageId}::registry::create_oracle`,
        arguments: [
          tx3.object(registryId),
          tx3.object(adminCapId),
          tx3.object(deployerCapId),
          tx3.pure.string("BTC"),
          tx3.pure.u64(BigInt(new Date(expiry).getTime())),
        ],
      });
    }

    const tx3Result = await executeTransaction(tx3, deployerKeypair);

    // Parse oracle entries from OracleCreated events (preserves oracle_id → expiry mapping)
    const oracleCreatedEvents = findEvents(tx3Result, "OracleCreated");
    interface OracleCreatedData { oracle_id: string; expiry: string }
    const oracleData: OracleCreatedData[] = oracleCreatedEvents
      .map((e: any) => e.parsedJson as OracleCreatedData)
      .filter((e): e is OracleCreatedData => !!e?.oracle_id && !!e?.expiry);

    if (oracleData.length === 0) {
      // Fallback: parse from created objects (order not guaranteed!)
      const createdIds = findAllCreatedOfType(tx3Result, "OracleSVI");
      if (createdIds.length === 0) throw new Error("TX3: No oracle objects found in result");
      log.warn("No OracleCreated events found, falling back to object order (expiry mapping may be wrong)");
      for (let i = 0; i < createdIds.length; i++) {
        oracleData.push({ oracle_id: createdIds[i], expiry: String(new Date(expiries[i]).getTime()) });
      }
    }

    const oracleIds = oracleData.map((d) => d.oracle_id);
    log.info(`TX3 complete: created ${oracleIds.length} oracles`, { oracleIds });

    // Wait for oracle objects to be available
    log.info("Waiting for oracle objects to be indexed...");
    await waitForObject(oracleIds[0]);
    log.info("Oracle objects available on RPC");

    // Step 5: TX4a — Register caps + activate oracles
    log.info("TX4a: Registering caps and activating oracles...");
    const tx4a = new Transaction();

    for (const oracleId of oracleIds) {
      // Register deployer_cap on oracle
      tx4a.moveCall({
        target: `${packageId}::registry::register_oracle_cap`,
        arguments: [tx4a.object(oracleId), tx4a.object(adminCapId), tx4a.object(deployerCapId)],
      });
      // Register oracle_cap on oracle (still owned by deployer)
      tx4a.moveCall({
        target: `${packageId}::registry::register_oracle_cap`,
        arguments: [tx4a.object(oracleId), tx4a.object(adminCapId), tx4a.object(oracleCapId)],
      });
      // Activate oracle
      tx4a.moveCall({
        target: `${packageId}::oracle::activate`,
        arguments: [tx4a.object(oracleId), tx4a.object(deployerCapId), tx4a.object(CLOCK_ID)],
      });
    }

    await executeTransaction(tx4a, deployerKeypair);
    log.info("TX4a complete: oracles registered and activated");

    // Step 5b: TX4b — Transfer oracle_cap to oracle wallet
    // (Sharing via public_share_object aborts in PTB context, so we transfer instead.
    //  Oracle wallet can then use the cap directly for update_prices/update_svi.)
    // Wait for the oracle_cap version to update from TX4a usage
    log.info("Waiting for oracle_cap version to propagate after TX4a...");
    await waitForObjectVersion(oracleCapId, 10, 2000);

    log.info("TX4b: Transferring oracle_cap to oracle wallet...");
    const oracleAddress = getOracleAddress();
    const tx4b = new Transaction();
    tx4b.transferObjects([tx4b.object(oracleCapId)], tx4b.pure.address(oracleAddress));

    await executeTransaction(tx4b, deployerKeypair);
    log.info("TX4b complete: oracle_cap transferred to oracle wallet");

    // Wait for transfer to propagate
    await new Promise((r) => setTimeout(r, 2000));

    // Step 6: TX5 (minter) — Create PredictManager
    log.info("TX5: Creating PredictManager for minter...");
    const tx5 = new Transaction();
    tx5.moveCall({
      target: `${packageId}::predict::create_manager`,
      arguments: [],
    });

    const tx5Result = await executeTransaction(tx5, minterKeypair);
    // PredictManager is shared internally by the Move code
    const managerId = findSharedObject(tx5Result, "PredictManager");
    log.info("TX5 complete", { managerId });

    // Wait for PredictManager to be indexed
    log.info("Waiting for PredictManager to be indexed...");
    await waitForObject(managerId);

    // Step 7: TX6 (minter) — Deposit DUSDC into PredictManager
    log.info("TX6: Depositing DUSDC into PredictManager...");

    // Find the minter's DUSDC coin by querying their coins
    const client = getClient();
    const minterCoins = await client.getCoins({
      owner: minterAddress,
      coinType: dusdcType,
    });
    const minterCoinData = (minterCoins as any).data;
    if (!minterCoinData || minterCoinData.length === 0) {
      throw new Error("TX6: No DUSDC coins found for minter");
    }
    // Pick the coin with the largest balance
    const minterDusdcCoin = minterCoinData.sort(
      (a: any, b: any) => (BigInt(b.balance) > BigInt(a.balance) ? 1 : -1),
    )[0];
    const minterDusdcCoinId = minterDusdcCoin.coinObjectId;

    const tx6 = new Transaction();
    tx6.moveCall({
      target: `${packageId}::predict_manager::deposit`,
      typeArguments: [dusdcType],
      arguments: [tx6.object(managerId), tx6.object(minterDusdcCoinId)],
    });

    const tx6Result = await executeTransaction(tx6, minterKeypair);
    log.info("TX6 complete: DUSDC deposited into PredictManager");

    // Step 8: Verify all objects on-chain
    log.info("Verifying objects on-chain...");
    await verifyObject(packageId, "package");
    await verifyObject(registryId, "registry");
    await verifyObject(adminCapId, "admin_cap");
    await verifyObject(deployerCapId, "deployer_cap");
    await verifyObject(oracleCapId, "oracle_cap (shared)");
    await verifyObject(predictId, "predict");
    await verifyObject(managerId, "manager");
    for (const oracleId of oracleIds) {
      await verifyObject(oracleId, "oracle");
    }

    // Build oracle entries from event data (correct oracle_id → expiry mapping)
    const oracleEntries: OracleEntry[] = oracleData.map((d) => {
      const expiryMs = Number(d.expiry);
      const expiryIso = new Date(expiryMs).toISOString();
      return {
        oracle_id: d.oracle_id,
        underlying: "BTC",
        expiry_iso: expiryIso,
        expiry_ms: expiryMs,
        state: "active" as const,
        first_update_ts: null,
      };
    });

    // Add to manifest
    const packageEntry: PackageEntry = {
      label,
      commit,
      package_id: packageId,
      predict_id: predictId,
      registry_id: registryId,
      admin_cap_id: adminCapId,
      deployer_cap_id: deployerCapId,
      oracle_cap_id: oracleCapId,
      manager_id: managerId,
      oracles: oracleEntries,
      deployed_at: new Date().toISOString(),
      active: true,
    };

    await withManifestLock((entries) => {
      entries.push(packageEntry);
      return { entries, result: undefined };
    });

    log.info("Manifest updated with new package entry");

    // Step 9: Clean up worktree
    log.info("Cleaning up worktree...");
    try {
      execSync(`git worktree remove ${worktreePath}`, {
        cwd: repoRoot,
        stdio: "pipe",
      });
      log.info("Worktree removed");
    } catch (e: any) {
      log.warn(`Failed to remove worktree (non-fatal): ${e.message}`);
    }

    log.info("Deploy complete!", {
      label,
      commit,
      packageId,
      predictId,
      registryId,
      oracleCount: oracleIds.length,
      managerId,
    });
  } catch (err: any) {
    log.error(`Deploy failed: ${err.message}`, { stack: err.stack });

    // Clean up worktree on failure
    try {
      execSync(`git worktree remove ${worktreePath} --force`, {
        cwd: getRepoRoot(),
        stdio: "pipe",
      });
      log.info("Worktree cleaned up after failure");
    } catch {
      // Ignore cleanup errors
    }

    process.exit(1);
  } finally {
    releaseDeployerLock();
  }
}

main();
