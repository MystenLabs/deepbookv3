// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Parallel-lane oracle feed service.
///
/// Architecture:
///   Loop 1 (Poller) — fetches spot, forwards, and SVIs from BlockScholes API
///   Loop 2 (Sender) — reads latest snapshot, builds a PTB, and fires it
///     via round-robin across N pre-split gas coins (~1 tx/sec).
///
/// Usage: PRIVATE_KEY=... BLOCKSCHOLES_API_KEY=... pnpm oracle-feed

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../utils/utils";
import {
  predictPackageID,
  predictOracleCapID,
  predictOracleCapIDs,
} from "../config/constants";
import { predictOracles, type OracleEntry } from "../config/predict-oracles";
import {
  fetchSpotPrice,
  fetchForwardPrice,
  fetchSVIParams,
  type SVIParamsResult,
} from "./blockscholes-oracle";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const CLOCK = "0x6";
const FLOAT_SCALING = 1e9;
const NUM_GAS_LANES = 20;
const GAS_PER_LANE = 10_000_000_000; // 10 SUI
const API_POLL_MS = 500;
const TX_INTERVAL_MS = 1_000;
const SVI_POLL_MS = 20_000;

const network = "testnet" as const;
const pkg = predictPackageID[network];

// Use multi-cap array if populated, otherwise fall back to single cap
const capIDs =
  predictOracleCapIDs[network].length > 0
    ? predictOracleCapIDs[network]
    : [predictOracleCapID[network]];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function scaleToU64(value: number): number {
  return Math.round(value * FLOAT_SCALING);
}

function signedParam(value: number): { magnitude: number; negative: boolean } {
  return { magnitude: scaleToU64(Math.abs(value)), negative: value < 0 };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ObjectRef {
  objectId: string;
  version: string;
  digest: string;
}

interface GasLane {
  ref: ObjectRef;
  capId: string;
  inflight: Promise<any> | null;
  available: boolean;
}

interface OracleSnapshot {
  spotScaled: number;
  forwards: Map<string, number>; // oracleId -> scaled forward price
  svis: Map<string, SVIParamsResult> | null; // null = no SVI this tick
}

// ---------------------------------------------------------------------------
// OracleState — shared mutable state between poller and sender loops.
// Safe because JS is single-threaded (no torn reads).
// ---------------------------------------------------------------------------

class OracleState {
  private spotScaled: number | null = null;
  private forwards = new Map<string, number>();
  private svis = new Map<string, SVIParamsResult>();
  lastSviUpdate = 0;

  updatePrices(spotScaled: number, forwards: Map<string, number>) {
    this.spotScaled = spotScaled;
    for (const [k, v] of forwards) {
      this.forwards.set(k, v);
    }
  }

  updateSvis(svis: Map<string, SVIParamsResult>) {
    for (const [k, v] of svis) {
      this.svis.set(k, v);
    }
    this.lastSviUpdate = Date.now();
  }

  getSnapshot(includeSvi: boolean): OracleSnapshot | null {
    if (this.spotScaled === null || this.forwards.size === 0) return null;
    return {
      spotScaled: this.spotScaled,
      forwards: new Map(this.forwards),
      svis: includeSvi ? new Map(this.svis) : null,
    };
  }
}

// ---------------------------------------------------------------------------
// OracleFeedService
// ---------------------------------------------------------------------------

class OracleFeedService {
  private client;
  private signer;
  private oracles: OracleEntry[];
  private activated = new Set<string>();
  private state = new OracleState();
  private lanes: GasLane[] = [];
  private nextLane = 0;
  private lastSviPushed = 0;

  constructor() {
    this.client = getClient(network);
    this.signer = getSigner();
    this.oracles = predictOracles[network];

    if (this.oracles.length === 0) {
      throw new Error(`No oracles configured for ${network}`);
    }

    console.log(`Oracle Feed Service (parallel lanes)`);
    console.log(`  Network:   ${network}`);
    console.log(`  Package:   ${pkg}`);
    console.log(`  Caps:      ${capIDs.length}`);
    console.log(`  Oracles:   ${this.oracles.length}`);
    console.log(`  Gas lanes: ${NUM_GAS_LANES}`);
    this.oracles.forEach((o) =>
      console.log(`    ${o.expiry} -> ${o.oracleId.slice(0, 16)}...`),
    );
  }

  /** Returns only oracles that have not yet expired. */
  private activeOracles(): OracleEntry[] {
    const now = Date.now();
    return this.oracles.filter((o) => now < o.expiryMs);
  }

  async start() {
    await this.checkActivation();
    await this.initGasLanes();

    console.log(`\nStarting poller + sender loops...\n`);
    await Promise.all([this.pollerLoop(), this.senderLoop()]);
  }

  // -----------------------------------------------------------------------
  // Activation check — identical to the old service
  // -----------------------------------------------------------------------

  private async checkActivation() {
    console.log(`\nChecking oracle activation status...`);
    for (const oracle of this.activeOracles()) {
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

    const expired = this.oracles.length - this.activeOracles().length;
    if (expired > 0) {
      console.log(`  Skipping ${expired} expired oracle(s)`);
    }
  }

  // -----------------------------------------------------------------------
  // Gas lane initialization: merge all coins → split into N lanes
  // -----------------------------------------------------------------------

  private async initGasLanes() {
    const address = this.signer.toSuiAddress();
    console.log(`\nInitializing gas lanes for ${address}...`);

    // 1. Fetch all SUI coins with pagination
    const allCoins: Array<{
      coinObjectId: string;
      version: string;
      digest: string;
      balance: string;
    }> = [];
    let cursor: string | null | undefined = undefined;
    let hasNext = true;
    while (hasNext) {
      const page = await this.client.getCoins({
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
    const needed = BigInt(GAS_PER_LANE) * BigInt(NUM_GAS_LANES) + 100_000_000n; // lanes + budget for txns
    if (totalBalance < needed) {
      throw new Error(
        `Insufficient SUI balance: have ${totalBalance}, need ~${needed}`,
      );
    }

    // 2. If >1 coin, merge all into the first one
    let primaryRef: ObjectRef = {
      objectId: allCoins[0].coinObjectId,
      version: allCoins[0].version,
      digest: allCoins[0].digest,
    };

    if (allCoins.length > 1) {
      console.log(`  Merging ${allCoins.length} coins into one...`);
      const mergeTx = new Transaction();
      mergeTx.setGasPayment([primaryRef]);

      const otherRefs = allCoins.slice(1).map((c) =>
        mergeTx.object(c.coinObjectId),
      );
      mergeTx.mergeCoins(mergeTx.gas, otherRefs);

      const mergeResult = await this.client.signAndExecuteTransaction({
        transaction: mergeTx,
        signer: this.signer,
        options: { showEffects: true },
      });
      await this.client.waitForTransaction({ digest: mergeResult.digest });

      if (mergeResult.effects?.status.status !== "success") {
        throw new Error(
          `Merge failed: ${JSON.stringify(mergeResult.effects?.status)}`,
        );
      }

      // Update primary ref from effects
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

    // 3. Split into N lane coins
    console.log(`  Splitting into ${NUM_GAS_LANES} lanes (${GAS_PER_LANE / 1e9} SUI each)...`);
    const splitTx = new Transaction();
    splitTx.setGasPayment([primaryRef]);

    const amounts = Array.from({ length: NUM_GAS_LANES }, () =>
      splitTx.pure.u64(GAS_PER_LANE),
    );
    const coins = splitTx.splitCoins(splitTx.gas, amounts);

    for (let i = 0; i < NUM_GAS_LANES; i++) {
      splitTx.transferObjects([coins[i]], address);
    }

    const splitResult = await this.client.signAndExecuteTransaction({
      transaction: splitTx,
      signer: this.signer,
      options: { showEffects: true, showObjectChanges: true },
    });
    await this.client.waitForTransaction({ digest: splitResult.digest });

    if (splitResult.effects?.status.status !== "success") {
      throw new Error(
        `Split failed: ${JSON.stringify(splitResult.effects?.status)}`,
      );
    }

    // 4. Extract created coin refs from objectChanges
    const created = (splitResult.objectChanges ?? []).filter(
      (c) =>
        c.type === "created" &&
        "objectType" in c &&
        c.objectType === "0x2::coin::Coin<0x2::sui::SUI>",
    );

    if (created.length < NUM_GAS_LANES) {
      throw new Error(
        `Expected ${NUM_GAS_LANES} created coins, got ${created.length}`,
      );
    }

    this.lanes = created.slice(0, NUM_GAS_LANES).map((c, i) => ({
      ref: {
        objectId: "objectId" in c ? (c as any).objectId : "",
        version: "version" in c ? (c as any).version : "",
        digest: "digest" in c ? (c as any).digest : "",
      },
      capId: capIDs[i % capIDs.length],
      inflight: null,
      available: true,
    }));

    for (let i = 0; i < this.lanes.length; i++) {
      console.log(
        `  Lane ${i}: gas=${this.lanes[i].ref.objectId.slice(0, 16)}... cap=${this.lanes[i].capId.slice(0, 16)}...`,
      );
    }
    console.log(`  Split OK: ${splitResult.digest.slice(0, 16)}...`);
  }

  // -----------------------------------------------------------------------
  // Loop 1 — API Poller
  // -----------------------------------------------------------------------

  private async pollerLoop() {
    let lastSviFetch = 0;

    while (true) {
      try {
        const now = Date.now();
        const includeSvi = now - lastSviFetch >= SVI_POLL_MS;
        const live = this.activeOracles();

        // Fetch spot + all forwards in parallel
        const [spotResult, ...forwardResults] = await Promise.all([
          fetchSpotPrice(),
          ...live.map((o) => fetchForwardPrice(o.expiry)),
        ]);

        const spotScaled = scaleToU64(spotResult.price);
        const forwards = new Map<string, number>();
        for (let i = 0; i < live.length; i++) {
          forwards.set(
            live[i].oracleId,
            scaleToU64(forwardResults[i].price),
          );
        }
        this.state.updatePrices(spotScaled, forwards);

        // Every SVI_POLL_MS, also fetch SVIs
        if (includeSvi) {
          const sviResults = await Promise.all(
            live.map((o) => fetchSVIParams(o.expiry)),
          );
          const svis = new Map<string, SVIParamsResult>();
          for (let i = 0; i < live.length; i++) {
            svis.set(live[i].oracleId, sviResults[i]);
          }
          this.state.updateSvis(svis);
          lastSviFetch = Date.now();
        }
      } catch (err) {
        console.error(`[poller] Error:`, err);
      }

      await sleep(API_POLL_MS);
    }
  }

  // -----------------------------------------------------------------------
  // Loop 2 — Transaction Sender
  // -----------------------------------------------------------------------

  private async senderLoop() {
    // Wait for the first valid snapshot
    while (this.state.getSnapshot(false) === null) {
      await sleep(100);
    }
    console.log(`[sender] First snapshot available, starting send loop`);

    while (true) {
      try {
        await this.senderTick();
      } catch (err) {
        console.error(`[sender] Tick error:`, err);
      }
      await sleep(TX_INTERVAL_MS);
    }
  }

  private async senderTick() {
    const lane = this.lanes[this.nextLane];
    const laneIdx = this.nextLane;

    // If this lane has an in-flight tx, await it now
    if (lane.inflight !== null) {
      try {
        const result = await lane.inflight;
        const gasRef = result.effects?.gasObject?.reference;
        if (
          gasRef &&
          result.effects?.status.status === "success"
        ) {
          lane.ref = {
            objectId: gasRef.objectId,
            version: gasRef.version,
            digest: gasRef.digest,
          };
          lane.available = true;
          const ts = new Date().toISOString();
          console.log(
            `[${ts}] Lane ${laneIdx} OK  digest=${result.digest.slice(0, 16)}...`,
          );
        } else {
          console.error(
            `[sender] Lane ${laneIdx} tx failed:`,
            result.effects?.status,
          );
          await this.recoverLane(laneIdx);
        }
      } catch (err) {
        console.error(`[sender] Lane ${laneIdx} inflight error:`, err);
        await this.recoverLane(laneIdx);
      }
      lane.inflight = null;
    }

    // If lane is not available after recovery, skip
    if (!lane.available) {
      this.nextLane = (this.nextLane + 1) % NUM_GAS_LANES;
      return;
    }

    // Determine if SVI should be included
    const includeSvi = this.state.lastSviUpdate > this.lastSviPushed;
    const snapshot = this.state.getSnapshot(includeSvi);
    if (!snapshot) return;

    // Build the PTB
    const tx = this.buildPTB(snapshot, lane.capId);
    tx.setGasPayment([lane.ref]);

    // Fire non-blocking
    lane.inflight = this.client.signAndExecuteTransaction({
      transaction: tx,
      signer: this.signer,
      options: { showEffects: true },
    });
    lane.available = false;

    if (includeSvi) {
      this.lastSviPushed = this.state.lastSviUpdate;
    }

    this.nextLane = (this.nextLane + 1) % NUM_GAS_LANES;
  }

  // -----------------------------------------------------------------------
  // Lane recovery — re-fetch coin state from chain
  // -----------------------------------------------------------------------

  private async recoverLane(index: number) {
    const lane = this.lanes[index];
    try {
      const obj = await this.client.getObject({
        id: lane.ref.objectId,
        options: { showOwner: true },
      });
      if (obj.data) {
        lane.ref = {
          objectId: obj.data.objectId,
          version: obj.data.version,
          digest: obj.data.digest,
        };
        lane.available = true;
        console.log(`[sender] Lane ${index} recovered: ${lane.ref.objectId.slice(0, 16)}...`);
      } else {
        lane.available = false;
        console.error(`[sender] Lane ${index} coin not found — disabled`);
      }
    } catch (err) {
      lane.available = false;
      console.error(`[sender] Lane ${index} recovery failed:`, err);
    }
  }

  // -----------------------------------------------------------------------
  // Build PTB from snapshot
  // -----------------------------------------------------------------------

  private buildPTB(snapshot: OracleSnapshot, capId: string): Transaction {
    const tx = new Transaction();
    const live = this.activeOracles();

    // Activate any inactive oracles
    for (const oracle of live) {
      if (!this.activated.has(oracle.oracleId)) {
        tx.moveCall({
          target: `${pkg}::oracle::activate`,
          typeArguments: [oracle.underlying],
          arguments: [
            tx.object(oracle.oracleId),
            tx.object(capId),
            tx.object(CLOCK),
          ],
        });
        this.activated.add(oracle.oracleId);
        console.log(`  Activating ${oracle.expiry}`);
      }
    }

    // Price updates for each oracle
    for (const oracle of live) {
      const forwardScaled =
        snapshot.forwards.get(oracle.oracleId) ?? snapshot.spotScaled;

      const priceData = tx.moveCall({
        target: `${pkg}::oracle::new_price_data`,
        arguments: [
          tx.pure.u64(snapshot.spotScaled),
          tx.pure.u64(forwardScaled),
        ],
      });

      tx.moveCall({
        target: `${pkg}::oracle::update_prices`,
        typeArguments: [oracle.underlying],
        arguments: [
          tx.object(oracle.oracleId),
          tx.object(capId),
          priceData,
          tx.object(CLOCK),
        ],
      });
    }

    // SVI updates (only when snapshot includes fresh SVIs)
    if (snapshot.svis !== null) {
      for (const oracle of live) {
        const svi = snapshot.svis.get(oracle.oracleId);
        if (!svi) continue;

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
            tx.object(capId),
            sviParams,
            tx.pure.u64(rateScaled),
            tx.object(CLOCK),
          ],
        });
      }
    }

    return tx;
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const service = new OracleFeedService();
service.start().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
