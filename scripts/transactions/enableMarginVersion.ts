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
  const versionToEnable = 2;

  const client = new SuiGrpcClient({
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      marginAdminCap: marginAdminCapID[env],
    }),
  );

  const tx = new Transaction();

  client.deepbook.marginAdmin.enableVersion(versionToEnable)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
