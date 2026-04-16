// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import type { OracleId, CapId, SVIParams } from "./types";

export const CLOCK_ID = "0x6";
export const FLOAT_SCALING = 1_000_000_000;

export function scaleToU64(value: number): number {
  return Math.round(value * FLOAT_SCALING);
}

function signedToPair(value: number): { magnitude: number; negative: boolean } {
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

  // oracle::new_svi_params expects rho and m as deepbook_predict::i64::I64
  // structs, not raw u64/bool pairs. Construct them via i64::from_parts first.
  const rhoI64 = tx.moveCall({
    target: `${packageId}::i64::from_parts`,
    arguments: [tx.pure.u64(rho.magnitude), tx.pure.bool(rho.negative)],
  });
  const mI64 = tx.moveCall({
    target: `${packageId}::i64::from_parts`,
    arguments: [tx.pure.u64(m.magnitude), tx.pure.bool(m.negative)],
  });

  const svi = tx.moveCall({
    target: `${packageId}::oracle::new_svi_params`,
    arguments: [
      tx.pure.u64(scaleToU64(args.params.a)),
      tx.pure.u64(scaleToU64(args.params.b)),
      rhoI64,
      mI64,
      tx.pure.u64(scaleToU64(args.params.sigma)),
    ],
  });
  tx.moveCall({
    target: `${packageId}::oracle::update_svi`,
    arguments: [tx.object(args.oracleId), tx.object(args.capId), svi, tx.object(CLOCK_ID)],
  });
}
