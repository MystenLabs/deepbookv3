// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { adminCapOwner, marginAdminCapID } from "../config/constants";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const versionToEnable = 2;

  const dbClient = new DeepBookClient({
    address: adminCapOwner[env],
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    marginAdminCap: marginAdminCapID[env],
  });

  const tx = new Transaction();

  dbClient.marginAdmin.enableVersion(versionToEnable)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
