// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 3: mint a directional binary position (UP or DOWN bet on a
// strike). One PTB:
//   1. take DUSDC from the user's existing balance (merge + split)
//   2. deposit it into the caller's PredictManager
//   3. build a MarketKey from (oracle_id, expiry, strike, direction)
//   4. call predict::mint<DUSDC>
//
// The user's active sui-client address must already hold DUSDC. This script
// does NOT touch the treasury cap.

import { Transaction } from "@mysten/sui/transactions";
import { getActiveAddress, getClient, getSigner } from "../../utils/utils.js";
import {
  dusdcPackageID,
  predictObjectID,
  predictPackageID,
} from "../../config/constants.js";

// === Edit these for your trade =====================================
// Values are human units. The script scales them on the way to the chain.
//   STRIKE          → dollars (multiplied by 1e9 for the 9-decimal price)
//   QUANTITY/TOPUP  → DUSDC dollars (multiplied by 1e6)
// MANAGER_ID is unique per attendee — paste the id printed by
// pnpm predict-create-manager.
// ORACLE_ID / EXPIRY come from pnpm predict-list-markets.
const CONFIG = {
  MANAGER_ID:
    "0x51f082104ca41498acdbd6181786978117ae4cc34a72a9a847083ecffe0011ea",
  ORACLE_ID:
    "0x57ab16e132ef0083085d1bdef7ed820892a4d574155f47a3cba168dcb43deb79", // BTC 2026-05-29 08:00 UTC
  EXPIRY: 1780041600000, // ms since epoch
  STRIKE: 75_000, // $75,000
  DIRECTION: "up" as "up" | "down",
  QUANTITY: 100, // $1 face
  TOPUP: 100, // DUSDC to deposit before mint
  SKIP_TOPUP: false, // true → reuse manager's existing balance
};
// Env vars override CONFIG if set, using the same human units.
// ===================================================================

const network = "testnet" as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = "0x6";
const PRICE_SCALE = 1_000_000_000n; // 9 decimals for strikes/prices
const DUSDC_SCALE = 1_000_000n; // 6 decimals for quantities/DUSDC

(async () => {
  const client = getClient(network);
  const signer = getSigner();
  const address = getActiveAddress();

  const managerId = process.env.MANAGER_ID ?? CONFIG.MANAGER_ID;
  const oracleId = process.env.ORACLE_ID ?? CONFIG.ORACLE_ID;
  const expiry = BigInt(process.env.EXPIRY ?? CONFIG.EXPIRY);
  const strikeDollars = BigInt(process.env.STRIKE ?? CONFIG.STRIKE);
  const direction = (process.env.DIRECTION ?? CONFIG.DIRECTION).toLowerCase();
  const quantityDollars = BigInt(process.env.QUANTITY ?? CONFIG.QUANTITY);
  const topupDollars = BigInt(process.env.TOPUP ?? CONFIG.TOPUP);
  const skipTopup = process.env.SKIP_TOPUP
    ? process.env.SKIP_TOPUP === "1"
    : CONFIG.SKIP_TOPUP;

  if (managerId === "PASTE_YOUR_MANAGER_ID") {
    console.error(
      "Set MANAGER_ID in the CONFIG block (or as an env var). Run pnpm predict-create-manager first.",
    );
    process.exit(1);
  }
  if (direction !== "up" && direction !== "down") {
    console.error('DIRECTION must be "up" or "down"');
    process.exit(1);
  }

  const strike = strikeDollars * PRICE_SCALE;
  const quantity = quantityDollars * DUSDC_SCALE;
  const topup = topupDollars * DUSDC_SCALE;

  console.log(`Trader:    ${address}`);
  console.log(`Manager:   ${managerId}`);
  console.log(`Oracle:    ${oracleId}`);
  console.log(`Expiry:    ${new Date(Number(expiry)).toISOString()}`);
  console.log(`Strike:    $${strikeDollars}`);
  console.log(`Direction: ${direction.toUpperCase()}`);
  console.log(`Quantity:  $${quantityDollars} face`);
  console.log(
    `Top-up:    ${skipTopup ? "skipped" : `$${topupDollars} DUSDC`}\n`,
  );

  const tx = new Transaction();

  if (!skipTopup) {
    const coins = await client.getCoins({
      owner: address,
      coinType: DUSDC_TYPE,
    });
    if (coins.data.length === 0) {
      console.error(
        `No DUSDC found for ${address}. Ask the host to mint you DUSDC.`,
      );
      process.exit(1);
    }
    const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);
    if (total < topup) {
      console.error(
        `Insufficient DUSDC: have $${Number(total) / 1e6}, need $${topupDollars}`,
      );
      process.exit(1);
    }

    const primary = tx.object(coins.data[0].coinObjectId);
    if (coins.data.length > 1) {
      tx.mergeCoins(
        primary,
        coins.data.slice(1).map((c) => tx.object(c.coinObjectId)),
      );
    }
    const [depositCoin] = tx.splitCoins(primary, [tx.pure.u64(topup)]);
    tx.moveCall({
      target: `${predictPackageID[network]}::predict_manager::deposit`,
      typeArguments: [DUSDC_TYPE],
      arguments: [tx.object(managerId), depositCoin],
    });
  }

  const keyFn = direction === "up" ? "up" : "down";
  const key = tx.moveCall({
    target: `${predictPackageID[network]}::market_key::${keyFn}`,
    arguments: [tx.pure.id(oracleId), tx.pure.u64(expiry), tx.pure.u64(strike)],
  });

  tx.moveCall({
    target: `${predictPackageID[network]}::predict::mint`,
    typeArguments: [DUSDC_TYPE],
    arguments: [
      tx.object(predictObjectID[network]),
      tx.object(managerId),
      tx.object(oracleId),
      key,
      tx.pure.u64(quantity),
      tx.object(CLOCK),
    ],
  });

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showEvents: true },
  });

  if (result.effects?.status.status !== "success") {
    console.error("mint failed:", result.effects?.status);
    process.exit(1);
  }

  const minted = result.events?.find((e) =>
    e.type.endsWith("::predict::PositionMinted"),
  );
  if (minted) {
    console.log("PositionMinted event:");
    console.dir(minted.parsedJson, { depth: null });
  }
  console.log(`\nDigest: ${result.digest}`);
})();
