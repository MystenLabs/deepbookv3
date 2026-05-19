// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { BlockScholesOracleService } from "./blockscholes-oracle.js";
import { getClient } from "../utils/utils.js";

/**
 * High-level service to manage multiple oracle feeds and protocol maintenance.
 */
async function runOracleFeed() {
  const packageId = process.env.PACKAGE_ID!;
  const oracleCapId = process.env.ORACLE_CAP_ID!;
  const network = (process.env.NETWORK as any) || "testnet";
  
  const blockScholes = new BlockScholesOracleService(packageId, oracleCapId, network);
  const client = getClient(network);

  // In a real scenario, we would fetch the list of active oracles from the Indexer API (PR 8)
  // For now, we take them from environment or a config file.
  const trackedOracles = [
    { id: process.env.BTC_ORACLE_ID!, asset: "BTC", expiry: 1716120000 },
  ];

  console.log("Oracle Feed Service started.");
  
  // Start the volatility and basis update loop
  blockScholes.start(trackedOracles, 15000); // Update every 15s

  // Maintenance Loop: Handle activation and settlement
  while (true) {
    const now = Date.now();
    for (const oracle of trackedOracles) {
        // 1. Check if oracle needs activation (if status is INACTIVE and time reached)
        // 2. Check if oracle needs settlement (if time > expiry and status not SETTLED)
        // Logic for this would require fetching oracle object state from Sui.
    }
    await new Promise(resolve => setTimeout(resolve, 60000)); // Check maintenance every minute
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
    runOracleFeed().catch(console.error);
}
