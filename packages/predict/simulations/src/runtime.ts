import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";

import {
  ADMIN_CAP_ID,
  DUSDC_PACKAGE_ID,
  PACKAGE_ID,
  PLP_TREASURY_CAP_ID,
  REGISTRY_ID,
  RPC_URL,
  TREASURY_CAP_ID,
  getSigner,
} from "./env.js";

export interface GasUsage {
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  gasTotal: number;
}

const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const CLOCK_ID = "0x6";
const SETUP_RESPONSE_OPTIONS = {
  showEffects: true,
  showEvents: true,
  showObjectChanges: true,
} as const;
const EXECUTION_RESPONSE_OPTIONS = {
  showEffects: true,
} as const;

export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();

function isSuccessStatus(status: any): boolean {
  return status?.status === "success" || status?.success === true;
}

function formatStatusError(status: any, fallback: string): string {
  return status?.error ?? fallback;
}

function gasSummaryFromEffects(effects: any): GasUsage {
  const gasUsed = effects?.gasUsed ?? {};
  const computationCost = Number(gasUsed.computationCost ?? 0);
  const storageCost = Number(gasUsed.storageCost ?? 0);
  const storageRebate = Number(gasUsed.storageRebate ?? 0);

  return {
    computationCost,
    storageCost,
    storageRebate,
    gasTotal: computationCost + storageCost - storageRebate,
  };
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

export function target(module: string, fn: string): `${string}::${string}::${string}` {
  return `${PACKAGE_ID}::${module}::${fn}`;
}

export function createPredictTx(): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_predict"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(REGISTRY_ID), tx.object(ADMIN_CAP_ID), tx.object(PLP_TREASURY_CAP_ID)],
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
  predictId: string;
  oracleCapId: string;
  underlyingAsset: string;
  expiry: bigint;
  minStrike: bigint;
  tickSize: bigint;
}): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_oracle"),
    typeArguments: [DUSDC_TYPE],
    arguments: [
      tx.object(REGISTRY_ID),
      tx.object(params.predictId),
      tx.object(ADMIN_CAP_ID),
      tx.object(params.oracleCapId),
      tx.pure.string(params.underlyingAsset),
      tx.pure.u64(params.expiry),
      tx.pure.u64(params.minStrike),
      tx.pure.u64(params.tickSize),
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

export function activateOracleTx(oracleId: string, oracleCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("oracle", "activate"),
    arguments: [tx.object(oracleId), tx.object(oracleCapId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export function updatePricesTx(oracleId: string, oracleCapId: string, spot: bigint, forward: bigint): Transaction {
  const tx = new Transaction();
  const priceData = tx.moveCall({
    target: target("oracle", "new_price_data"),
    arguments: [tx.pure.u64(spot), tx.pure.u64(forward)],
  });
  tx.moveCall({
    target: target("oracle", "update_prices"),
    arguments: [tx.object(oracleId), tx.object(oracleCapId), priceData, tx.object(CLOCK_ID)],
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
  riskFreeRate: bigint
): Transaction {
  const tx = new Transaction();
  const rho = tx.moveCall({
    target: target("i64", "from_parts"),
    arguments: [tx.pure.u64(svi.rho), tx.pure.bool(svi.rhoNegative)],
  });
  const m = tx.moveCall({
    target: target("i64", "from_parts"),
    arguments: [tx.pure.u64(svi.m), tx.pure.bool(svi.mNegative)],
  });
  const sviParams = tx.moveCall({
    target: target("oracle", "new_svi_params"),
    arguments: [
      tx.pure.u64(svi.a),
      tx.pure.u64(svi.b),
      rho,
      m,
      tx.pure.u64(svi.sigma),
    ],
  });
  tx.moveCall({
    target: target("oracle", "update_svi"),
    arguments: [
      tx.object(oracleId),
      tx.object(oracleCapId),
      sviParams,
      tx.pure.u64(riskFreeRate),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function supplyTx(predictId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const [dusdc] = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
  });
  const [plpCoin] = tx.moveCall({
    target: target("predict", "supply"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(predictId), dusdc],
  });
  tx.transferObjects([plpCoin], tx.pure.address(address));
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
}): Transaction {
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
      tx.object(params.predictId),
      tx.object(params.managerId),
      tx.object(params.oracleId),
      key,
      tx.pure.u64(params.quantity),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function refreshOracleAndMintTx(params: {
  predictId: string;
  managerId: string;
  oracleId: string;
  oracleCapId: string;
  expiry: bigint;
  strike: bigint;
  isUp: boolean;
  quantity: bigint;
  spot: bigint;
  forward: bigint;
  svi: {
    a: bigint;
    b: bigint;
    rho: bigint;
    rhoNegative: boolean;
    m: bigint;
    mNegative: boolean;
    sigma: bigint;
  };
  riskFreeRate: bigint;
}): Transaction {
  const tx = new Transaction();
  const priceData = tx.moveCall({
    target: target("oracle", "new_price_data"),
    arguments: [tx.pure.u64(params.spot), tx.pure.u64(params.forward)],
  });
  tx.moveCall({
    target: target("oracle", "update_prices"),
    arguments: [tx.object(params.oracleId), tx.object(params.oracleCapId), priceData, tx.object(CLOCK_ID)],
  });

  const rho = tx.moveCall({
    target: target("i64", "from_parts"),
    arguments: [tx.pure.u64(params.svi.rho), tx.pure.bool(params.svi.rhoNegative)],
  });
  const m = tx.moveCall({
    target: target("i64", "from_parts"),
    arguments: [tx.pure.u64(params.svi.m), tx.pure.bool(params.svi.mNegative)],
  });
  const sviParams = tx.moveCall({
    target: target("oracle", "new_svi_params"),
    arguments: [
      tx.pure.u64(params.svi.a),
      tx.pure.u64(params.svi.b),
      rho,
      m,
      tx.pure.u64(params.svi.sigma),
    ],
  });
  tx.moveCall({
    target: target("oracle", "update_svi"),
    arguments: [
      tx.object(params.oracleId),
      tx.object(params.oracleCapId),
      sviParams,
      tx.pure.u64(params.riskFreeRate),
      tx.object(CLOCK_ID),
    ],
  });

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
      tx.object(params.predictId),
      tx.object(params.managerId),
      tx.object(params.oracleId),
      key,
      tx.pure.u64(params.quantity),
      tx.object(CLOCK_ID),
    ],
  });

  return tx;
}

export async function executeAndWait(
  tx: Transaction,
  label = "transaction",
  gasBudget = 500_000_000n
): Promise<any> {
  tx.setSender(address);
  tx.setGasBudget(gasBudget);

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

const EXECUTE_MAX_ATTEMPTS = 5;
const EXECUTE_RETRY_DELAY_MS = 1000;

export async function execute(buildTx: Transaction | (() => Transaction), label = "transaction"): Promise<GasUsage> {
  let lastError: unknown;
  for (let attempt = 0; attempt < EXECUTE_MAX_ATTEMPTS; attempt++) {
    try {
      // Build a fresh transaction on each attempt so object versions are re-resolved.
      const tx = typeof buildTx === "function" ? buildTx() : buildTx;
      tx.setSender(address);
      tx.setGasBudget(500_000_000n);

      const raw: any = await client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: EXECUTION_RESPONSE_OPTIONS,
      });

      const status = raw.effects?.status;
      if (!isSuccessStatus(status)) {
        throw new Error(`${label} failed: ${formatStatusError(status, JSON.stringify(raw).slice(0, 300))}`);
      }

      const settled = await getTransactionBlockWithRetry(raw.digest);
      return gasSummaryFromEffects(settled.effects ?? raw.effects);
    } catch (error) {
      lastError = error;
      const msg = String(error);
      // Retry on transient object version / input errors.
      if (msg.includes("Object ID") || msg.includes("TransactionExecutionClientError")) {
        if (attempt < EXECUTE_MAX_ATTEMPTS - 1) {
          const delay = EXECUTE_RETRY_DELAY_MS * (attempt + 1);
          process.stdout.write(`[retry] ${label} attempt ${attempt + 1} failed, retrying in ${delay}ms...\n`);
          await new Promise((r) => setTimeout(r, delay));
          continue;
        }
      }
      throw error;
    }
  }
  throw lastError;
}
