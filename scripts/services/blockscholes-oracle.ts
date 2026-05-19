// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../utils/utils.js";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui/utils";

/**
 * Service to fetch volatility and price data from Block Scholes and push to Sui.
 */
export class BlockScholesOracleService {
  private client;
  private signer;
  private packageId: string;
  private oracleCapId: string;

  constructor(packageId: string, oracleCapId: string, network: any = "testnet") {
    this.client = getClient(network);
    this.signer = getSigner();
    this.packageId = packageId;
    this.oracleCapId = oracleCapId;
  }

  /**
   * Fetch SVI and Price data for a specific asset.
   * In production, this would call Block Scholes API.
   */
  async fetchData(asset: string, expiry: number) {
    console.log(`Fetching data for ${asset} at expiry ${expiry}...`);
    // Placeholder logic - replace with real API call
    return {
      spot: 65000_000_000n, // $65,000 (1e9 scaled)
      forward: 65100_000_000n, // $65,100
      svi: {
        a: 100_000_000n,
        b: 50_000_000n,
        rho: { value: 100_000_000n, pos: false }, // -0.1
        m: { value: 50_000_000n, pos: true },   // +0.05
        sigma: 200_000_000n,
      },
    };
  }

  /**
   * Push updates for a specific oracle.
   */
  async updateOracle(oracleId: string, asset: string, expiry: number) {
    const data = await this.fetchData(asset, expiry);
    const tx = new Transaction();

    // 1. Update Prices (Spot + Forward)
    tx.moveCall({
      target: `${this.packageId}::oracle::update_prices`,
      arguments: [
        tx.object(oracleId),
        tx.object(this.oracleCapId),
        tx.pure.u64(data.spot),
        tx.pure.u64(data.forward),
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    });

    // 2. Update SVI Parameters
    tx.moveCall({
      target: `${this.packageId}::oracle::update_svi`,
      arguments: [
        tx.object(oracleId),
        tx.object(this.oracleCapId),
        tx.pure({
          SVIParams: {
            a: data.svi.a,
            b: data.svi.b,
            rho: data.svi.rho,
            m: data.svi.m,
            sigma: data.svi.sigma,
          }
        }),
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    });

    const result = await this.client.signAndExecuteTransaction({
      transaction: tx,
      signer: this.signer,
    });

    if (result.effects?.status.status === "success") {
      console.log(`Successfully updated oracle ${oracleId} for ${asset}`);
    } else {
      console.error(`Failed to update oracle ${oracleId}:`, result.effects?.status.error);
    }
  }

  /**
   * Main loop to periodically update all tracked oracles.
   */
  async start(oracles: { id: string; asset: string; expiry: number }[], intervalMs: number = 10000) {
    console.log(`Starting Block Scholes Oracle Service with ${oracles.length} oracles...`);
    while (true) {
      for (const oracle of oracles) {
        try {
          await this.updateOracle(oracle.id, oracle.asset, oracle.expiry);
        } catch (e) {
          console.error(`Error updating oracle ${oracle.id}:`, e);
        }
      }
      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
  }
}
