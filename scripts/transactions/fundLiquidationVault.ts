// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { adminCapOwner, liquidationAdminCapID } from "../config/constants";

(async () => {
  const env = "mainnet";
  const tx = new Transaction();
  const vaultId =
    "0xae8e060630107720560d49e99f352b41a9f1696675021f087b69b57d35d814b6";

  const dbClient = new DeepBookClient({
    address: adminCapOwner[env],
    env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
  });

  // Amounts to deposit
  // const suiAmount = 5_494;
  const usdcAmount = 50_000;
  // const deepAmount = 190_000;
  // const walAmount = 73_000;

  // dbClient.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "SUI",
  //   suiAmount,
  // )(tx);

  dbClient.marginLiquidations.deposit(
    vaultId,
    liquidationAdminCapID[env],
    "USDC",
    usdcAmount,
  )(tx);

  // dbClient.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "DEEP",
  //   deepAmount,
  // )(tx);

  // dbClient.marginLiquidations.deposit(
  //   vaultId,
  //   liquidationAdminCapID[env],
  //   "WAL",
  //   walAmount,
  // )(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
