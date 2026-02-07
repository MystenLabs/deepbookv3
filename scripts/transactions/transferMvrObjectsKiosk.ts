// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

  const holdingAddress =
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  const MVRAppCaps = {
    kiosk: "0x476cbd1df24cf590d675ddde59de4ec535f8aff9eea22fd83fed57001cfc9426",
  };

  const packageInfos = {
    kiosk: "0xa364dd21f5eb43fdd4e502be52f450c09529dfc94dea12412a6d587f17ec7f24",
  };

  // Transfer all app cap + package info objects
  const allObjects: string[] = [];

  for (const value of Object.values(MVRAppCaps)) {
    allObjects.push(value);
  }

  transaction.transferObjects(allObjects, holdingAddress);
  transaction.moveCall({
    target: `@mvr/metadata::package_info::transfer`,
    arguments: [
      transaction.object(packageInfos.kiosk),
      transaction.pure.address(holdingAddress),
    ],
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xcb6a5c15cba57e5033cf3c2b8dc56eafa8a0564a1810f1f2f1341a663b575d54"
  ); // Suins account

  console.dir(res, { depth: null });
})();
