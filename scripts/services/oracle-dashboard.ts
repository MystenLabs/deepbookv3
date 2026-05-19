// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import axios from "axios";

/**
 * Simple dashboard to monitor Predict Oracles via the Server API.
 */
async function monitorOracles() {
  const apiUrl = process.env.PREDICT_API_URL || "http://127.0.0.1:8080/api/v1";

  console.log(`Monitoring oracles at ${apiUrl}...`);

  while (true) {
    try {
      const response = await axios.get(`${apiUrl}/oracles`);
      const oracles = response.data;

      console.clear();
      console.log("=== Predict Oracle Dashboard ===");
      console.table(oracles.map((o: any) => ({
        ID: o.object_id.substring(0, 10) + "...",
        Asset: o.underlying_asset,
        Status: ["Inactive", "Active", "Pending", "Settled"][o.status],
        Expiry: new Date(Number(o.expiry)).toLocaleString(),
        Settlement: o.settlement_price ? (Number(o.settlement_price) / 1e9).toFixed(2) : "N/A",
      })));
    } catch (e) {
      console.error("Error fetching oracle data:", (e as any).message);
    }
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
    monitorOracles().catch(console.error);
}
