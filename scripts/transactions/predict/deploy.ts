// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, publishPackage } from "../../utils/utils.js";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui/utils";

(async () => {
  const network = (process.env.NETWORK as any) || "testnet";
  const client = getClient(network);
  const signer = getSigner();
  const tx = new Transaction();

  // 1. Publish Package
  console.log("Publishing deepbook_predict...");
  publishPackage(tx, "../packages/predict");

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: signer,
    options: {
      showObjectChanges: true,
      showEffects: true,
    },
  });

  if (result.effects?.status.status !== "success") {
    console.error("Publish failed:", result.effects?.status.error);
    return;
  }

  const packageId = result.objectChanges?.find(
    (oc) => oc.type === "published"
  )?.packageId;
  const adminCap = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.endsWith("::registry::AdminCap")
  )?.objectId;
  const registry = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.endsWith("::registry::Registry")
  )?.objectId;
  const treasuryCapPLP = result.objectChanges?.find(
    (oc) => (oc as any).objectType?.includes("::coin::TreasuryCap<") && (oc as any).objectType?.includes("::plp::PLP>")
  )?.objectId;

  console.log({
    packageId,
    adminCap,
    registry,
    treasuryCapPLP,
  });

  // 2. Setup Protocol (Create Predict object)
  // Assuming USDC is the quote asset. Need its Currency object.
  // This part usually requires a second transaction or finding the USDC Currency.
  console.log("Protocol published. Next: run setup_protocol with specific Quote asset.");
})();
