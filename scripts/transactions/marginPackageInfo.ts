// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";

  const mainnetUpgradeCap =
    "0xd57c7a41b31c0a1fab5e71d296a75daf2e9e09945df383d4745daa49f06d9c56";

  const mainnetPackageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(mainnetUpgradeCap), // Margin UpgradeCap
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::transfer`,
    arguments: [
      transaction.object(mainnetPackageInfo),
      transaction.pure.address(holdingAddress),
    ],
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0x37f187e1e54e9c9b8c78b6c46a7281f644ebc62e75493623edcaa6d1dfcf64d2",
  ); // multisig address

  console.dir(res, { depth: null });
})();
