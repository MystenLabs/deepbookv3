// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import {
  adminCapOwner,
  adminCapID,
  marginAdminCapID,
} from "../config/constants";
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
    marginAdminCap: marginAdminCapID[env],
  });

  const tx = new Transaction();

  // 1. Enable Margin package in core deepbook
  dbClient.deepBookAdmin.authorizeMarginApp()(tx);

  // 2. PauseCap distribution
  const pauseCap1 = dbClient.marginAdmin.mintPauseCap()(tx);
  const pauseCap2 = dbClient.marginAdmin.mintPauseCap()(tx);
  const pauseCap3 = dbClient.marginAdmin.mintPauseCap()(tx);
  tx.transferObjects(
    [pauseCap1],
    "0x517f822cd3c45a3ac3dbfab73c060d9a0d96bec7fffa204c341e7e0877c9787c"
  );
  tx.transferObjects(
    [pauseCap2],
    "0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192"
  );
  tx.transferObjects(
    [pauseCap3],
    "0x7da4267928e568da4f64f5a80f5b63680f3c2e008f4f96f475b60ff1c48c0dcf"
  );

  // 3. Mint maintainerCap
  const maintainerCap = dbClient.marginAdmin.mintMaintainerCap()(tx);
  tx.transferObjects([maintainerCap], adminCapOwner[env]);

  // 4. Pyth Config
  const pythConfig = dbClient.marginAdmin.newPythConfig(
    [
      { coinKey: "SUI", maxConfBps: 300, maxEwmaDifferenceBps: 1500 }, // maxConfBps: 3%, maxEwmaDifferenceBps: 15%
      { coinKey: "USDC", maxConfBps: 100, maxEwmaDifferenceBps: 500 }, // maxConfBps: 1%, maxEwmaDifferenceBps: 5%
      { coinKey: "DEEP", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
      { coinKey: "WAL", maxConfBps: 500, maxEwmaDifferenceBps: 3000 }, // maxConfBps: 5%, maxEwmaDifferenceBps: 30%
    ],
    30 // maxAgeSeconds: 30 seconds
  )(tx);
  dbClient.marginAdmin.addConfig(pythConfig)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
