// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, marginAdminCapID } from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const poolKeys = [
    "SUI_USDC",
    "WAL_USDC",
    "DEEP_USDC",
    "SUIUSDE_USDC",
    "SUI_SUIUSDE",
    "XBTC_USDC",
  ];

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      marginAdminCap: marginAdminCapID[env],
    }),
  );

  const tx = new Transaction();

  for (const poolKey of poolKeys) {
    client.deepbook.marginAdmin.disableDeepbookPool(poolKey)(tx);
  }

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
