// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import {
  adminCapOwner,
  adminCapID,
  marginAdminCapID,
} from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const deepbookVersionToEnable = 8;
  const marginVersionToEnable = 5;

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: adminCapOwner[env],
      adminCap: adminCapID[env],
      marginAdminCap: marginAdminCapID[env],
    }),
  );

  const tx = new Transaction();

  // 1. Enable version 8 in deepbook core
  client.deepbook.deepBookAdmin.enableVersion(deepbookVersionToEnable)(tx);

  // 2. Enable version 5 in margin
  client.deepbook.marginAdmin.enableVersion(marginVersionToEnable)(tx);

  // 3. Authorize the margin package
  client.deepbook.deepBookAdmin.authorizeMarginApp()(tx);

  const res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
