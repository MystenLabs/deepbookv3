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
  // Update constant for env
  const env = "mainnet";

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      adminCap: adminCapID[env],
      marginAdminCap: marginAdminCapID[env],
      marginMaintainerCap: marginMaintainerCapID[env],
    }),
  );

  const tx = new Transaction();

  // // 1. Enable Margin package in core deepbook
  // client.deepbook.deepBookAdmin.authorizeMarginApp()(tx);

  // // 2. PauseCap distribution
  // const pauseCap1 = client.deepbook.marginAdmin.mintPauseCap()(tx);
  // const pauseCap2 = client.deepbook.marginAdmin.mintPauseCap()(tx);
  // const pauseCap3 = client.deepbook.marginAdmin.mintPauseCap()(tx);
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
  // const maintainerCap = client.deepbook.marginAdmin.mintMaintainerCap()(tx);
  // tx.transferObjects([maintainerCap], adminCapOwner[env]);

  // // 4. Pyth Config
  // const maxAgeSeconds = 70;
  // const pythConfig = client.deepbook.marginAdmin.newPythConfig(
  //   [
  //     { coinKey: "SUI", maxConfBps: 300, maxEwmaDifferenceBps: 1500 }, // maxConfBps: 3%, maxEwmaDifferenceBps: 15%
  //     { coinKey: "USDC", maxConfBps: 100, maxEwmaDifferenceBps: 500 }, // maxConfBps: 1%, maxEwmaDifferenceBps: 5%
  //     { coinKey: "DEEP", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //     { coinKey: "WAL", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //   ],
  //   maxAgeSeconds // maxAgeSeconds: 70 seconds
  // )(tx);
  // client.deepbook.marginAdmin.removeConfig()(tx);
  // client.deepbook.marginAdmin.addConfig(pythConfig)(tx);

  // // 5. Create margin pools
  // const USDCprotocolConfig = client.deepbook.marginMaintainer.newProtocolConfig(
  //   "USDC",
  //   {
  //     supplyCap: 1_000_000,
  //     maxUtilizationRate: 0.8,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 200_000,
  //     rateLimitRefillRatePerMs: 0.009259, // 200_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  //   {
  //     baseRate: 0.1,
  //     baseSlope: 0.15,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   }
  // )(tx);
  // client.deepbook.marginMaintainer.createMarginPool("USDC", USDCprotocolConfig)(tx);

  // const SUIprotocolConfig = client.deepbook.marginMaintainer.newProtocolConfig(
  //   "SUI",
  //   {
  //     supplyCap: 500_000,
  //     maxUtilizationRate: 0.8,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 100_000,
  //     rateLimitRefillRatePerMs: 0.00462963, // 100_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  //   {
  //     baseRate: 0.1,
  //     baseSlope: 0.2,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   }
  // )(tx);
  // client.deepbook.marginMaintainer.createMarginPool("SUI", SUIprotocolConfig)(tx);

  // const DEEPprotocolConfig = client.deepbook.marginMaintainer.newProtocolConfig(
  //   "DEEP",
  //   {
  //     supplyCap: 20_000_000,
  //     maxUtilizationRate: 0.8,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 4_000_000,
  //     rateLimitRefillRatePerMs: 0.185185, // 4_000_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  //   {
  //     baseRate: 0.15,
  //     baseSlope: 0.2,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   }
  // )(tx);
  // client.deepbook.marginMaintainer.createMarginPool("DEEP", DEEPprotocolConfig)(tx);

  // const WALprotocolConfig = client.deepbook.marginMaintainer.newProtocolConfig(
  //   "WAL",
  //   {
  //     supplyCap: 7_000_000,
  //     maxUtilizationRate: 0.8,
  //     referralSpread: 0.2,
  //     minBorrow: 0.1,
  //     rateLimitCapacity: 1_400_000,
  //     rateLimitRefillRatePerMs: 0.064814815, // 1_400_000 / 21_600_000 (6 hours)
  //     rateLimitEnabled: true,
  //   },
  //   {
  //     baseRate: 0.15,
  //     baseSlope: 0.2,
  //     optimalUtilization: 0.8,
  //     excessSlope: 5,
  //   }
  // )(tx);
  // client.deepbook.marginMaintainer.createMarginPool("WAL", WALprotocolConfig)(tx);

  const USDEprotocolConfig = client.deepbook.marginMaintainer.newProtocolConfig(
    "USDE",
    {
      supplyCap: 1_000_000,
      maxUtilizationRate: 0.8,
      referralSpread: 0.2,
      minBorrow: 0.1,
      rateLimitCapacity: 200_000,
      rateLimitRefillRatePerMs: 0.009259, // 200_000 / 21_600_000 (6 hours)
      rateLimitEnabled: true,
    },
    {
      baseRate: 0.15,
      baseSlope: 0.2,
      optimalUtilization: 0.8,
      excessSlope: 5,
    },
  )(tx);
  client.deepbook.marginMaintainer.createMarginPool(
    "USDE",
    USDEprotocolConfig,
  )(tx);

  // // 3. Registering SUI_DBUSDC pool
  // const PoolConfigSUIUSDC = client.deepbook.marginAdmin.newPoolConfig("SUI_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.2499,
  //   liquidationRiskRatio: 1.1,
  //   targetLiquidationRiskRatio: 1.25,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);

  // client.deepbook.marginAdmin.registerDeepbookPool("SUI_USDC", PoolConfigSUIUSDC)(tx);
  // client.deepbook.marginAdmin.enableDeepbookPool("SUI_USDC")(tx);

  // const PoolConfigDEEPUSDC = client.deepbook.marginAdmin.newPoolConfig("DEEP_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.4999,
  //   liquidationRiskRatio: 1.2,
  //   targetLiquidationRiskRatio: 1.5,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);
  // client.deepbook.marginAdmin.registerDeepbookPool(
  //   "DEEP_USDC",
  //   PoolConfigDEEPUSDC
  // )(tx);
  // client.deepbook.marginAdmin.enableDeepbookPool("DEEP_USDC")(tx);

  // const poolConfigWalUsdc = client.deepbook.marginAdmin.newPoolConfig("WAL_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.4999,
  //   liquidationRiskRatio: 1.2,
  //   targetLiquidationRiskRatio: 1.5,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);
  // client.deepbook.marginAdmin.registerDeepbookPool("WAL_USDC", poolConfigWalUsdc)(tx);
  // client.deepbook.marginAdmin.enableDeepbookPool("WAL_USDC")(tx);

  // // 4. Enable deepbook pool for loan
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "SUI_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "DEEP_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "WAL_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "DEEP_USDC",
  //   "DEEP",
  //   tx.object(deepMarginPoolCapID[env])
  // )(tx);
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "SUI_USDC",
  //   "SUI",
  //   tx.object(suiMarginPoolCapID[env])
  // )(tx);
  // client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
  //   "WAL_USDC",
  //   "WAL",
  //   tx.object(walMarginPoolCapID[env])
  // )(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
