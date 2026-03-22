import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "fs";
import path from "path";
import { ANALYSIS_DIR, REPLAYS_DIR, DIGESTS_DIR } from "./config.js";
import { readManifest } from "./manifest.js";
import type { PackageEntry, ReplayResult, DigestEntry } from "./types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readJsonl<T>(filePath: string): T[] {
  if (!existsSync(filePath)) return [];
  return readFileSync(filePath, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as T);
}

function percentile(sorted: number[], p: number): number {
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

function mean(vals: number[]): number {
  if (vals.length === 0) return 0;
  return vals.reduce((a, b) => a + b, 0) / vals.length;
}

// ---------------------------------------------------------------------------
// Per-package analysis
// ---------------------------------------------------------------------------

interface PackageSummary {
  label: string;
  commit: string;
  package_id: string;
  total_mints: number;
  successful_mints: number;
  failed_mints: number;
  failure_rate: number;
  gas: {
    mean: number;
    p50: number;
    p95: number;
    p99: number;
    min: number;
    max: number;
  };
  errors: Record<string, number>;
  vault: {
    latest_balance: number;
    latest_total_mtm: number;
  };
}

function analyzePackage(
  pkg: PackageEntry,
  replays: ReplayResult[],
  digests: DigestEntry[],
): PackageSummary {
  const successful = replays.filter((r) => r.status === "success");
  const failed = replays.filter((r) => r.status === "failure");

  // Gas values from successful replays
  const gasValues = successful
    .map((r) => r.gas.total)
    .sort((a, b) => a - b);

  // Error counts
  const errors: Record<string, number> = {};
  for (const r of failed) {
    const key = r.error ?? "unknown";
    // Try to extract a known error name (EFoo pattern)
    const match = key.match(/E[A-Z][A-Za-z]+/);
    const label = match ? match[0] : "other";
    errors[label] = (errors[label] ?? 0) + 1;
  }

  // Latest vault snapshot (by ts)
  const vaultSnapshots = replays
    .filter((r) => r.vault !== null)
    .sort((a, b) => a.ts - b.ts);
  const latestVault = vaultSnapshots.length > 0
    ? vaultSnapshots[vaultSnapshots.length - 1].vault!
    : { balance: 0, total_mtm: 0 };

  const total = replays.length || digests.length;

  return {
    label: pkg.label,
    commit: pkg.commit,
    package_id: pkg.package_id,
    total_mints: total,
    successful_mints: successful.length,
    failed_mints: failed.length,
    failure_rate: total > 0 ? failed.length / total : 0,
    gas: {
      mean: Math.round(mean(gasValues)),
      p50: gasValues.length > 0 ? percentile(gasValues, 50) : 0,
      p95: gasValues.length > 0 ? percentile(gasValues, 95) : 0,
      p99: gasValues.length > 0 ? percentile(gasValues, 99) : 0,
      min: gasValues.length > 0 ? gasValues[0] : 0,
      max: gasValues.length > 0 ? gasValues[gasValues.length - 1] : 0,
    },
    errors,
    vault: {
      latest_balance: latestVault.balance,
      latest_total_mtm: latestVault.total_mtm,
    },
  };
}

// ---------------------------------------------------------------------------
// CSV writers
// ---------------------------------------------------------------------------

function writeGasPerMintCsv(
  summaries: PackageSummary[],
  allReplays: Map<string, ReplayResult[]>,
): void {
  const rows: string[] = ["package_id,label,digest,gas_total"];
  for (const s of summaries) {
    const replays = allReplays.get(s.package_id) ?? [];
    for (const r of replays) {
      if (r.status === "success") {
        rows.push(`${s.package_id},${s.label},${r.digest},${r.gas.total}`);
      }
    }
  }
  writeFileSync(path.join(ANALYSIS_DIR, "gas_per_mint.csv"), rows.join("\n") + "\n");
}

function writeFailureRatesCsv(summaries: PackageSummary[]): void {
  const rows: string[] = ["package_id,label,error_type,count"];
  for (const s of summaries) {
    for (const [errType, count] of Object.entries(s.errors)) {
      rows.push(`${s.package_id},${s.label},${errType},${count}`);
    }
  }
  writeFileSync(path.join(ANALYSIS_DIR, "failure_rates.csv"), rows.join("\n") + "\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main(): void {
  mkdirSync(ANALYSIS_DIR, { recursive: true });

  const packages = readManifest();
  if (packages.length === 0) {
    console.log("No packages found in manifest. Nothing to analyze.");
    return;
  }

  // Collect all replay and digest files
  const replayFiles = existsSync(REPLAYS_DIR) ? readdirSync(REPLAYS_DIR).filter((f) => f.endsWith(".jsonl")) : [];
  const digestFiles = existsSync(DIGESTS_DIR) ? readdirSync(DIGESTS_DIR).filter((f) => f.endsWith(".jsonl")) : [];

  const allReplays = new Map<string, ReplayResult[]>();
  const allDigests = new Map<string, DigestEntry[]>();

  for (const f of replayFiles) {
    const pkgId = f.replace(".jsonl", "");
    allReplays.set(pkgId, readJsonl<ReplayResult>(path.join(REPLAYS_DIR, f)));
  }

  for (const f of digestFiles) {
    const pkgId = f.replace(".jsonl", "");
    allDigests.set(pkgId, readJsonl<DigestEntry>(path.join(DIGESTS_DIR, f)));
  }

  // Analyze each package
  const summaries: PackageSummary[] = [];
  for (const pkg of packages) {
    const replays = allReplays.get(pkg.package_id) ?? [];
    const digests = allDigests.get(pkg.package_id) ?? [];
    if (replays.length === 0 && digests.length === 0) continue;
    summaries.push(analyzePackage(pkg, replays, digests));
  }

  if (summaries.length === 0) {
    console.log("No replay or digest data found for any package. Nothing to analyze.");
    return;
  }

  // Write summary JSON
  const summary = {
    generated_at: new Date().toISOString(),
    packages: summaries,
  };
  writeFileSync(
    path.join(ANALYSIS_DIR, "summary.json"),
    JSON.stringify(summary, null, 2) + "\n",
  );

  // Write CSVs
  writeGasPerMintCsv(summaries, allReplays);
  writeFailureRatesCsv(summaries);

  console.log(`Analysis complete. ${summaries.length} package(s) analyzed.`);
  console.log(`  -> ${ANALYSIS_DIR}/summary.json`);
  console.log(`  -> ${ANALYSIS_DIR}/gas_per_mint.csv`);
  console.log(`  -> ${ANALYSIS_DIR}/failure_rates.csv`);
}

main();
