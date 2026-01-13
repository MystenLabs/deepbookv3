// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import {
  adminCapOwner,
  adminCapID,
  marginAdminCapID,
} from "../config/constants";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const marginMaintainerCap =
    "0xfa7c092fac70a0c2f9e8245748449c087727646ffe80e08efe702e4114402c9e";

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    adminCap: adminCapID[env],
    marginAdminCap: marginAdminCapID[env],
    marginMaintainerCap,
  });

  const tx = new Transaction();

  // // 1. Enable Margin package in core deepbook
  // dbClient.deepBookAdmin.authorizeMarginApp()(tx);

  // // 2. PauseCap distribution
  // const pauseCap1 = dbClient.marginAdmin.mintPauseCap()(tx);
  // const pauseCap2 = dbClient.marginAdmin.mintPauseCap()(tx);
  // const pauseCap3 = dbClient.marginAdmin.mintPauseCap()(tx);
  // tx.transferObjects(
  //   [pauseCap1],
  //   "0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c"
  // );
  // tx.transferObjects(
  //   [pauseCap2],
  //   "0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192"
  // );
  // tx.transferObjects(
  //   [pauseCap3],
  //   "0x7da4267928e568da4f64f5a80f5b63680f3c2e008f4f96f475b60ff1c48c0dcf"
  // );

  // // 3. Mint maintainerCap
  // const maintainerCap = dbClient.marginAdmin.mintMaintainerCap()(tx);
  // tx.transferObjects([maintainerCap], adminCapOwner[env]);

  // // 4. Pyth Config
  // const pythConfig = dbClient.marginAdmin.newPythConfig(
  //   [
  //     { coinKey: "SUI", maxConfBps: 300, maxEwmaDifferenceBps: 1500 }, // maxConfBps: 3%, maxEwmaDifferenceBps: 15%
  //     { coinKey: "USDC", maxConfBps: 100, maxEwmaDifferenceBps: 500 }, // maxConfBps: 1%, maxEwmaDifferenceBps: 5%
  //     { coinKey: "DEEP", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //     { coinKey: "WAL", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //   ],
  //   30 // maxAgeSeconds: 30 seconds
  // )(tx);
  // dbClient.marginAdmin.addConfig(pythConfig)(tx);

  // 5. Create margin pools
  const USDCprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
    "USDC",
    {
      supplyCap: 1_000_000,
      maxUtilizationRate: 0.9,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 200_000,
      rateLimitRefillRatePerMs: 0.002315, // 200_000 / 86_400_000
      rateLimitEnabled: true,
    },
    {
      baseRate: 0.05,
      baseSlope: 0.25,
      optimalUtilization: 0.85,
      excessSlope: 5,
    }
  )(tx);
  dbClient.marginMaintainer.createMarginPool("USDC", USDCprotocolConfig)(tx);

  const SUIprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
    "SUI",
    {
      supplyCap: 500_000,
      maxUtilizationRate: 0.8,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 100_000,
      rateLimitRefillRatePerMs: 0.001157407, // 100_000 / 86_400_000
      rateLimitEnabled: true,
    },
    {
      baseRate: 0.05,
      baseSlope: 0.25,
      optimalUtilization: 0.75,
      excessSlope: 5,
    }
  )(tx);
  dbClient.marginMaintainer.createMarginPool("SUI", SUIprotocolConfig)(tx);

  const DEEPprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
    "DEEP",
    {
      supplyCap: 20_000_000,
      maxUtilizationRate: 0.8,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 4_000_000,
      rateLimitRefillRatePerMs: 0.046296, // 4_000_000 / 86_400_000
      rateLimitEnabled: true,
    },
    {
      baseRate: 0.1,
      baseSlope: 0.35,
      optimalUtilization: 0.7,
      excessSlope: 5,
    }
  )(tx);
  dbClient.marginMaintainer.createMarginPool("DEEP", DEEPprotocolConfig)(tx);

  const WALprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
    "WAL",
    {
      supplyCap: 7_000_000,
      maxUtilizationRate: 0.8,
      referralSpread: 0.2,
      minBorrow: 0.00001,
      rateLimitCapacity: 1_400_000,
      rateLimitRefillRatePerMs: 0.016203704, // 1_400_000 / 86_400_000
      rateLimitEnabled: true,
    },
    {
      baseRate: 0.1,
      baseSlope: 0.35,
      optimalUtilization: 0.7,
      excessSlope: 5,
    }
  )(tx);
  dbClient.marginMaintainer.createMarginPool("WAL", WALprotocolConfig)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
