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

  // Step 1: Disable margin package versions 3 and 4
  client.deepbook.marginAdmin.disableVersion(3)(tx);
  client.deepbook.marginAdmin.disableVersion(4)(tx);

  // Step 2: Mint 5 DeepbookCorePauseCaps and distribute
  //   - 2 to 0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c
  //   - 1 to 0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192
  //   - 1 to 0xe9584eb3262c8cee0d0e8ff4fe4f20c5053e4748a23a4c46954d0c21fbbf0aff
  //   - 1 to 0x361b079475aa70e00ee71022168a7eb0ea4ace066c4c0d7bec4a66d721deec0a
  const corePauseCap1 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap2 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap3 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap4 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  const corePauseCap5 = client.deepbook.deepBookAdmin.mintCorePauseCap()(tx);
  tx.transferObjects(
    [corePauseCap1, corePauseCap2],
    "0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c",
  );
  tx.transferObjects(
    [corePauseCap3],
    "0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192",
  );
  tx.transferObjects(
    [corePauseCap4],
    "0xe9584eb3262c8cee0d0e8ff4fe4f20c5053e4748a23a4c46954d0c21fbbf0aff",
  );
  tx.transferObjects(
    [corePauseCap5],
    "0x361b079475aa70e00ee71022168a7eb0ea4ace066c4c0d7bec4a66d721deec0a",
  );

  // Step 3: Mint 3 margin pause caps and distribute
  //   - 1 to 0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c
  //   - 1 to 0xe9584eb3262c8cee0d0e8ff4fe4f20c5053e4748a23a4c46954d0c21fbbf0aff
  //   - 1 to 0x361b079475aa70e00ee71022168a7eb0ea4ace066c4c0d7bec4a66d721deec0a
  const marginPauseCap1 = client.deepbook.marginAdmin.mintPauseCap()(tx);
  const marginPauseCap2 = client.deepbook.marginAdmin.mintPauseCap()(tx);
  const marginPauseCap3 = client.deepbook.marginAdmin.mintPauseCap()(tx);
  tx.transferObjects(
    [marginPauseCap1],
    "0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c",
  );
  tx.transferObjects(
    [marginPauseCap2],
    "0xe9584eb3262c8cee0d0e8ff4fe4f20c5053e4748a23a4c46954d0c21fbbf0aff",
  );
  tx.transferObjects(
    [marginPauseCap3],
    "0x361b079475aa70e00ee71022168a7eb0ea4ace066c4c0d7bec4a66d721deec0a",
  );

  // Step 4: Enable margin trading on the 6 pairs
  client.deepbook.marginAdmin.enableDeepbookPool("SUI_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("DEEP_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("WAL_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("SUI_SUIUSDE")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("SUIUSDE_USDC")(tx);
  client.deepbook.marginAdmin.enableDeepbookPool("XBTC_USDC")(tx);

  // Step 5: Enable each (pair, asset) loan flow for the 6 pairs
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

  const res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
