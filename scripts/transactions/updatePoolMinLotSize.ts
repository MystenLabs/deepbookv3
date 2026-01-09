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

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    adminCap: adminCapID[env],
  });

  const tx = new Transaction();

  dbClient.deepBookAdmin.adjustMinLotSize("DEEP_USDC", 1, 10)(tx);
  dbClient.deepBookAdmin.adjustMinLotSize("DEEP_SUI", 1, 10)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
