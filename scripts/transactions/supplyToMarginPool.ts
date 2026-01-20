// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { adminCapOwner, supplierCapID } from "../config/constants";

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
  const usdcAmount = 90_000;

  dbClient.marginPool.supplyToMarginPool("USDC", tx.object(supplierCapID[env]), usdcAmount)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
