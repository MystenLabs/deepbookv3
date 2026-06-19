// PTB builders for the live trade flows. Arg orders mirror the contract entrypoints
// (see packages/predict/sources/expiry_market.move + plp.move + account package).
import { Transaction } from "@mysten/sui/transactions";
import {
  ACCUMULATOR_ROOT_ID,
  CLOCK_ID,
  DUSDC_TYPE,
  ORACLE_REGISTRY_ID,
  PROTOCOL_CONFIG_ID,
  POOL_VAULT_ID,
  ACCOUNT_REGISTRY_ID,
  targetAccount,
  targetPredict,
} from "./config";

// Owner authority is a hot potato minted from the tx sender and consumed by the next
// account-loading call (load_account_mut inside deposit_funds / mint / redeem / request_*).
function generateAuth(tx: Transaction) {
  return tx.moveCall({ target: targetAccount("account", "generate_auth"), arguments: [] });
}

/** Create the sender's canonical derived account wrapper and share it. */
export function createAccountTx(): Transaction {
  const tx = new Transaction();
  const wrapper = tx.moveCall({
    target: targetAccount("account_registry", "new"),
    arguments: [tx.object(ACCOUNT_REGISTRY_ID)],
  });
  tx.moveCall({ target: targetAccount("account", "share"), arguments: [wrapper] });
  return tx;
}

/** Split `amount` DUSDC off `fundingCoinId` and deposit it into the account's stored balance. */
export function depositTx(wrapperId: string, fundingCoinId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const [coin] = tx.splitCoins(tx.object(fundingCoinId), [tx.pure.u64(amount)]);
  const auth = generateAuth(tx);
  tx.moveCall({
    target: targetAccount("account", "deposit_funds"),
    typeArguments: [DUSDC_TYPE],
    arguments: [tx.object(wrapperId), auth, coin, tx.object(ACCUMULATOR_ROOT_ID), tx.object(CLOCK_ID)],
  });
  return tx;
}

export interface MintArgs {
  marketId: string;
  wrapperId: string;
  pythFeedId: string;
  bsFeedId: string;
  lowerTick: bigint;
  higherTick: bigint;
  quantity: bigint;
  leverage: bigint;
}
export function mintTx(a: MintArgs): Transaction {
  const tx = new Transaction();
  const auth = generateAuth(tx);
  tx.moveCall({
    target: targetPredict("expiry_market", "mint"),
    arguments: [
      tx.object(a.marketId),
      tx.object(a.wrapperId),
      auth,
      tx.object(PROTOCOL_CONFIG_ID),
      tx.object(ORACLE_REGISTRY_ID),
      tx.object(a.pythFeedId),
      tx.object(a.bsFeedId),
      tx.pure.u64(a.lowerTick),
      tx.pure.u64(a.higherTick),
      tx.pure.u64(a.quantity),
      tx.pure.u64(a.leverage),
      tx.object(ACCUMULATOR_ROOT_ID),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export interface RedeemArgs {
  marketId: string;
  wrapperId: string;
  pythFeedId: string;
  bsFeedId: string;
  orderId: string;
  closeQuantity: bigint;
}
export function redeemTx(a: RedeemArgs): Transaction {
  const tx = new Transaction();
  const auth = generateAuth(tx);
  tx.moveCall({
    target: targetPredict("expiry_market", "redeem"),
    arguments: [
      tx.object(a.marketId),
      tx.object(a.wrapperId),
      auth,
      tx.object(PROTOCOL_CONFIG_ID),
      tx.object(ORACLE_REGISTRY_ID),
      tx.object(a.pythFeedId),
      tx.object(a.bsFeedId),
      tx.pure.u256(BigInt(a.orderId)),
      tx.pure.u64(a.closeQuantity),
      tx.object(ACCUMULATOR_ROOT_ID),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

/** Queue an LP supply request: pulls `amount` DUSDC from the account's stored balance. */
export function requestSupplyTx(wrapperId: string, amount: bigint): Transaction {
  const tx = new Transaction();
  const auth = generateAuth(tx);
  tx.moveCall({
    target: targetPredict("plp", "request_supply"),
    arguments: [
      tx.object(POOL_VAULT_ID),
      tx.object(wrapperId),
      auth,
      tx.object(PROTOCOL_CONFIG_ID),
      tx.pure.u64(amount),
      tx.object(ACCUMULATOR_ROOT_ID),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

/** Queue an LP withdraw request: pulls `shares` PLP from the account's stored balance. */
export function requestWithdrawTx(wrapperId: string, shares: bigint): Transaction {
  const tx = new Transaction();
  const auth = generateAuth(tx);
  tx.moveCall({
    target: targetPredict("plp", "request_withdraw"),
    arguments: [
      tx.object(POOL_VAULT_ID),
      tx.object(wrapperId),
      auth,
      tx.object(PROTOCOL_CONFIG_ID),
      tx.pure.u64(shares),
      tx.object(ACCUMULATOR_ROOT_ID),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}
