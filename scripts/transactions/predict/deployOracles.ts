// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Deploys one OracleSVI<SUI> per BlockScholes expiry on testnet.
/// Usage: pnpm tsx transactions/predict/deployOracles.ts

import { Transaction } from "@mysten/sui/transactions";
import { getActiveAddress, getClient, getSigner } from "../../utils/utils";
import {
  predictPackageID,
  predictRegistryID,
  predictAdminCapID,
  predictOracleCapID,
} from "../../config/constants";
import {
  predictOracles,
  type OracleEntry,
} from "../../config/predict-oracles";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ORACLES_CONFIG_PATH = path.resolve(
  __dirname,
  "../../config/predict-oracles.ts",
);

const network = "testnet" as const;
const UNDERLYING_TYPE = "0x2::sui::SUI";

// New BlockScholes BTC expiries to deploy (all 08:00 UTC)
const EXPIRIES = [
  "2026-05-29T08:00:00.000Z",
  "2026-06-26T08:00:00.000Z",
  "2026-09-25T08:00:00.000Z",
  "2026-12-25T08:00:00.000Z",
];

(async () => {
  const client = getClient(network);
  const signer = getSigner();
  const address = getActiveAddress();

  console.log(`Deploying ${EXPIRIES.length} oracles on ${network}`);
  console.log(`Deployer: ${address}`);
  console.log(`Package:  ${predictPackageID[network]}`);
  console.log(`Cap:      ${predictOracleCapID[network]}\n`);

  const entries: OracleEntry[] = [];

  for (const expiryIso of EXPIRIES) {
    const expiryMs = new Date(expiryIso).getTime();

    console.log(`Creating oracle for ${expiryIso} (${expiryMs})...`);

    const tx = new Transaction();
    tx.moveCall({
      target: `${predictPackageID[network]}::registry::create_oracle`,
      typeArguments: [UNDERLYING_TYPE],
      arguments: [
        tx.object(predictRegistryID[network]),
        tx.object(predictAdminCapID[network]),
        tx.object(predictOracleCapID[network]),
        tx.pure.u64(expiryMs),
      ],
    });

    const result = await client.signAndExecuteTransaction({
      transaction: tx,
      signer,
      options: {
        showEffects: true,
        showObjectChanges: true,
      },
    });

    // Wait for the transaction to finalize before building the next one,
    // otherwise shared objects (AdminCap, Registry) may have stale versions.
    await client.waitForTransaction({ digest: result.digest });

    if (result.effects?.status.status !== "success") {
      console.error(`  FAILED:`, result.effects?.status);
      process.exit(1);
    }

    let oracleId = "";
    const created =
      result.objectChanges?.filter((c) => c.type === "created") ?? [];
    for (const obj of created) {
      if (obj.type !== "created") continue;
      if (obj.objectType.includes("::oracle::OracleSVI")) {
        oracleId = obj.objectId;
      }
    }

    if (!oracleId) {
      console.error(`  Could not find OracleSVI in objectChanges`);
      process.exit(1);
    }

    console.log(`  Oracle: ${oracleId}`);
    console.log(`  Digest: ${result.digest}\n`);

    entries.push({
      oracleId,
      expiry: expiryIso,
      expiryMs,
      underlying: UNDERLYING_TYPE,
    });
  }

  // Merge with existing non-expired oracles
  const now = Date.now();
  const existing = (predictOracles[network] ?? []).filter(
    (o) => o.expiryMs > now,
  );
  const allOracles = [...existing, ...entries].sort(
    (a, b) => a.expiryMs - b.expiryMs,
  );

  const configContent = `// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OracleEntry {
  oracleId: string;
  expiry: string; // ISO 8601
  expiryMs: number; // on-chain milliseconds
  underlying: string; // Move type arg
}

export const predictOracles: Record<string, OracleEntry[]> = {
  testnet: ${JSON.stringify(allOracles, null, 4)},
  mainnet: [],
};
`;

  fs.writeFileSync(ORACLES_CONFIG_PATH, configContent);
  console.log(`Written ${allOracles.length} oracle entries to config/predict-oracles.ts (${existing.length} existing + ${entries.length} new)`);
})();
