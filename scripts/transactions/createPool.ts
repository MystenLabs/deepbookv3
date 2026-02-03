// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, adminCapID } from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";

  const client = new SuiGrpcClient({
    baseUrl: "https://fullnode.mainnet.sui.io:443",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      adminCap: adminCapID[env],
    }),
  );

  const tx = new Transaction();

  client.deepbook.deepBookAdmin.createPoolAdmin({
    baseCoinKey: "SUI",
    quoteCoinKey: "USDE",
    tickSize: 0.0001,
    lotSize: 0.1,
    minSize: 0.1,
    whitelisted: false,
    stablePool: false,
  })(tx);

  client.deepbook.deepBookAdmin.createPoolAdmin({
    baseCoinKey: "USDE",
    quoteCoinKey: "USDC",
    tickSize: 0.000001,
    lotSize: 0.1,
    minSize: 0.1,
    whitelisted: false,
    stablePool: true,
  })(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
