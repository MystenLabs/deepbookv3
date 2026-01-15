// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction, coinWithBalance } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { DeepBookClient } from "@mysten/deepbook-v3";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  const env = "mainnet";
  // admin address
  const adminAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";
  const liquidationAdminCap =
    "0x21521b9ddc1cfc76b6f4c9462957b4d58a998a23eb100ab2821d27d55c60d0a9";
  const tx = new Transaction();

  const dbClient = new DeepBookClient({
    address: adminAddress,
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
  });

  dbClient.marginLiquidations.createLiquidationVault(liquidationAdminCap)(tx);
  let res = await prepareMultisigTx(tx, env, adminAddress);

  console.dir(res, { depth: null });
})();
