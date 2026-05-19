// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../../utils/utils.js";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui/utils";

(async () => {
  const network = (process.env.NETWORK as any) || "testnet";
  const client = getClient(network);
  const signer = getSigner();
  const tx = new Transaction();

  const packageId = process.env.PACKAGE_ID!;
  const registry = process.env.REGISTRY_ID!;
  const predict = process.env.PREDICT_ID!;
  const adminCap = process.env.ADMIN_CAP_ID!;
  const oracleCap = process.env.ORACLE_CAP_ID!;

  const asset = process.env.ASSET_NAME || "BTC";
  const feedId = BigInt(process.env.PYTH_FEED_ID || "0");
  const expiry = BigInt(process.env.EXPIRY || "0");
  const minStrike = BigInt(process.env.MIN_STRIKE || "50000000000"); // $50,000
  const tickSize = BigInt(process.env.TICK_SIZE || "100000000"); // $100

  // 1. Add Asset and Oracle
  tx.moveCall({
    target: `${packageId}::deploy_scripts::add_asset_and_oracle`,
    arguments: [
      tx.object(registry),
      tx.object(predict),
      tx.object(adminCap),
      tx.object(oracleCap),
      tx.pure.string(asset),
      tx.pure.u64(feedId),
      tx.pure.u64(expiry),
      tx.pure.u64(minStrike),
      tx.pure.u64(tickSize),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  });

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: signer,
    options: {
      showObjectChanges: true,
      showEffects: true,
    },
  });

  if (result.effects?.status.status !== "success") {
    console.error("Create oracle failed:", result.effects?.status.error);
    return;
  }

  const oracleId = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.includes("::oracle::OracleSVI")
  )?.objectId;

  console.log({
    oracleId,
  });

  console.log(`Oracle for ${asset} created successfully.`);
})();
