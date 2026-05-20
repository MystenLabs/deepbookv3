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
  suiUsdeMarginPoolCapID,
  usdSuiMarginPoolCapID,
  xbtcMarginPoolCapID,
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
      address: adminCapOwner[env],
      adminCap: adminCapID[env],
      marginAdminCap: marginAdminCapID[env],
      marginMaintainerCap: marginMaintainerCapID[env],
    }),
  );

  const tx = new Transaction();

  // Step 1: Disable old margin package versions 3 and 4 (v5 is the live version)
  client.deepbook.marginAdmin.disableVersion(3)(tx);
  client.deepbook.marginAdmin.disableVersion(4)(tx);

  // Step 2: Mint 3 DeepbookCorePauseCaps and distribute to ops addresses
  //   - 2 caps to 0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c
  //   - 1 cap  to 0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192
  const corePauseCap1 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap2 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap3 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  tx.transferObjects(
    [corePauseCap1, corePauseCap2],
    "0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c",
  );
  tx.transferObjects(
    [corePauseCap3],
    "0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192",
  );

  // Step 3: Re-enable margin trading on the 6 pairs.
  // All 6 pools (SUI_USDC, DEEP_USDC, WAL_USDC, SUI_SUIUSDE, SUIUSDE_USDC, XBTC_USDC)
  // were previously registered and are currently disabled. pool_registry persists
  // across disable_version, so re-registering would abort with EPoolAlreadyRegistered.
  // USDSUI pairs intentionally remain disabled in margin.
  client.deepbook.marginAdmin.enableDeepbookPool("SUI_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("DEEP_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("WAL_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("SUI_SUIUSDE")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("SUIUSDE_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("XBTC_USDC")(tx);

  // Step 4: Enable each (pair, asset) loan flow for the 6 enabled pairs
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_USDC",
    "SUI",
    tx.object(suiMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "DEEP_USDC",
    "DEEP",
    tx.object(deepMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "DEEP_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "WAL_USDC",
    "WAL",
    tx.object(walMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "WAL_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_SUIUSDE",
    "SUI",
    tx.object(suiMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_SUIUSDE",
    "SUIUSDE",
    tx.object(suiUsdeMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUIUSDE_USDC",
    "SUIUSDE",
    tx.object(suiUsdeMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUIUSDE_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "XBTC_USDC",
    "XBTC",
    tx.object(xbtcMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "XBTC_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);

  // Step 5: Stage loan flow for USDSUI pairs (pairs stay disabled in margin)
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_USDSUI",
    "SUI",
    tx.object(suiMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "SUI_USDSUI",
    "USDSUI",
    tx.object(usdSuiMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "USDSUI_USDC",
    "USDSUI",
    tx.object(usdSuiMarginPoolCapID[env]),
  )(tx);
  client.deepbook.marginMaintainer.enableDeepbookPoolForLoan(
    "USDSUI_USDC",
    "USDC",
    tx.object(usdcMarginPoolCapID[env]),
  )(tx);

  const res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
