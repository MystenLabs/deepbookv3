// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 4: redeem a directional position back into the manager.
//
// Two modes:
//   - default (oracle still live):  predict::redeem
//   - SETTLED=true (oracle settled): predict::redeem_permissionless

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../../utils/utils.js";
import {
  dusdcPackageID,
  predictObjectID,
  predictPackageID,
} from "../../config/constants.js";

// === Edit these to match the position you want to close ============
// Values are human units. Strikes in dollars (×1e9). QUANTITY in DUSDC (×1e6).
// Must mirror the MarketKey of the position you minted.
const CONFIG = {
  MANAGER_ID:
    "0xb7f44301182aeaad54f2e35cbdef164ffa0bbb24aa84a6ab25d6ef05bd5310f0",
  ORACLE_ID:
    "0x57ab16e132ef0083085d1bdef7ed820892a4d574155f47a3cba168dcb43deb79", // BTC 2026-05-29 08:00 UTC
  EXPIRY: 1780041600000, // ms since epoch
  STRIKE: 75_000, // $75,000
  DIRECTION: "up" as "up" | "down",
  QUANTITY: 20, // $1 face to close
  SETTLED: false, // true → use redeem_permissionless
};
// Env vars override CONFIG if set.
// ===================================================================

const network = "testnet" as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const CLOCK = "0x6";
const PRICE_SCALE = 1_000_000_000n;
const DUSDC_SCALE = 1_000_000n;

(async () => {
  const client = getClient(network);
  const signer = getSigner();

  const managerId = process.env.MANAGER_ID ?? CONFIG.MANAGER_ID;
  const oracleId = process.env.ORACLE_ID ?? CONFIG.ORACLE_ID;
  const expiry = BigInt(process.env.EXPIRY ?? CONFIG.EXPIRY);
  const strikeDollars = BigInt(process.env.STRIKE ?? CONFIG.STRIKE);
  const direction = (process.env.DIRECTION ?? CONFIG.DIRECTION).toLowerCase();
  const quantityDollars = BigInt(process.env.QUANTITY ?? CONFIG.QUANTITY);
  const settled = process.env.SETTLED
    ? process.env.SETTLED === "1"
    : CONFIG.SETTLED;

  if (managerId === "PASTE_YOUR_MANAGER_ID") {
    console.error("Set MANAGER_ID in the CONFIG block (or as an env var).");
    process.exit(1);
  }
  if (direction !== "up" && direction !== "down") {
    console.error('DIRECTION must be "up" or "down"');
    process.exit(1);
  }

  const strike = strikeDollars * PRICE_SCALE;
  const quantity = quantityDollars * DUSDC_SCALE;
  const target = settled ? "redeem_permissionless" : "redeem";
  console.log(
    `Calling predict::${target} for ${direction.toUpperCase()} @ $${strikeDollars}, qty=$${quantityDollars}`,
  );

  const tx = new Transaction();
  const keyFn = direction === "up" ? "up" : "down";
  const key = tx.moveCall({
    target: `${predictPackageID[network]}::market_key::${keyFn}`,
    arguments: [tx.pure.id(oracleId), tx.pure.u64(expiry), tx.pure.u64(strike)],
  });

  tx.moveCall({
    target: `${predictPackageID[network]}::predict::${target}`,
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
    console.error("redeem failed:", result.effects?.status);
    process.exit(1);
  }

  const redeemed = result.events?.find((e) =>
    e.type.endsWith("::predict::PositionRedeemed"),
  );
  if (redeemed) {
    console.log("PositionRedeemed event:");
    console.dir(redeemed.parsedJson, { depth: null });
  }
  console.log(`\nDigest: ${result.digest}`);
})();
