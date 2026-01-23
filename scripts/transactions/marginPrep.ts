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
  // Update constant for env
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
  // const maxAgeSeconds = 70;
  // const pythConfig = dbClient.marginAdmin.newPythConfig(
  //   [
  //     { coinKey: "SUI", maxConfBps: 300, maxEwmaDifferenceBps: 1500 }, // maxConfBps: 3%, maxEwmaDifferenceBps: 15%
  //     { coinKey: "USDC", maxConfBps: 100, maxEwmaDifferenceBps: 500 }, // maxConfBps: 1%, maxEwmaDifferenceBps: 5%
  //     { coinKey: "DEEP", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //     { coinKey: "WAL", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
  //   ],
  //   maxAgeSeconds // maxAgeSeconds: 70 seconds
  // )(tx);
  // dbClient.marginAdmin.removeConfig()(tx);
  // dbClient.marginAdmin.addConfig(pythConfig)(tx);

  // // 5. Create margin pools
  // const USDCprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
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
  // dbClient.marginMaintainer.createMarginPool("USDC", USDCprotocolConfig)(tx);

  // const SUIprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
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
  // dbClient.marginMaintainer.createMarginPool("SUI", SUIprotocolConfig)(tx);

  // const DEEPprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
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
  // dbClient.marginMaintainer.createMarginPool("DEEP", DEEPprotocolConfig)(tx);

  // const WALprotocolConfig = dbClient.marginMaintainer.newProtocolConfig(
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
  // dbClient.marginMaintainer.createMarginPool("WAL", WALprotocolConfig)(tx);

  // // 3. Registering SUI_DBUSDC pool
  // const PoolConfigSUIUSDC = dbClient.marginAdmin.newPoolConfig("SUI_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.2499,
  //   liquidationRiskRatio: 1.1,
  //   targetLiquidationRiskRatio: 1.25,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);

  // dbClient.marginAdmin.registerDeepbookPool("SUI_USDC", PoolConfigSUIUSDC)(tx);
  // dbClient.marginAdmin.enableDeepbookPool("SUI_USDC")(tx);

  // const PoolConfigDEEPUSDC = dbClient.marginAdmin.newPoolConfig("DEEP_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.4999,
  //   liquidationRiskRatio: 1.2,
  //   targetLiquidationRiskRatio: 1.5,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);
  // dbClient.marginAdmin.registerDeepbookPool(
  //   "DEEP_USDC",
  //   PoolConfigDEEPUSDC
  // )(tx);
  // dbClient.marginAdmin.enableDeepbookPool("DEEP_USDC")(tx);

  // const poolConfigWalUsdc = dbClient.marginAdmin.newPoolConfig("WAL_USDC", {
  //   minWithdrawRiskRatio: 2,
  //   minBorrowRiskRatio: 1.4999,
  //   liquidationRiskRatio: 1.2,
  //   targetLiquidationRiskRatio: 1.5,
  //   userLiquidationReward: 0.02,
  //   poolLiquidationReward: 0.03,
  // })(tx);
  // dbClient.marginAdmin.registerDeepbookPool("WAL_USDC", poolConfigWalUsdc)(tx);
  // dbClient.marginAdmin.enableDeepbookPool("WAL_USDC")(tx);

  // // 4. Enable deepbook pool for loan
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "SUI_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "DEEP_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "WAL_USDC",
  //   "USDC",
  //   tx.object(usdcMarginPoolCapID[env])
  // )(tx);
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "DEEP_USDC",
  //   "DEEP",
  //   tx.object(deepMarginPoolCapID[env])
  // )(tx);
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "SUI_USDC",
  //   "SUI",
  //   tx.object(suiMarginPoolCapID[env])
  // )(tx);
  // dbClient.marginMaintainer.enableDeepbookPoolForLoan(
  //   "WAL_USDC",
  //   "WAL",
  //   tx.object(walMarginPoolCapID[env])
  // )(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
