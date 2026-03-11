// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registers existing extra caps on newly deployed oracles.
/// Usage: pnpm tsx transactions/predict/registerCapsOnNewOracles.ts

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../../utils/utils";
import {
  predictPackageID,
  predictAdminCapID,
  predictOracleCapID,
  predictOracleCapIDs,
} from "../../config/constants";

const network = "testnet" as const;
const pkg = predictPackageID[network];
const adminCapId = predictAdminCapID[network];
const originalCapId = predictOracleCapID[network];

// The 19 extra caps (all except the original)
const extraCaps = predictOracleCapIDs[network].filter(
  (id) => id !== originalCapId,
);

// New oracles that need the extra caps registered
const newOracles = [
  {
    oracleId:
      "0xd3a4e5e819dccc7c68c243f3f0eda1a8521ad7a4912104425d7a151b6a1acab4",
    underlying: "0x2::sui::SUI",
  },
  {
    oracleId:
      "0x9434d52a2f8faba2d9723df9461426ab898fa6b8c7f715e6460d56dc9a3515b6",
    underlying: "0x2::sui::SUI",
  },
  {
    oracleId:
      "0x78ae3139cd2273aa6a9e6325a1a160c5f65368073fe479a0e4bee2383cf67e36",
    underlying: "0x2::sui::SUI",
  },
  {
    oracleId:
      "0x5525958a4ffa8ade210fbe0084a1dfd1db7870aa70a75c849df9ee1c2eb6844b",
    underlying: "0x2::sui::SUI",
  },
];

(async () => {
  const client = getClient(network);
  const signer = getSigner();

  console.log(`Registering ${extraCaps.length} caps on ${newOracles.length} new oracles`);
  console.log(`  AdminCap: ${adminCapId}`);
  console.log(`  Total calls: ${extraCaps.length * newOracles.length}\n`);

  const tx = new Transaction();
  for (const capId of extraCaps) {
    for (const oracle of newOracles) {
      tx.moveCall({
        target: `${pkg}::registry::register_oracle_cap`,
        typeArguments: [oracle.underlying],
        arguments: [
          tx.object(oracle.oracleId),
          tx.object(adminCapId),
          tx.object(capId),
        ],
      });
    }
  }

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true },
  });
  await client.waitForTransaction({ digest: result.digest });

  if (result.effects?.status.status !== "success") {
    console.error("Failed:", result.effects?.status);
    process.exit(1);
  }

  console.log(`Done! Digest: ${result.digest}`);
})();
