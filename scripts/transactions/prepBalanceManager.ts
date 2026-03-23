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
  const balanceManagers = {
    BALANCE_MANAGER_1: {
      address:
        "0xedd38a1faf45147923c4b020af940e1e09f0888d311e45267ed2bd05b5f648a8",
    },
    BALANCE_MANAGER_2: {
      address:
        "0xc915672c93be17e55a35455a24a600fccf81afe1beb81e9ca9e12d5dc49195e7",
    },
  };

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      adminCap: adminCapID[env],
      balanceManagers,
    }),
  );

  const tx = new Transaction();

  const tradeCap =
    client.deepbook.balanceManager.mintTradeCap("BALANCE_MANAGER_2")(tx);
  tx.transferObjects(
    [tradeCap],
    "0x946a9773c1acfe7a20ac926f948ed4e6d77148b75e00d60f83ac10abae4ea9d7",
  );

  client.deepbook.balanceManager.depositIntoManager(
    "BALANCE_MANAGER_1",
    "DEEP",
    110000,
  )(tx);

  client.deepbook.balanceManager.depositIntoManager(
    "BALANCE_MANAGER_2",
    "DEEP",
    30000,
  )(tx);

  const res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
