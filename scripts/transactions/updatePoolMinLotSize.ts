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
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      adminCap: adminCapID[env],
    }),
  );

  const tx = new Transaction();

  client.deepbook.deepBookAdmin.adjustMinLotSize("DEEP_USDC", 1, 10)(tx);
  client.deepbook.deepBookAdmin.adjustMinLotSize("DEEP_SUI", 1, 10)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
