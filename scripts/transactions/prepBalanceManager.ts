// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import {
  adminCapOwner,
  adminCapID,
  marketMakerID,
} from "../config/constants.js";
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
    BALANCE_MANAGER_3: {
      address:
        "0xb5ef19079369b05046097c8b5b0dc4b96e870f526545973e0cdac30249d26aca",
    },
    BALANCE_MANAGER_4: {
      address:
        "0x9392ad0dd51fc2df496c4e731cec6d463aa2630c511931f7234239d7e2ba17c0",
    },
  };

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: marketMakerID[env],
      balanceManagers,
    }),
  );

  const tx = new Transaction();
  client.deepbook.balanceManager.createAndShareBalanceManager()(tx);
  client.deepbook.balanceManager.createAndShareBalanceManager()(tx);

  const res = await prepareMultisigTx(tx, env, marketMakerID[env]);

  console.dir(res, { depth: null });
})();
