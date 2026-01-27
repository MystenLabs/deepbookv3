// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import {
  adminCapOwner,
  adminCapID,
  marginAdminCapID,
  marginMaintainerCapID,
  suiMarginPoolCapID,
  usdcMarginPoolCapID,
  deepMarginPoolCapID,
  walMarginPoolCapID,
} from "../config/constants";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";

(async () => {
  const env = "mainnet";

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    adminCap: adminCapID[env],
    marginAdminCap: marginAdminCapID[env],
    marginMaintainerCap: marginMaintainerCapID[env],
  });

  const tx = new Transaction();

  // dbClient.marginMaintainer.updateInterestParams(
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env]),
  //   {
  //     baseRate: 0,
  //     baseSlope: 0.15,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  dbClient.marginMaintainer.updateMarginPoolConfig(
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
    {
      supplyCap: 2_000_000,
      maxUtilizationRate: 0.9,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 400_000,
      rateLimitRefillRatePerMs: 0.018518, // 400_000 / 21_600_000 (6 hours)
      rateLimitEnabled: true,
    },
  )(tx);

  // dbClient.marginMaintainer.updateInterestParams(
  //   "SUI",
  //   tx.object(suiMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.03,
  //     baseSlope: 0.2,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  dbClient.marginMaintainer.updateMarginPoolConfig(
    "SUI",
    tx.object(suiMarginPoolCapID[env]),
    {
      supplyCap: 1_000_000,
      maxUtilizationRate: 0.9,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 200_000,
      rateLimitRefillRatePerMs: 0.00925926, // 200_000 / 21_600_000 (6 hours)
      rateLimitEnabled: true,
    },
  )(tx);

  // dbClient.marginMaintainer.updateInterestParams(
  //   "DEEP",
  //   tx.object(deepMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.05,
  //     baseSlope: 0.25,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  // dbClient.marginMaintainer.updateMarginPoolConfig(
  //   "DEEP",
  //   tx.object(deepMarginPoolCapID[env]),
  //   {
  //     supplyCap: 20_000_000,
  //     maxUtilizationRate: 0.9,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 4_000_000,
  //     rateLimitRefillRatePerMs: 0.185185, // 4_000_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  // )(tx);

  // dbClient.marginMaintainer.updateInterestParams(
  //   "WAL",
  //   tx.object(walMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.05,
  //     baseSlope: 0.25,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  // dbClient.marginMaintainer.updateMarginPoolConfig(
  //   "WAL",
  //   tx.object(walMarginPoolCapID[env]),
  //   {
  //     supplyCap: 7_000_000,
  //     maxUtilizationRate: 0.9,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 1_400_000,
  //     rateLimitRefillRatePerMs: 0.064814815, // 1_400_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  // )(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
