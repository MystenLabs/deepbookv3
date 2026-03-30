import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";

import {
  ADMIN_CAP_ID,
  DUSDC_PACKAGE_ID,
  PACKAGE_ID,
  REGISTRY_ID,
  RPC_URL,
  TREASURY_CAP_ID,
  getSigner,
} from "./env.js";

const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const CLOCK_ID = "0x6";

export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();

export interface OwnedRef {
  kind: "owned";
  objectId: string;
  version: string;
  digest: string;
}

export interface SharedRef {
  kind: "shared";
  objectId: string;
  initialSharedVersion: string;
}

export type CachedRef = OwnedRef | SharedRef;

export interface FastExecutorState {
  refs: Record<string, CachedRef>;
  gasCoin: { objectId: string; version: string; digest: string };
  gasPrice: string;
}

type RefMode = "standard" | "fast";

const cache = new Map<string, CachedRef>();
let gasCoin: { objectId: string; version: string; digest: string } | null = null;
let gasPrice = "1000";
const SETUP_RESPONSE_OPTIONS = {
  showEffects: true,
  showEvents: true,
  showObjectChanges: true,
} as const;
const FAST_RESPONSE_OPTIONS = {
  showEffects: true,
  showObjectChanges: true,
} as const;

function normId(id: string): string {
  return `0x${id.replace(/^0x/, "").padStart(64, "0")}`;
}

function isSuccessStatus(status: any): boolean {
  return status?.status === "success" || status?.success === true;
}

function formatStatusError(status: any, fallback: string): string {
  return status?.error ?? fallback;
}

function extractGasCoinRef(effects: any): { objectId: string; version: string; digest: string } | null {
  const gasObject = effects?.gasObject;
  if (!gasObject) return null;

  const objectId = gasObject.objectId ?? gasObject.reference?.objectId;
  const version = gasObject.outputVersion ?? gasObject.reference?.version ?? gasObject.version;
  const digest = gasObject.outputDigest ?? gasObject.reference?.digest ?? gasObject.digest;

  if (!objectId || !version || !digest) {
    return null;
  }

  return {
    objectId: normId(objectId),
    version: String(version),
    digest,
  };
}

function resolveObject(tx: Transaction, id: string, mutable = true, mode: RefMode = "standard") {
  if (mode === "standard") {
    return tx.object(id);
  }

  const entry = cache.get(normId(id));
  if (!entry) {
    throw new Error(`Object ${id} not found in fast executor cache`);
  }

  if (entry.kind === "shared") {
    return tx.sharedObjectRef({
      objectId: entry.objectId,
      initialSharedVersion: entry.initialSharedVersion,
      mutable,
    });
  }

  return tx.objectRef({
    objectId: entry.objectId,
    version: entry.version,
    digest: entry.digest,
  });
}

export function target(module: string, fn: string): `${string}::${string}::${string}` {
  return `${PACKAGE_ID}::${module}::${fn}`;
}

export function createPredictTx(): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_predict"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(REGISTRY_ID), tx.object(ADMIN_CAP_ID)],
  });
  return tx;
}

export function createOracleCapTx(recipient: string): Transaction {
  const tx = new Transaction();
  const cap = tx.moveCall({
    target: target("registry", "create_oracle_cap"),
    arguments: [tx.object(ADMIN_CAP_ID)],
  });
  tx.transferObjects([cap], tx.pure.address(recipient));
  return tx;
}

export function createOracleTx(params: {
  oracleCapId: string;
  underlyingAsset: string;
  expiry: bigint;
}): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_oracle"),
    arguments: [
      tx.object(REGISTRY_ID),
      tx.object(ADMIN_CAP_ID),
      tx.object(params.oracleCapId),
      tx.pure.string(params.underlyingAsset),
      tx.pure.u64(params.expiry),
    ],
  });
  return tx;
}

export function registerOracleCapTx(oracleId: string, oracleCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "register_oracle_cap"),
    arguments: [tx.object(oracleId), tx.object(ADMIN_CAP_ID), tx.object(oracleCapId)],
  });
  return tx;
}

export function activateOracleTx(oracleId: string, oracleCapId: string, mode: RefMode = "standard"): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("oracle", "activate"),
    arguments: [
      resolveObject(tx, oracleId, true, mode),
      resolveObject(tx, oracleCapId, true, mode),
      resolveObject(tx, CLOCK_ID, false, mode),
    ],
  });
  return tx;
}

export function updatePricesTx(
  oracleId: string,
  oracleCapId: string,
  spot: bigint,
  forward: bigint,
  mode: RefMode = "standard"
): Transaction {
  const tx = new Transaction();
  const priceData = tx.moveCall({
    target: target("oracle", "new_price_data"),
    arguments: [tx.pure.u64(spot), tx.pure.u64(forward)],
  });
  tx.moveCall({
    target: target("oracle", "update_prices"),
    arguments: [
      resolveObject(tx, oracleId, true, mode),
      resolveObject(tx, oracleCapId, true, mode),
      priceData,
      resolveObject(tx, CLOCK_ID, false, mode),
    ],
  });
  return tx;
}

export function updateSviTx(
  oracleId: string,
  oracleCapId: string,
  svi: {
    a: bigint;
    b: bigint;
    rho: bigint;
    rhoNegative: boolean;
    m: bigint;
    mNegative: boolean;
    sigma: bigint;
  },
  riskFreeRate: bigint,
  mode: RefMode = "standard"
): Transaction {
  const tx = new Transaction();
  const sviParams = tx.moveCall({
    target: target("oracle", "new_svi_params"),
    arguments: [
      tx.pure.u64(svi.a),
      tx.pure.u64(svi.b),
      tx.pure.u64(svi.rho),
      tx.pure.bool(svi.rhoNegative),
      tx.pure.u64(svi.m),
      tx.pure.bool(svi.mNegative),
      tx.pure.u64(svi.sigma),
    ],
  });
  tx.moveCall({
    target: target("oracle", "update_svi"),
    arguments: [
      resolveObject(tx, oracleId, true, mode),
      resolveObject(tx, oracleCapId, true, mode),
      sviParams,
      tx.pure.u64(riskFreeRate),
      resolveObject(tx, CLOCK_ID, false, mode),
    ],
  });
  return tx;
}

export function supplyTx(predictId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const [coin] = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
  });
  tx.moveCall({
    target: target("predict", "supply"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(predictId), coin],
  });
  return tx;
}

export function createManagerTx(): Transaction {
  const tx = new Transaction();
  tx.moveCall({ target: target("predict", "create_manager") });
  return tx;
}

export function depositToManagerTx(managerId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const [coin] = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
  });
  tx.moveCall({
    target: target("predict_manager", "deposit"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(managerId), coin],
  });
  return tx;
}

export function mintTx(params: {
  predictId: string;
  managerId: string;
  oracleId: string;
  expiry: bigint;
  strike: bigint;
  isUp: boolean;
  quantity: bigint;
}, mode: RefMode = "standard"): Transaction {
  const tx = new Transaction();
  const key = tx.moveCall({
    target: target("market_key", "new"),
    arguments: [
      tx.pure.id(params.oracleId),
      tx.pure.u64(params.expiry),
      tx.pure.u64(params.strike),
      tx.pure.bool(params.isUp),
    ],
  });
  tx.moveCall({
    target: target("predict", "mint"),
    typeArguments: [DUSDC_TYPE],
    arguments: [
      resolveObject(tx, params.predictId, true, mode),
      resolveObject(tx, params.managerId, true, mode),
      resolveObject(tx, params.oracleId, true, mode),
      key,
      tx.pure.u64(params.quantity),
      resolveObject(tx, CLOCK_ID, false, mode),
    ],
  });
  return tx;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function collectCachedRefs(objectIds: string[]): Promise<Record<string, CachedRef>> {
  const objects = await client.multiGetObjects({
    ids: objectIds,
    options: { showOwner: true },
  });

  const refs: Record<string, CachedRef> = {};
  for (const object of objects as any[]) {
    const data = object.data;
    if (!data) continue;

    if (data.owner?.Shared) {
      refs[data.objectId] = {
        kind: "shared",
        objectId: data.objectId,
        initialSharedVersion: String(data.owner.Shared.initial_shared_version),
      };
      continue;
    }

    refs[data.objectId] = {
      kind: "owned",
      objectId: data.objectId,
      version: String(data.version),
      digest: data.digest,
    };
  }

  return refs;
}

async function pickGasCoin(): Promise<{ objectId: string; version: string; digest: string }> {
  const coins = await client.getCoins({ owner: address, coinType: "0x2::sui::SUI" });
  const sortedCoins = [...(coins as any).data].sort((left: any, right: any) =>
    BigInt(right.balance) > BigInt(left.balance) ? 1 : -1
  );
  const largestCoin = sortedCoins[0];
  const gasObject = await client.getObject({ id: largestCoin.coinObjectId, options: {} });
  const gasObjectData = (gasObject as any).data;

  return {
    objectId: gasObjectData.objectId,
    version: String(gasObjectData.version),
    digest: gasObjectData.digest,
  };
}

function applyEffectsToCache(effects: any): void {
  for (const change of effects?.changedObjects ?? []) {
    const entry = cache.get(normId(change.objectId));
    if (!entry || entry.kind !== "owned") {
      continue;
    }

    if (change.outputState === "ObjectWrite" && change.outputVersion && change.outputDigest) {
      entry.version = String(change.outputVersion);
      entry.digest = change.outputDigest;
      continue;
    }

    if (change.outputState === "DoesNotExist") {
      cache.delete(normId(change.objectId));
    }
  }
}

function applyObjectChangesToCache(objectChanges: any[] | null | undefined): void {
  for (const change of objectChanges ?? []) {
    const objectId = change.objectId;
    if (!objectId) {
      continue;
    }

    const entry = cache.get(normId(objectId));
    if (!entry || entry.kind !== "owned") {
      continue;
    }

    if ((change.type === "mutated" || change.type === "created" || change.type === "transferred") && change.version && change.digest) {
      entry.version = String(change.version);
      entry.digest = change.digest;
      continue;
    }

    if (change.type === "deleted" || change.type === "wrapped") {
      cache.delete(normId(objectId));
    }
  }
}

async function getTransactionBlockWithRetry(digest: string): Promise<any> {
  let lastError: unknown;

  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      return await client.getTransactionBlock({
        digest,
        options: { showEvents: true, showObjectChanges: true, showEffects: true },
      });
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }

  throw lastError;
}

export async function executeAndWait(tx: Transaction, label = "transaction"): Promise<any> {
  tx.setSender(address);
  tx.setGasBudget(500_000_000n);

  let execution: any;
  try {
    execution = await client.signAndExecuteTransaction({
      transaction: tx,
      signer,
      options: SETUP_RESPONSE_OPTIONS,
    });
  } catch (error) {
    let dryRunSummary = "";
    try {
      const bytes = await tx.build({ client });
      const dryRun = await client.dryRunTransactionBlock({ transactionBlock: bytes });
      dryRunSummary = ` dryRun=${JSON.stringify(dryRun).slice(0, 1000)}`;
    } catch (dryRunError) {
      dryRunSummary = ` dryRun_error=${String(dryRunError)}`;
    }
    throw new Error(`${label} rpc failure: ${String(error)}${dryRunSummary}`);
  }

  const status = (execution as any).effects?.status;
  if (!isSuccessStatus(status)) {
    throw new Error(`${label} failed: ${formatStatusError(status, JSON.stringify(execution).slice(0, 300))}`);
  }

  return getTransactionBlockWithRetry(execution.digest);
}

export async function buildFastExecutorState(objectIds: string[]): Promise<FastExecutorState> {
  let refs = await collectCachedRefs(objectIds);
  let selectedGasCoin = await pickGasCoin();
  let previousSnapshot = "";

  for (let attempt = 0; attempt < 20; attempt++) {
    const snapshot = JSON.stringify({ refs, gasCoin: selectedGasCoin });
    if (snapshot === previousSnapshot) break;
    previousSnapshot = snapshot;
    await sleep(250);
    refs = await collectCachedRefs(objectIds);
    selectedGasCoin = await pickGasCoin();
  }

  return {
    refs,
    gasCoin: selectedGasCoin,
    gasPrice: String(await (client as any).getReferenceGasPrice()),
  };
}

export function loadFastExecutor(state: FastExecutorState): void {
  cache.clear();
  for (const [id, ref] of Object.entries(state.refs)) {
    cache.set(normId(id), ref);
  }

  if (!cache.has(normId(CLOCK_ID))) {
    cache.set(normId(CLOCK_ID), {
      kind: "shared",
      objectId: normId(CLOCK_ID),
      initialSharedVersion: "1",
    });
  }

  gasCoin = state.gasCoin;
  gasPrice = state.gasPrice;
  console.log(`  Fast executor: ${cache.size} objects cached, gas price ${gasPrice}`);
}

export interface ExecutionResult {
  digest: string;
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  gasTotal: number;
}

export async function executeFast(tx: Transaction): Promise<ExecutionResult> {
  if (!gasCoin) {
    throw new Error("Fast executor has not been initialized");
  }

  tx.setSender(address);
  tx.setGasPrice(BigInt(gasPrice));
  tx.setGasBudget(500_000_000n);
  tx.setGasPayment([gasCoin]);

  const raw: any = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: FAST_RESPONSE_OPTIONS,
  });

  const status = raw.effects?.status;
  if (!isSuccessStatus(status)) {
    throw new Error(`Transaction failed: ${formatStatusError(status, JSON.stringify(raw).slice(0, 300))}`);
  }

  const effects = raw.effects ?? raw;
  applyObjectChangesToCache(raw.objectChanges);
  applyEffectsToCache(effects);
  gasCoin = extractGasCoinRef(effects) ?? await pickGasCoin();

  const gasUsed = effects.gasUsed ?? {};
  const computationCost = Number(gasUsed.computationCost ?? 0);
  const storageCost = Number(gasUsed.storageCost ?? 0);
  const storageRebate = Number(gasUsed.storageRebate ?? 0);

  return {
    digest: raw.digest,
    computationCost,
    storageCost,
    storageRebate,
    gasTotal: computationCost + storageCost - storageRebate,
  };
}
