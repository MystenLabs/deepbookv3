import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";
import type { OracleId, CapId, SVIParams, Tier } from "./types";

export const CLOCK_ID = "0x6";
export const FLOAT_SCALING = 1_000_000_000;

export function scaleToU64(value: number): number {
  return Math.round(value * FLOAT_SCALING);
}

export function signedToPair(value: number): { magnitude: number; negative: boolean } {
  return { magnitude: scaleToU64(Math.abs(value)), negative: value < 0 };
}

export function addUpdatePrices(
  tx: Transaction,
  packageId: string,
  args: { oracleId: OracleId; capId: CapId; spot: number; forward: number },
): void {
  const priceData = tx.moveCall({
    target: `${packageId}::oracle::new_price_data`,
    arguments: [tx.pure.u64(scaleToU64(args.spot)), tx.pure.u64(scaleToU64(args.forward))],
  });
  tx.moveCall({
    target: `${packageId}::oracle::update_prices`,
    arguments: [tx.object(args.oracleId), tx.object(args.capId), priceData, tx.object(CLOCK_ID)],
  });
}

export function addUpdateSvi(
  tx: Transaction,
  packageId: string,
  args: { oracleId: OracleId; capId: CapId; params: SVIParams },
): void {
  const rho = signedToPair(args.params.rho);
  const m = signedToPair(args.params.m);
  const svi = tx.moveCall({
    target: `${packageId}::oracle::new_svi_params`,
    arguments: [
      tx.pure.u64(scaleToU64(args.params.a)),
      tx.pure.u64(scaleToU64(args.params.b)),
      tx.pure.u64(rho.magnitude),
      tx.pure.bool(rho.negative),
      tx.pure.u64(m.magnitude),
      tx.pure.bool(m.negative),
      tx.pure.u64(scaleToU64(args.params.sigma)),
    ],
  });
  tx.moveCall({
    target: `${packageId}::oracle::update_svi`,
    arguments: [tx.object(args.oracleId), tx.object(args.capId), svi, tx.object(CLOCK_ID)],
  });
}

export function addActivate(
  tx: Transaction,
  packageId: string,
  args: { oracleId: OracleId; capId: CapId },
): void {
  tx.moveCall({
    target: `${packageId}::oracle::activate`,
    arguments: [tx.object(args.oracleId), tx.object(args.capId), tx.object(CLOCK_ID)],
  });
}

export function addCompact(
  tx: Transaction,
  packageId: string,
  args: { predictId: string; oracleId: OracleId; capId: CapId },
): void {
  tx.moveCall({
    target: `${packageId}::predict::compact_settled_oracle`,
    arguments: [tx.object(args.predictId), tx.object(args.oracleId), tx.object(args.capId)],
  });
}

export function addSettleNudge(
  tx: Transaction,
  packageId: string,
  args: { oracleId: OracleId; capId: CapId; spot: number; forward: number },
): void {
  // Same as update_prices; the chain's update_prices hits the pending_settlement
  // branch once clock >= expiry.
  addUpdatePrices(tx, packageId, args);
}

export function addRegisterCap(
  tx: Transaction,
  packageId: string,
  args: { oracleId: OracleId; adminCapId: string; capIdToRegister: CapId },
): void {
  tx.moveCall({
    target: `${packageId}::registry::register_oracle_cap`,
    arguments: [
      tx.object(args.oracleId),
      tx.object(args.adminCapId),
      tx.object(args.capIdToRegister),
    ],
  });
}

export function addCreateOracle(
  tx: Transaction,
  packageId: string,
  args: {
    registryId: string;
    predictId: string;
    adminCapId: string;
    capId: CapId;
    underlying: "BTC";
    expiryMs: number;
    minStrike: number;
    tickSize: number;
  },
): TransactionArgument {
  return tx.moveCall({
    target: `${packageId}::registry::create_oracle`,
    arguments: [
      tx.object(args.registryId),
      tx.object(args.predictId),
      tx.object(args.adminCapId),
      tx.object(args.capId),
      tx.pure.string(args.underlying),
      tx.pure.u64(args.expiryMs),
      tx.pure.u64(args.minStrike),
      tx.pure.u64(args.tickSize),
    ],
  });
}
