import { readFileSync, writeFileSync, renameSync, mkdirSync, rmSync, existsSync } from "fs";
import path from "path";
import { MANIFEST_PATH, MANIFEST_LOCK_PATH } from "./config.js";
import type { PackageEntry } from "./types.js";

// Cross-process manifest lock using atomic mkdir
const LOCK_TIMEOUT_MS = 5000;
const LOCK_SPIN_MS = 50;
const LOCK_STALE_MS = 30000;

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

export async function acquireManifestLock(): Promise<void> {
  const ownerFile = path.join(MANIFEST_LOCK_PATH, "owner.json");
  const start = Date.now();

  while (true) {
    try {
      mkdirSync(MANIFEST_LOCK_PATH);
      // Acquired — write owner info
      writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, ts: Date.now() }));
      return;
    } catch (e: any) {
      if (e.code !== "EEXIST") throw e;
    }

    // Lock exists — check timeout
    if (Date.now() - start > LOCK_TIMEOUT_MS) {
      // Try to read owner and check if stale
      try {
        const owner: LockOwner = JSON.parse(readFileSync(ownerFile, "utf8"));
        if (!isProcessAlive(owner.pid)) {
          // Dead PID — force remove and retry
          rmSync(MANIFEST_LOCK_PATH, { recursive: true });
          continue;
        }
        if (Date.now() - owner.ts > LOCK_STALE_MS) {
          throw new Error(
            `Manifest lock held by PID ${owner.pid} for ${Math.round((Date.now() - owner.ts) / 1000)}s — investigate`
          );
        }
      } catch (readErr: any) {
        if (readErr.code === "ENOENT") {
          // Owner file gone, lock dir might be stale — force remove
          try { rmSync(MANIFEST_LOCK_PATH, { recursive: true }); } catch {}
          continue;
        }
        if (readErr.message?.includes("investigate")) throw readErr;
      }
    }

    await new Promise((r) => setTimeout(r, LOCK_SPIN_MS));
  }
}

export function releaseManifestLock(): void {
  try {
    rmSync(MANIFEST_LOCK_PATH, { recursive: true });
  } catch {}
}

// Read manifest — returns empty array if file doesn't exist
export function readManifest(): PackageEntry[] {
  if (!existsSync(MANIFEST_PATH)) return [];
  return JSON.parse(readFileSync(MANIFEST_PATH, "utf8")) as PackageEntry[];
}

// Atomic write — write to tmp file, then rename
function atomicWrite(filePath: string, data: string): void {
  const tmp = filePath + ".tmp." + process.pid;
  writeFileSync(tmp, data);
  renameSync(tmp, filePath);
}

// Write manifest atomically (caller must hold lock)
export function writeManifest(entries: PackageEntry[]): void {
  atomicWrite(MANIFEST_PATH, JSON.stringify(entries, null, 2));
}

// Read-modify-write with lock
export async function withManifestLock<T>(fn: (entries: PackageEntry[]) => { entries: PackageEntry[]; result: T }): Promise<T> {
  await acquireManifestLock();
  try {
    const current = readManifest();
    const { entries, result } = fn(current);
    writeManifest(entries);
    return result;
  } finally {
    releaseManifestLock();
  }
}
