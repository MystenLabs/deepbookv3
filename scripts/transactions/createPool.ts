// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { adminCapOwner, adminCapID } from "../config/constants";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";

(async () => {
  // Update constant for env
  const env = "mainnet";

  // Initialize with balance managers if needed
  const balanceManagers = {
    MANAGER_1: {
      address: "",
      tradeCap: "",
    },
  };

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    balanceManagers: balanceManagers,
    adminCap: adminCapID[env],
  });

  const tx = new Transaction();

  dbClient.deepBookAdmin.createPoolAdmin({
    baseCoinKey: "WAL",
    quoteCoinKey: "USDC",
    tickSize: 0.000001,
    lotSize: 0.1,
    minSize: 1,
    whitelisted: false,
    stablePool: false,
  })(tx);

  dbClient.deepBookAdmin.createPoolAdmin({
    baseCoinKey: "WAL",
    quoteCoinKey: "SUI",
    tickSize: 0.000001,
    lotSize: 0.1,
    minSize: 1,
    whitelisted: false,
    stablePool: false,
  })(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
