// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One-time setup: mint 19 additional OracleCapSVI objects, register each on
/// all oracles, split gas into 20 lanes, and write cap IDs to constants.ts.

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../../utils/utils";
import {
  predictPackageID,
  predictAdminCapID,
  predictOracleCapID,
} from "../../config/constants";
import { predictOracles, type OracleEntry } from "../../config/predict-oracles";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONSTANTS_PATH = path.resolve(__dirname, "../../config/constants.ts");

const network = "testnet" as const;
const NUM_NEW_CAPS = 19;
const NUM_TOTAL_LANES = 20;
const GAS_PER_LANE = 10_000_000_000; // 10 SUI

(async () => {
  const client = getClient(network);
  const signer = getSigner();
  const address = signer.toSuiAddress();
  const pkg = predictPackageID[network];
  const adminCapId = predictAdminCapID[network];
  const originalCapId = predictOracleCapID[network];
  const oracles: OracleEntry[] = predictOracles[network];

  console.log(`Setup Oracle Cap Lanes on ${network}`);
  console.log(`  Address:      ${address}`);
  console.log(`  Package:      ${pkg}`);
  console.log(`  AdminCap:     ${adminCapId}`);
  console.log(`  Original Cap: ${originalCapId}`);
  console.log(`  Oracles:      ${oracles.length}`);
  console.log(`  New caps:     ${NUM_NEW_CAPS}`);

  // -------------------------------------------------------------------------
  // Step 1: Mint 19 new OracleCapSVI objects
  // -------------------------------------------------------------------------
  console.log(`\n--- Step 1: Mint ${NUM_NEW_CAPS} new OracleCapSVI ---`);

  const mintTx = new Transaction();
  for (let i = 0; i < NUM_NEW_CAPS; i++) {
    const cap = mintTx.moveCall({
      target: `${pkg}::registry::create_oracle_cap`,
      arguments: [mintTx.object(adminCapId)],
    });
    mintTx.transferObjects([cap], mintTx.pure.address(address));
  }

  const mintResult = await client.signAndExecuteTransaction({
    transaction: mintTx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: mintResult.digest });

  if (mintResult.effects?.status.status !== "success") {
    console.error("Mint failed:", mintResult.effects?.status);
    process.exit(1);
  }

  const newCapIds = (mintResult.objectChanges ?? [])
    .filter(
      (c) =>
        c.type === "created" &&
        "objectType" in c &&
        c.objectType.includes("::oracle::OracleCapSVI"),
    )
    .map((c) => ("objectId" in c ? c.objectId : ""));

  if (newCapIds.length !== NUM_NEW_CAPS) {
    console.error(
      `Expected ${NUM_NEW_CAPS} new caps, got ${newCapIds.length}`,
    );
    process.exit(1);
  }

  console.log(`  Minted ${newCapIds.length} caps: ${mintResult.digest}`);
  newCapIds.forEach((id, i) => console.log(`    Cap ${i + 1}: ${id}`));

  // -------------------------------------------------------------------------
  // Step 2: Register each new cap on all oracles
  // -------------------------------------------------------------------------
  console.log(`\n--- Step 2: Register all caps on ${oracles.length} oracles ---`);

  const regTx = new Transaction();
  for (const capId of newCapIds) {
    for (const oracle of oracles) {
      regTx.moveCall({
        target: `${pkg}::registry::register_oracle_cap`,
        typeArguments: [oracle.underlying],
        arguments: [
          regTx.object(oracle.oracleId),
          regTx.object(adminCapId),
          regTx.object(capId),
        ],
      });
    }
  }

  const regResult = await client.signAndExecuteTransaction({
    transaction: regTx,
    signer,
    options: { showEffects: true },
  });
  await client.waitForTransaction({ digest: regResult.digest });

  if (regResult.effects?.status.status !== "success") {
    console.error("Register caps failed:", regResult.effects?.status);
    process.exit(1);
  }

  console.log(
    `  Registered ${newCapIds.length} caps on ${oracles.length} oracles in 1 tx: ${regResult.digest}`,
  );

  // -------------------------------------------------------------------------
  // Step 3: Merge all SUI coins and split into 20 gas lanes
  // -------------------------------------------------------------------------
  console.log(`\n--- Step 3: Split gas into ${NUM_TOTAL_LANES} lanes ---`);

  // Fetch all SUI coins
  const allCoins: Array<{
    coinObjectId: string;
    version: string;
    digest: string;
    balance: string;
  }> = [];
  let cursor: string | null | undefined = undefined;
  let hasNext = true;
  while (hasNext) {
    const page = await client.getCoins({
      owner: address,
      coinType: "0x2::sui::SUI",
      cursor: cursor ?? undefined,
    });
    allCoins.push(...page.data);
    hasNext = page.hasNextPage;
    cursor = page.nextCursor;
  }

  console.log(`  Found ${allCoins.length} SUI coin(s)`);

  const totalBalance = allCoins.reduce(
    (sum, c) => sum + BigInt(c.balance),
    0n,
  );
  const needed =
    BigInt(GAS_PER_LANE) * BigInt(NUM_TOTAL_LANES) + 500_000_000n;
  console.log(
    `  Total balance: ${totalBalance}, needed: ~${needed}`,
  );

  if (totalBalance < needed) {
    console.error(
      `Insufficient SUI: have ${totalBalance}, need ~${needed}`,
    );
    process.exit(1);
  }

  // Merge if >1 coin
  let primaryRef = {
    objectId: allCoins[0].coinObjectId,
    version: allCoins[0].version,
    digest: allCoins[0].digest,
  };

  if (allCoins.length > 1) {
    console.log(`  Merging ${allCoins.length} coins...`);
    const mergeTx = new Transaction();
    mergeTx.setGasPayment([primaryRef]);
    const otherRefs = allCoins
      .slice(1)
      .map((c) => mergeTx.object(c.coinObjectId));
    mergeTx.mergeCoins(mergeTx.gas, otherRefs);

    const mergeResult = await client.signAndExecuteTransaction({
      transaction: mergeTx,
      signer,
      options: { showEffects: true },
    });
    await client.waitForTransaction({ digest: mergeResult.digest });

    if (mergeResult.effects?.status.status !== "success") {
      console.error("Merge failed:", mergeResult.effects?.status);
      process.exit(1);
    }

    const gasRef = mergeResult.effects?.gasObject?.reference;
    if (gasRef) {
      primaryRef = {
        objectId: gasRef.objectId,
        version: gasRef.version,
        digest: gasRef.digest,
      };
    }
    console.log(`  Merge OK: ${mergeResult.digest.slice(0, 16)}...`);
  }

  // Split into lanes
  const splitTx = new Transaction();
  splitTx.setGasPayment([primaryRef]);
  const amounts = Array.from({ length: NUM_TOTAL_LANES }, () =>
    splitTx.pure.u64(GAS_PER_LANE),
  );
  const coins = splitTx.splitCoins(splitTx.gas, amounts);
  for (let i = 0; i < NUM_TOTAL_LANES; i++) {
    splitTx.transferObjects([coins[i]], address);
  }

  const splitResult = await client.signAndExecuteTransaction({
    transaction: splitTx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: splitResult.digest });

  if (splitResult.effects?.status.status !== "success") {
    console.error("Split failed:", splitResult.effects?.status);
    process.exit(1);
  }

  console.log(`  Split OK: ${splitResult.digest.slice(0, 16)}...`);

  // -------------------------------------------------------------------------
  // Step 4: Update constants.ts with all 20 cap IDs
  // -------------------------------------------------------------------------
  const allCapIds = [originalCapId, ...newCapIds];
  console.log(`\n--- Step 4: Write ${allCapIds.length} cap IDs to constants.ts ---`);

  let constants = fs.readFileSync(CONSTANTS_PATH, "utf-8");

  // Build the replacement array literal
  const capArrayStr = allCapIds.map((id) => `    "${id}"`).join(",\n");
  const replacement = `export const predictOracleCapIDs: Record<string, string[]> = {\n  mainnet: [],\n  testnet: [\n${capArrayStr},\n  ],\n};`;

  constants = constants.replace(
    /export const predictOracleCapIDs[\s\S]*?^};/m,
    replacement,
  );

  fs.writeFileSync(CONSTANTS_PATH, constants);

  console.log(`  Written to ${CONSTANTS_PATH}`);
  console.log(`\nDone! ${allCapIds.length} cap IDs configured for ${NUM_TOTAL_LANES} lanes.`);
})();
