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

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
    }),
  );

  client.deepbook.marginLiquidations.createLiquidationVault(
    liquidationAdminCapID[env],
  )(tx);
  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
