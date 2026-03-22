/**
 * Replay Service — enriches transaction digests with on-chain gas and state data.
 *
 * Usage: tsx src/replay-service.ts [--package <id>]
 *
 * For each unprocessed digest in digests/{package_id}.jsonl:
 *   1. Fetch full transaction details (effects, events, object changes)
 *   2. Parse gas from effects.gasUsed
 *   3. For successful mints: parse PositionMinted event, fetch post-tx vault state
 *   4. Append result to replays/{package_id}.jsonl
 *   5. Track cursor in replays/.cursor.json
 */

import {
  readFileSync,
  writeFileSync,
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
} from "fs";
import path from "path";
import { DIGESTS_DIR, REPLAYS_DIR } from "./config.js";
import { getClient, findEvents, normId } from "./sui-helpers.js";
import { readManifest } from "./manifest.js";
import { Logger } from "./logger.js";
import type { DigestEntry, ReplayResult, PackageEntry } from "./types.js";

const CURSOR_PATH = path.join(REPLAYS_DIR, ".cursor.json");
const BATCH_DELAY_MS = 200; // delay between RPC calls to avoid rate limits

const log = new Logger("replay");

// ---------------------------------------------------------------------------
// Cursor management
// ---------------------------------------------------------------------------

function loadCursors(): Record<string, number> {
  if (!existsSync(CURSOR_PATH)) return {};
  return JSON.parse(readFileSync(CURSOR_PATH, "utf8"));
}

function saveCursors(cursors: Record<string, number>): void {
  if (!existsSync(REPLAYS_DIR)) mkdirSync(REPLAYS_DIR, { recursive: true });
  writeFileSync(CURSOR_PATH, JSON.stringify(cursors, null, 2));
}

// ---------------------------------------------------------------------------
// Digest file reading
// ---------------------------------------------------------------------------

function readDigestFile(filePath: string, startLine: number): DigestEntry[] {
  const content = readFileSync(filePath, "utf8").trim();
  if (!content) return [];
  const lines = content.split("\n");
  return lines.slice(startLine).map((l) => JSON.parse(l) as DigestEntry);
}

// ---------------------------------------------------------------------------
// Process a single digest
// ---------------------------------------------------------------------------

async function processDigest(
  entry: DigestEntry,
  manifest: PackageEntry[],
): Promise<ReplayResult> {
  const client = getClient();

  try {
    const txResult = await client.getTransactionBlock({
      digest: entry.digest,
      options: {
        showEffects: true,
        showEvents: true,
        showObjectChanges: true,
      },
    });

    const effects = (txResult as any).effects;
    const gasUsed = effects?.gasUsed ?? {};

    const computation = Number(gasUsed.computationCost ?? 0);
    const storage = Number(gasUsed.storageCost ?? 0);
    const storageRebate = Number(gasUsed.storageRebate ?? 0);

    const gas = {
      computation,
      storage,
      storage_rebate: storageRebate,
      total: computation + storage - storageRebate,
    };

    let vault: ReplayResult["vault"] = null;
    let mintData: ReplayResult["mint"] = null;

    if (entry.status === "success") {
      // Parse PositionMinted event
      const mintEvents = ((txResult as any).events ?? []).filter(
        (e: any) => e.type?.includes("PositionMinted"),
      );

      if (mintEvents.length > 0) {
        const evt = mintEvents[0].parsedJson;
        mintData = {
          strike: Number(evt.strike),
          is_up: evt.is_up,
          quantity: Number(evt.quantity),
          oracle_id: evt.oracle_id,
        };
      }

      // Try to get post-tx vault state via tryGetPastObject
      const pkg = manifest.find(
        (p) => normId(p.package_id) === normId(entry.package_id),
      );

      if (pkg) {
        const mutated = effects?.mutated ?? [];
        const predictRef = mutated.find((m: any) => {
          const id = m.reference?.objectId ?? m.objectId;
          return id && normId(id) === normId(pkg.predict_id);
        });

        if (predictRef) {
          const version =
            predictRef.reference?.version ?? predictRef.version;
          if (version) {
            try {
              const pastObj = await client.tryGetPastObject({
                id: pkg.predict_id,
                version: Number(version),
                options: { showContent: true },
              });
              const content = (pastObj as any)?.data?.content;
              if (content?.fields) {
                vault = {
                  balance: Number(
                    content.fields.vault_balance ??
                      content.fields.balance ??
                      0,
                  ),
                  total_mtm: Number(content.fields.total_mtm ?? 0),
                };
              }
            } catch {
              // tryGetPastObject may not be available or may fail
            }
          }
        }
      }
    }

    return {
      digest: entry.digest,
      ts: entry.ts,
      status: entry.status,
      gas,
      gas_profile: null,
      vault,
      mint: mintData ?? {
        strike: entry.strike,
        is_up: entry.is_up,
        quantity: entry.qty,
        oracle_id: entry.oracle_id,
      },
      error: entry.error,
    };
  } catch (err: any) {
    return {
      digest: entry.digest,
      ts: entry.ts,
      status: "failure",
      gas: { computation: 0, storage: 0, storage_rebate: 0, total: 0 },
      gas_profile: null,
      vault: null,
      mint: {
        strike: entry.strike,
        is_up: entry.is_up,
        quantity: entry.qty,
        oracle_id: entry.oracle_id,
      },
      error: `replay_error: ${err.message}`,
    };
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function parseArgs(): { packageFilter: string | null } {
  const args = process.argv.slice(2);
  let packageFilter: string | null = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--package" && i + 1 < args.length) {
      packageFilter = args[i + 1];
      i++;
    }
  }
  return { packageFilter };
}

async function main() {
  const { packageFilter } = parseArgs();
  const manifest = readManifest();

  if (!existsSync(DIGESTS_DIR)) {
    log.info("No digests directory found — nothing to replay.");
    return;
  }

  if (!existsSync(REPLAYS_DIR)) mkdirSync(REPLAYS_DIR, { recursive: true });

  // Discover digest files
  const digestFiles = readdirSync(DIGESTS_DIR)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => ({
      packageId: f.replace(".jsonl", ""),
      filePath: path.join(DIGESTS_DIR, f),
    }));

  if (packageFilter) {
    const normalized = normId(packageFilter);
    const filtered = digestFiles.filter(
      (d) => normId(d.packageId) === normalized,
    );
    if (filtered.length === 0) {
      log.warn(`No digest file found for package ${packageFilter}`);
      return;
    }
    digestFiles.length = 0;
    digestFiles.push(...filtered);
  }

  const cursors = loadCursors();
  let totalProcessed = 0;
  let totalErrors = 0;

  for (const { packageId, filePath } of digestFiles) {
    const cursor = cursors[packageId] ?? 0;
    const entries = readDigestFile(filePath, cursor);

    if (entries.length === 0) {
      log.debug(`No new digests for package ${packageId}`);
      continue;
    }

    log.info(
      `Processing ${entries.length} digests for package ${packageId} (cursor=${cursor})`,
    );

    const replayFile = path.join(REPLAYS_DIR, `${packageId}.jsonl`);

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      log.debug(`Replaying digest ${entry.digest} (${i + 1}/${entries.length})`);

      const result = await processDigest(entry, manifest);
      appendFileSync(replayFile, JSON.stringify(result) + "\n");

      if (result.error && result.error.startsWith("replay_error")) {
        totalErrors++;
        log.warn(`Error replaying ${entry.digest}: ${result.error}`);
      }

      totalProcessed++;

      // Update cursor after each successful append
      cursors[packageId] = cursor + i + 1;
      saveCursors(cursors);

      // Rate limit delay
      if (i < entries.length - 1) {
        await new Promise((r) => setTimeout(r, BATCH_DELAY_MS));
      }
    }

    log.info(
      `Finished package ${packageId}: ${entries.length} digests replayed`,
    );
  }

  log.info(
    `Replay complete: ${totalProcessed} processed, ${totalErrors} errors`,
  );
}

main().catch((err) => {
  log.error(`Fatal error: ${err.message}`, { stack: err.stack });
  process.exit(1);
});
