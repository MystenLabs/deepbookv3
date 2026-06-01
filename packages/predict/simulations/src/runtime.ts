import { bcs } from "@mysten/sui/bcs";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { deriveObjectID } from "@mysten/sui/utils";

import {
  ADMIN_CAP_ID,
  DUSDC_CURRENCY_ID,
  DUSDC_PACKAGE_ID,
  PACKAGE_ID,
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
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

export interface ExecutionReceipt {
  digest: string;
  gas: GasUsage;
  events: any[];
  objectChanges: any[];
  effects: any;
}

const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const CLOCK_ID = "0x6";
const COIN_REGISTRY_ID = "0xc";
const NEG_INF_STRIKE = 0n;
const POS_INF_STRIKE = (1n << 64n) - 1n;
const SETUP_RESPONSE_OPTIONS = {
  showEffects: true,
  showEvents: true,
  showObjectChanges: true,
} as const;
const EXECUTION_RESPONSE_OPTIONS = {
  showEffects: true,
  showEvents: true,
  showObjectChanges: true,
} as const;

export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();
export { POOL_VAULT_ID, PROTOCOL_CONFIG_ID };

const DEFAULT_GAS_BUDGET = 1_000_000_000n;

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

let lastSourceTimestampMs = 0n;

function nextSourceTimestampMs(): bigint {
  const conservativeNow = BigInt(Date.now()) - 1_000n;
  const next = conservativeNow > lastSourceTimestampMs ? conservativeNow : lastSourceTimestampMs + 1n;
  lastSourceTimestampMs = next;
  return next;
}

interface OracleRefreshParams {
  oracleId: string;
  protocolConfigId: string;
  pythSourceId: string;
  oracleCapId: string;
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
}

interface ExpiryValuationParams {
  poolVaultId: string;
  protocolConfigId: string;
  expiryMarketId: string;
  oracleId: string;
  pythSourceId: string;
}

interface SupplyWithExpiryValuationParams extends ExpiryValuationParams {
  amount: bigint;
}

interface WithdrawWithExpiryValuationParams extends ExpiryValuationParams {
  lpCoinId: string;
}

interface MintParams {
  expiryMarketId: string;
  protocolConfigId: string;
  managerId: string;
  oracleId: string;
  pythSourceId: string;
  strike: bigint;
  isUp: boolean;
  quantity: bigint;
  leverage: bigint;
}

interface RedeemParams {
  expiryMarketId: string;
  protocolConfigId: string;
  managerId: string;
  oracleId: string;
  pythSourceId: string;
  orderId: string;
  closeQuantity: bigint;
}

function addOracleRefresh(tx: Transaction, params: OracleRefreshParams): void {
  tx.moveCall({
    target: target("market_oracle", "update_block_scholes_prices"),
    arguments: [
      tx.object(params.oracleId),
      tx.object(params.protocolConfigId),
      tx.object(params.pythSourceId),
      tx.object(params.oracleCapId),
      tx.pure.u64(params.spot),
      tx.pure.u64(params.forward),
      tx.pure.u64(nextSourceTimestampMs()),
      tx.object(CLOCK_ID),
    ],
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
    target: target("market_oracle", "new_svi_params"),
    arguments: [
      tx.pure.u64(params.svi.a),
      tx.pure.u64(params.svi.b),
      rho,
      m,
      tx.pure.u64(params.svi.sigma),
    ],
  });
  tx.moveCall({
    target: target("market_oracle", "update_svi"),
    arguments: [
      tx.object(params.oracleId),
      tx.object(params.protocolConfigId),
      tx.object(params.oracleCapId),
      sviParams,
      tx.pure.u64(nextSourceTimestampMs()),
      tx.object(CLOCK_ID),
    ],
  });
}

function mintDusdc(tx: Transaction, amount: bigint) {
  const [coin] = tx.moveCall({
    target: "0x2::coin::mint",
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
  });
  return coin;
}

function startPlpValuationWithExpiry(tx: Transaction, params: ExpiryValuationParams) {
  const valuation = tx.moveCall({
    target: target("plp", "start_valuation"),
    arguments: [tx.object(params.protocolConfigId), tx.object(params.poolVaultId)],
  });
  const expiryValuation = tx.moveCall({
    target: target("expiry_market", "produce_valuation"),
    arguments: [
      tx.object(params.expiryMarketId),
      tx.object(params.protocolConfigId),
      tx.object(params.oracleId),
      tx.object(params.pythSourceId),
      tx.object(CLOCK_ID),
    ],
  });
  tx.moveCall({
    target: target("plp", "add_expiry_valuation"),
    arguments: [valuation, expiryValuation],
  });
  return valuation;
}

function addMint(tx: Transaction, params: MintParams): void {
  const { lower, higher } = binaryRangeBounds(params.strike, params.isUp);
  tx.moveCall({
    target: target("expiry_market", "mint"),
    arguments: [
      tx.object(params.expiryMarketId),
      tx.object(params.managerId),
      tx.object(params.protocolConfigId),
      tx.object(params.oracleId),
      tx.object(params.pythSourceId),
      tx.pure.u64(lower),
      tx.pure.u64(higher),
      tx.pure.u64(params.quantity),
      tx.pure.u64(params.leverage),
      tx.object(CLOCK_ID),
    ],
  });
}

function addRedeem(tx: Transaction, params: RedeemParams): void {
  tx.moveCall({
    target: target("expiry_market", "redeem"),
    arguments: [
      tx.object(params.expiryMarketId),
      tx.object(params.managerId),
      tx.object(params.protocolConfigId),
      tx.object(params.oracleId),
      tx.object(params.pythSourceId),
      tx.pure.u256(BigInt(params.orderId)),
      tx.pure.u64(params.closeQuantity),
      tx.object(CLOCK_ID),
    ],
  });
}

function binaryRangeBounds(strike: bigint, isUp: boolean): { lower: bigint; higher: bigint } {
  return isUp
    ? { lower: strike, higher: POS_INF_STRIKE }
    : { lower: NEG_INF_STRIKE, higher: strike };
}

export function finalizeDusdcCurrencyRegistrationTx(): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: "0x2::coin_registry::finalize_registration",
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(COIN_REGISTRY_ID), tx.object(DUSDC_CURRENCY_ID)],
  });
  return tx;
}

export function createMarketOracleCapTx(recipient: string): Transaction {
  const tx = new Transaction();
  const cap = tx.moveCall({
    target: target("market_oracle", "create_cap"),
    arguments: [tx.object(ADMIN_CAP_ID)],
  });
  tx.transferObjects([cap], tx.pure.address(recipient));
  return tx;
}

export function createPythSourceTx(
  feedId: number,
  expiryFeeWindowMs: bigint = 0n,
  expiryFeeMaxMultiplier: bigint = 1_000_000_000n,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_pyth_source"),
    arguments: [
      tx.object(REGISTRY_ID),
      tx.object(ADMIN_CAP_ID),
      tx.pure.u32(feedId),
      tx.pure.u64(expiryFeeWindowMs),
      tx.pure.u64(expiryFeeMaxMultiplier),
    ],
  });
  return tx;
}

export function createExpiryMarketTx(params: {
  poolVaultId: string;
  protocolConfigId: string;
  pythSourceId: string;
  oracleCapId: string;
  expiry: bigint;
  minStrike: bigint;
  tickSize: bigint;
}): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_expiry_market"),
    arguments: [
      tx.object(REGISTRY_ID),
      tx.object(params.poolVaultId),
      tx.object(params.protocolConfigId),
      tx.object(params.pythSourceId),
      tx.object(params.oracleCapId),
      tx.pure.u64(params.expiry),
      tx.pure.u64(params.minStrike),
      tx.pure.u64(params.tickSize),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function setMarketOracleBasisBoundsTx(
  oracleId: string,
  protocolConfigId: string,
  oracleCapId: string,
  maxSpotDeviation: bigint,
  maxBasisDeviation: bigint,
  minBasis: bigint,
  maxBasis: bigint
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("market_oracle", "set_basis_bounds"),
    arguments: [
      tx.object(oracleId),
      tx.object(protocolConfigId),
      tx.object(oracleCapId),
      tx.pure.u64(maxSpotDeviation),
      tx.pure.u64(maxBasisDeviation),
      tx.pure.u64(minBasis),
      tx.pure.u64(maxBasis),
    ],
  });
  return tx;
}

export function supplyTx(poolVaultId: string, protocolConfigId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const dusdc = mintDusdc(tx, amount);
  const valuation = tx.moveCall({
    target: target("plp", "start_valuation"),
    arguments: [tx.object(protocolConfigId), tx.object(poolVaultId)],
  });
  const [plpCoin] = tx.moveCall({
    target: target("plp", "supply"),
    arguments: [tx.object(poolVaultId), tx.object(protocolConfigId), valuation, dusdc],
  });
  tx.transferObjects([plpCoin], tx.pure.address(address));
  return tx;
}

export function refreshOracleAndSupplyWithExpiryValuationTx(
  params: OracleRefreshParams & SupplyWithExpiryValuationParams
): Transaction {
  const tx = new Transaction();
  addOracleRefresh(tx, params);
  const dusdc = mintDusdc(tx, params.amount);
  const valuation = startPlpValuationWithExpiry(tx, params);
  const [plpCoin] = tx.moveCall({
    target: target("plp", "supply"),
    arguments: [tx.object(params.poolVaultId), tx.object(params.protocolConfigId), valuation, dusdc],
  });
  tx.transferObjects([plpCoin], tx.pure.address(address));
  return tx;
}

export function refreshOracleAndWithdrawWithExpiryValuationTx(
  params: OracleRefreshParams & WithdrawWithExpiryValuationParams
): Transaction {
  const tx = new Transaction();
  addOracleRefresh(tx, params);
  const valuation = startPlpValuationWithExpiry(tx, params);
  const [dusdc] = tx.moveCall({
    target: target("plp", "withdraw"),
    arguments: [
      tx.object(params.poolVaultId),
      tx.object(params.protocolConfigId),
      valuation,
      tx.object(params.lpCoinId),
    ],
  });
  tx.transferObjects([dusdc], tx.pure.address(address));
  return tx;
}

export function createManagerTx(): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: target("registry", "create_and_share_manager"),
    arguments: [tx.object(REGISTRY_ID)],
  });
  return tx;
}

// === Derived object IDs ===

const PredictManagerKeyBcs = bcs.struct("PredictManagerKey", {
  pos0: bcs.Address,
  pos1: bcs.u64(),
});

export function deriveManagerId(owner: string, index: bigint = 0n): string {
  const key = PredictManagerKeyBcs.serialize({ pos0: owner, pos1: index }).toBytes();
  return deriveObjectID(
    REGISTRY_ID,
    `${PACKAGE_ID}::predict_manager::PredictManagerKey`,
    key
  );
}

export function depositToManagerTx(managerId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const coin = mintDusdc(tx, amount);
  tx.moveCall({
    target: target("predict_manager", "deposit"),
    arguments: [tx.object(managerId), coin],
  });
  return tx;
}

export function refreshOracleAndMintTx(params: OracleRefreshParams & MintParams): Transaction {
  const tx = new Transaction();
  addOracleRefresh(tx, params);
  addMint(tx, params);
  return tx;
}

export function refreshOracleAndRedeemTx(params: OracleRefreshParams & RedeemParams): Transaction {
  const tx = new Transaction();
  addOracleRefresh(tx, params);
  addRedeem(tx, params);
  return tx;
}

export async function executeAndWait(
  tx: Transaction,
  label = "transaction",
  gasBudget = DEFAULT_GAS_BUDGET
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

export async function execute(
  buildTx: Transaction | (() => Transaction),
  label = "transaction",
): Promise<ExecutionReceipt> {
  let lastError: unknown;
  for (let attempt = 0; attempt < EXECUTE_MAX_ATTEMPTS; attempt++) {
    try {
      // Build a fresh transaction on each attempt so object versions are re-resolved.
      const tx = typeof buildTx === "function" ? buildTx() : buildTx;
      tx.setSender(address);
      tx.setGasBudget(DEFAULT_GAS_BUDGET);

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
      return {
        digest: raw.digest,
        gas: gasSummaryFromEffects(settled.effects ?? raw.effects),
        events: settled.events ?? raw.events ?? [],
        objectChanges: settled.objectChanges ?? raw.objectChanges ?? [],
        effects: settled.effects ?? raw.effects,
      };
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
