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

  // IDs from deploy.ts output
  const packageId = process.env.PACKAGE_ID!;
  const registry = process.env.REGISTRY_ID!;
  const adminCap = process.env.ADMIN_CAP_ID!;
  const treasuryCapPLP = process.env.TREASURY_CAP_PLP_ID!;
  const usdcCurrency = process.env.USDC_CURRENCY_ID!; // Currency<USDC>
  const usdcType = process.env.USDC_TYPE!; // e.g. "0x...::usdc::USDC"

  // 1. Setup Protocol (Create Predict object)
  tx.moveCall({
    target: `${packageId}::deploy_scripts::setup_protocol`,
    typeArguments: [usdcType],
    arguments: [
      tx.object(registry),
      tx.object(adminCap),
      tx.object(usdcCurrency),
      tx.object(treasuryCapPLP),
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
    console.error("Setup failed:", result.effects?.status.error);
    return;
  }

  const predict = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.includes("::predict::Predict<")
  )?.objectId;
  const oracleCap = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.endsWith("::oracle::OracleSVICap")
  )?.objectId;

  console.log({
    predict,
    oracleCap,
  });

  console.log("Protocol setup complete. Use oracleCap to create oracles.");
})();
