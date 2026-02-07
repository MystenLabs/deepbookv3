// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import {
  adminCapOwner,
  adminCapID,
  marginAdminCapID,
  marginMaintainerCapID,
  suiMarginPoolCapID,
  usdcMarginPoolCapID,
  deepMarginPoolCapID,
  walMarginPoolCapID,
} from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  const env = "mainnet";

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      adminCap: adminCapID[env],
      marginAdminCap: marginAdminCapID[env],
      marginMaintainerCap: marginMaintainerCapID[env],
    }),
  );

  const tx = new Transaction();

  // client.deepbook.marginMaintainer.updateInterestParams(
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env]),
  //   {
  //     baseRate: 0,
  //     baseSlope: 0.15,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  // client.deepbook.marginMaintainer.updateMarginPoolConfig(
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env]),
  //   {
  //     supplyCap: 2_000_000,
  //     maxUtilizationRate: 0.9,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 400_000,
  //     rateLimitRefillRatePerMs: 0.018518, // 400_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  // )(tx);

  // client.deepbook.marginMaintainer.updateInterestParams(
  //   "SUI",
  //   tx.object(suiMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.03,
  //     baseSlope: 0.2,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  // client.deepbook.marginMaintainer.updateMarginPoolConfig(
  //   "SUI",
  //   tx.object(suiMarginPoolCapID[env]),
  //   {
  //     supplyCap: 1_000_000,
  //     maxUtilizationRate: 0.9,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 200_000,
  //     rateLimitRefillRatePerMs: 0.00925926, // 200_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  // )(tx);

  // client.deepbook.marginMaintainer.updateInterestParams(
  //   "DEEP",
  //   tx.object(deepMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.05,
  //     baseSlope: 0.25,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  client.deepbook.marginMaintainer.updateMarginPoolConfig(
    "DEEP",
    tx.object(deepMarginPoolCapID[env]),
    {
      supplyCap: 30_000_000,
      maxUtilizationRate: 0.9,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 6_000_000,
      rateLimitRefillRatePerMs: 0.277778, // 6_000_000 / 21_600_000 (6 hours)
      rateLimitEnabled: true,
    },
  )(tx);

  // client.deepbook.marginMaintainer.updateInterestParams(
  //   "WAL",
  //   tx.object(walMarginPoolCapID[env]),
  //   {
  //     baseRate: 0.05,
  //     baseSlope: 0.25,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   },
  // )(tx);

  // client.deepbook.marginMaintainer.updateMarginPoolConfig(
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
