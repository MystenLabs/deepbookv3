// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { adminCapOwner, liquidationAdminCapID } from "../config/constants.js";

(async () => {
  const env = "mainnet";
  const tx = new Transaction();
  const vaultId =
    "0xae8e060630107720560d49e99f352b41a9f1696675021f087b69b57d35d814b6";

  const client = new SuiGrpcClient({
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
    }),
  );

  // Amounts to deposit
  // const suiAmount = 5_494;
  const usdcAmount = 50_000;
  // const deepAmount = 190_000;
  // const walAmount = 73_000;

  // client.deepbook.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "SUI",
  //   suiAmount,
  // )(tx);

  client.deepbook.marginLiquidations.deposit(
    vaultId,
    liquidationAdminCapID[env],
    "USDC",
    usdcAmount,
  )(tx);

  // client.deepbook.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "DEEP",
  //   deepAmount,
  // )(tx);

  // client.deepbook.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "WAL",
  //   walAmount,
  // )(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
