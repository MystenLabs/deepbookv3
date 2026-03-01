// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Long-running oracle feed service that polls BlockScholes REST API
/// and pushes price/SVI data on-chain via PTBs.
///
/// Usage: pnpm oracle-feed

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../utils/utils";
import { predictPackageID, predictOracleCapID } from "../config/constants";
import { predictOracles, type OracleEntry } from "../config/predict-oracles";
import {
  fetchSpotPrice,
  fetchForwardPrice,
  fetchSVIParams,
} from "./blockscholes-oracle";

const CLOCK = "0x6";
const FLOAT_SCALING = 1e9;
const SVI_INTERVAL_MS = 20_000;
const LOOP_SLEEP_MS = 500;

const network = "testnet" as const;
const pkg = predictPackageID[network];
const oracleCapId = predictOracleCapID[network];

function scaleToU64(value: number): number {
  return Math.round(value * FLOAT_SCALING);
}

function signedParam(value: number): { magnitude: number; negative: boolean } {
  return { magnitude: scaleToU64(Math.abs(value)), negative: value < 0 };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class OracleFeedService {
  private client;
  private signer;
  private oracles: OracleEntry[];
  private lastSviTime = 0;
  private activated = new Set<string>();

  constructor() {
    this.client = getClient(network);
    this.signer = getSigner();
    this.oracles = predictOracles[network];

    if (this.oracles.length === 0) {
      throw new Error(`No oracles configured for ${network}`);
    }

    console.log(`Oracle Feed Service`);
    console.log(`  Network: ${network}`);
    console.log(`  Package: ${pkg}`);
    console.log(`  Cap:     ${oracleCapId}`);
    console.log(`  Oracles: ${this.oracles.length}`);
    this.oracles.forEach((o) =>
      console.log(`    ${o.expiry} -> ${o.oracleId.slice(0, 16)}...`),
    );
  }

  async start() {
    // Check which oracles need activation on first run
    await this.checkActivation();

    console.log(`\nStarting feed loop...\n`);

    while (true) {
      try {
        await this.tick();
      } catch (err) {
        console.error(`Tick error:`, err);
      }
      await sleep(LOOP_SLEEP_MS);
    }
  }

  private async checkActivation() {
    console.log(`\nChecking oracle activation status...`);
    for (const oracle of this.oracles) {
      const obj = await this.client.getObject({
        id: oracle.oracleId,
        options: { showContent: true },
      });

      const content = obj.data?.content;
      if (content?.dataType === "moveObject") {
        const fields = content.fields as Record<string, unknown>;
        if (fields.active === true) {
          this.activated.add(oracle.oracleId);
          console.log(`  ${oracle.expiry} — already active`);
        } else {
          console.log(`  ${oracle.expiry} — needs activation`);
        }
      }
    }
  }

  private async tick() {
    const now = Date.now();
    const includeSvi = now - this.lastSviTime >= SVI_INTERVAL_MS;

    // 1. Fetch all API data in parallel
    const forwardPromises = this.oracles.map((o) => fetchForwardPrice(o.expiry));
    const sviPromises = includeSvi
      ? this.oracles.map((o) => fetchSVIParams(o.expiry))
      : [];

    const [spot, ...forwards] = await Promise.all([
      fetchSpotPrice(),
      ...forwardPromises,
    ]);
    const sviResults = includeSvi ? await Promise.all(sviPromises) : [];

    const spotScaled = scaleToU64(spot.price);

    // 2. Build PTB
    const tx = new Transaction();

    // Activate any inactive oracles first
    for (const oracle of this.oracles) {
      if (!this.activated.has(oracle.oracleId)) {
        tx.moveCall({
          target: `${pkg}::oracle::activate`,
          typeArguments: [oracle.underlying],
          arguments: [
            tx.object(oracle.oracleId),
            tx.object(oracleCapId),
            tx.object(CLOCK),
          ],
        });
        this.activated.add(oracle.oracleId);
        console.log(`  Activating ${oracle.expiry}`);
      }
    }

    // For each oracle: build price update calls
    for (let i = 0; i < this.oracles.length; i++) {
      const oracle = this.oracles[i];
      const forwardScaled = scaleToU64(forwards[i].price);

      const priceData = tx.moveCall({
        target: `${pkg}::oracle::new_price_data`,
        arguments: [tx.pure.u64(spotScaled), tx.pure.u64(forwardScaled)],
      });

      tx.moveCall({
        target: `${pkg}::oracle::update_prices`,
        typeArguments: [oracle.underlying],
        arguments: [
          tx.object(oracle.oracleId),
          tx.object(oracleCapId),
          priceData,
          tx.object(CLOCK),
        ],
      });
    }

    // Every ~20s: also push SVI params per expiry
    if (includeSvi) {
      for (let i = 0; i < this.oracles.length; i++) {
        const oracle = this.oracles[i];
        const svi = sviResults[i];
        const rho = signedParam(svi.rho);
        const m = signedParam(svi.m);
        const rateScaled = scaleToU64(0.035); // domestic risk-free rate

        const sviParams = tx.moveCall({
          target: `${pkg}::oracle::new_svi_params`,
          arguments: [
            tx.pure.u64(scaleToU64(svi.a)),
            tx.pure.u64(scaleToU64(svi.b)),
            tx.pure.u64(rho.magnitude),
            tx.pure.bool(rho.negative),
            tx.pure.u64(m.magnitude),
            tx.pure.bool(m.negative),
            tx.pure.u64(scaleToU64(svi.sigma)),
          ],
        });

        tx.moveCall({
          target: `${pkg}::oracle::update_svi`,
          typeArguments: [oracle.underlying],
          arguments: [
            tx.object(oracle.oracleId),
            tx.object(oracleCapId),
            sviParams,
            tx.pure.u64(rateScaled),
            tx.object(CLOCK),
          ],
        });
      }

      this.lastSviTime = now;
    }

    // 3. Sign and execute
    const result = await this.client.signAndExecuteTransaction({
      transaction: tx,
      signer: this.signer,
      options: { showEffects: true },
    });

    // 4. Wait for confirmation
    await this.client.waitForTransaction({ digest: result.digest });

    const status = result.effects?.status.status;
    const ts = new Date().toISOString();
    if (status === "success") {
      console.log(
        `[${ts}] OK  digest=${result.digest.slice(0, 16)}...` +
          (includeSvi ? " [+SVI]" : ""),
      );
    } else {
      console.error(`[${ts}] FAIL digest=${result.digest}`, result.effects?.status);
    }
  }
}

const service = new OracleFeedService();
service.start().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
