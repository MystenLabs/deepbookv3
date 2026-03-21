import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";

import { RPC_URL } from "./env.js";
import {
  type ActionName,
  DIGESTS_PATH,
  RESULTS_PATH,
  type DigestEntry,
  type DigestsFile,
  type MintAnalysisRow,
  type ResultsFile,
  type TxMetricRow,
  readJson,
  ts,
  writeJson,
} from "./shared.js";

const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
const MIST_PER_SUI = 1_000_000_000;
const BATCH_SIZE = 50;

function mistToSui(value: number): number {
  return value / MIST_PER_SUI;
}

function toNumber(value: string | number | null | undefined): number {
  if (value == null) return 0;
  return Number(value);
}

function summarizeMetricRows(rows: TxMetricRow[]) {
  const gasValues = rows.map((row) => row.gasTotal);
  const wallValues = rows.map((row) => row.wallMs);
  const computationValues = rows.map((row) => row.computationCost);
  const storageValues = rows.map((row) => row.storageCost);
  const rebateValues = rows.map((row) => row.storageRebate);

  const avg = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const min = (values: number[]) => Math.min(...values);
  const max = (values: number[]) => Math.max(...values);

  return {
    count: rows.length,
    gas: {
      avg: avg(gasValues),
      min: min(gasValues),
      max: max(gasValues),
      avgSui: mistToSui(avg(gasValues)),
      minSui: mistToSui(min(gasValues)),
      maxSui: mistToSui(max(gasValues)),
    },
    wallMs: {
      avg: avg(wallValues),
      min: min(wallValues),
      max: max(wallValues),
    },
    computationCost: {
      avg: avg(computationValues),
      min: min(computationValues),
      max: max(computationValues),
      avgSui: mistToSui(avg(computationValues)),
    },
    storageCost: {
      avg: avg(storageValues),
      min: min(storageValues),
      max: max(storageValues),
      avgSui: mistToSui(avg(storageValues)),
    },
    storageRebate: {
      avg: avg(rebateValues),
      min: min(rebateValues),
      max: max(rebateValues),
      avgSui: mistToSui(avg(rebateValues)),
    },
  };
}

function buildTxMetricRow(entry: DigestEntry, tx: any): TxMetricRow {
  const effects = tx.effects;
  const computationCost = toNumber(effects?.gasUsed?.computationCost);
  const storageCost = toNumber(effects?.gasUsed?.storageCost);
  const storageRebate = toNumber(effects?.gasUsed?.storageRebate);
  const gasTotal = computationCost + storageCost - storageRebate;

  return {
    index: entry.index,
    action: entry.action as ActionName,
    digest: entry.digest,
    wallMs: entry.wallMs,
    computationCost,
    computationCostSui: mistToSui(computationCost),
    storageCost,
    storageCostSui: mistToSui(storageCost),
    storageRebate,
    storageRebateSui: mistToSui(storageRebate),
    gasTotal,
    gasTotalSui: mistToSui(gasTotal),
    timestampMs: tx.timestampMs ?? null,
  };
}

function requirePredictMutation(tx: any, predictId: string): { previousVersion: string; version: string } {
  const change = (tx.objectChanges ?? []).find(
    (entry: any) =>
      entry.objectId === predictId &&
      entry.type === "mutated"
  );

  if (!change) {
    throw new Error(`Predict mutation not found in transaction ${tx.digest}`);
  }

  return {
    previousVersion: String(change.previousVersion),
    version: String(change.version),
  };
}

async function readPredictVaultAtVersion(predictId: string, version: string) {
  const object = await client.tryGetPastObject({
    id: predictId,
    version: Number(version),
    options: { showContent: true },
  });

  if ((object as any).status !== "VersionFound") {
    throw new Error(`Failed to load predict ${predictId} at version ${version}: ${JSON.stringify(object)}`);
  }

  const details = (object as any).details;
  const fields = details.content?.fields;
  const vaultFields = fields?.vault?.fields;

  return {
    version: String(details.version),
    vaultBalance: String(vaultFields?.balance ?? "0"),
    vaultTotalMtm: String(vaultFields?.total_mtm ?? "0"),
  };
}

async function buildMintAnalysisRow(
  entry: DigestEntry,
  tx: any,
  predictId: string,
  metricRow: TxMetricRow,
  mintIndex: number
): Promise<MintAnalysisRow> {
  const mintEvent = (tx.events ?? []).find((event: any) => event.type?.includes("PositionMinted"));
  const predictMutation = requirePredictMutation(tx, predictId);
  const [beforeState, afterState] = await Promise.all([
    readPredictVaultAtVersion(predictId, predictMutation.previousVersion),
    readPredictVaultAtVersion(predictId, predictMutation.version),
  ]);

  return {
    ...metricRow,
    mintIndex,
    strike: entry.strike ?? "0",
    isUp: entry.isUp ?? false,
    quantity: entry.quantity ?? "0",
    cost: mintEvent?.parsedJson?.cost ?? null,
    askPrice: mintEvent?.parsedJson?.ask_price ?? null,
    predictVersionBefore: beforeState.version,
    predictVersionAfter: afterState.version,
    vaultBalanceBefore: beforeState.vaultBalance,
    vaultBalanceAfter: afterState.vaultBalance,
    vaultBalanceDelta: String(BigInt(afterState.vaultBalance) - BigInt(beforeState.vaultBalance)),
    vaultTotalMtmBefore: beforeState.vaultTotalMtm,
    vaultTotalMtmAfter: afterState.vaultTotalMtm,
    vaultTotalMtmDelta: String(BigInt(afterState.vaultTotalMtm) - BigInt(beforeState.vaultTotalMtm)),
  };
}

async function fetchMetricBatch(batch: DigestEntry[]) {
  return client.multiGetTransactionBlocks({
    digests: batch.map((entry) => entry.digest),
    options: {
      showEffects: true,
    },
  });
}

async function fetchMintBatch(batch: DigestEntry[]) {
  return client.multiGetTransactionBlocks({
    digests: batch.map((entry) => entry.digest),
    options: {
      showEffects: true,
      showEvents: true,
      showObjectChanges: true,
    },
  });
}

async function run() {
  const data = readJson<DigestsFile>(DIGESTS_PATH);
  console.log(`[${ts()}] Loaded ${data.digests.length} digests\n`);

  const txRows: TxMetricRow[] = [];
  const mintRows: MintAnalysisRow[] = [];
  const txMetricByDigest = new Map<string, TxMetricRow>();
  const mintIndexByDigest = new Map(
    data.digests
      .filter((entry) => entry.action === "mint")
      .map((entry, index) => [entry.digest, index + 1])
  );

  console.log(`[${ts()}] --- Fetching transaction gas details ---`);
  for (let i = 0; i < data.digests.length; i += BATCH_SIZE) {
    const batch = data.digests.slice(i, i + BATCH_SIZE);
    const txResults = await fetchMetricBatch(batch);
    for (let j = 0; j < batch.length; j++) {
      const entry = batch[j];
      const tx = txResults[j] as any;
      const metricRow = buildTxMetricRow(entry, tx);
      txRows.push(metricRow);
      txMetricByDigest.set(entry.digest, metricRow);
    }
    process.stdout.write(`[${ts()}]   Fetched ${Math.min(i + BATCH_SIZE, data.digests.length)}/${data.digests.length}\n`);
  }

  const mintDigests = data.digests.filter((entry) => entry.action === "mint");
  console.log(`\n[${ts()}] --- Fetching mint details ---`);
  for (let i = 0; i < mintDigests.length; i += BATCH_SIZE) {
    const batch = mintDigests.slice(i, i + BATCH_SIZE);
    const txResults = await fetchMintBatch(batch);

    const pendingMintRows: Promise<MintAnalysisRow>[] = [];
    for (let j = 0; j < batch.length; j++) {
      const entry = batch[j];
      const tx = txResults[j] as any;
      const metricRow = txMetricByDigest.get(entry.digest);
      if (!metricRow) {
        throw new Error(`Missing tx metric row for digest ${entry.digest}`);
      }
      pendingMintRows.push(
        buildMintAnalysisRow(
          entry,
          tx,
          data.predictId,
          metricRow,
          mintIndexByDigest.get(entry.digest) ?? 0
        )
      );
    }

    mintRows.push(...(await Promise.all(pendingMintRows)));
    process.stdout.write(`[${ts()}]   Enriched ${Math.min(i + BATCH_SIZE, mintDigests.length)}/${mintDigests.length} mints\n`);
  }

  console.log(`\n[${ts()}] --- Fetching final vault state ---`);
  const predictObj = await client.getObject({
    id: data.predictId,
    options: { showContent: true },
  });
  const predictFields = (predictObj.data?.content as any)?.fields;
  const vaultFields = predictFields?.vault?.fields;
  const vaultState = {
    balance: String(vaultFields?.balance ?? "0"),
    totalMtm: String(vaultFields?.total_mtm ?? "0"),
  };
  console.log(`[${ts()}]   Vault balance: ${vaultState.balance}`);
  console.log(`[${ts()}]   Vault MTM: ${vaultState.totalMtm}`);

  const rowsByAction = {
    update_prices: txRows.filter((row) => row.action === "update_prices"),
    update_svi: txRows.filter((row) => row.action === "update_svi"),
    mint: txRows.filter((row) => row.action === "mint"),
  };

  const output: ResultsFile = {
    summary: {
      totalTxs: txRows.length,
      byAction: {
        update_prices: summarizeMetricRows(rowsByAction.update_prices),
        update_svi: summarizeMetricRows(rowsByAction.update_svi),
        mint: summarizeMetricRows(rowsByAction.mint),
      },
      vault: vaultState,
    },
    mints: mintRows,
  };

  writeJson(RESULTS_PATH, output);
  console.log(`\n[${ts()}] --- Results written to ${RESULTS_PATH} ---`);

  console.log(`\n[${ts()}] === SUMMARY ===`);
  console.log(`  update_prices: count=${output.summary.byAction.update_prices.count} avgGas=${output.summary.byAction.update_prices.gas.avgSui.toFixed(9)} SUI`);
  console.log(`  update_svi:    count=${output.summary.byAction.update_svi.count} avgGas=${output.summary.byAction.update_svi.gas.avgSui.toFixed(9)} SUI`);
  console.log(`  mint:          count=${output.summary.byAction.mint.count} avgGas=${output.summary.byAction.mint.gas.avgSui.toFixed(9)} SUI`);
  console.log(`  Mint wall:     avg=${output.summary.byAction.mint.wallMs.avg.toFixed(0)}ms min=${output.summary.byAction.mint.wallMs.min.toFixed(0)}ms max=${output.summary.byAction.mint.wallMs.max.toFixed(0)}ms`);
  console.log(`  Vault: balance=${vaultState.balance} mtm=${vaultState.totalMtm}`);
}

run().catch((error) => {
  console.error("Analysis failed:", error);
  process.exit(1);
});
