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

  const dbClient = new DeepBookClient({
    address: adminCapOwner[env],
    env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
  });

  dbClient.marginLiquidations.createLiquidationVault(
    liquidationAdminCapID[env]
  )(tx);
  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
