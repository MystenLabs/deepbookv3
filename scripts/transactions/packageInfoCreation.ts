// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { newTransaction } from "./transaction";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = newTransaction();

  /// We pass in our UpgradeCap
  const packageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(
        "0xdadf253cea3b91010e64651b03da6d56166a4f44b43bdd4e185c277658634483"
      ), // Deepbook UpgradeCap
    ],
  });

  // We also need to create the visual representation of our "info" object.
  // You can also call `@mvr/metadata::display::new` instead,
  // that allows customizing the colors of your metadata object!
  const display = transaction.moveCall({
    target: `@mvr/metadata::display::default`,
    arguments: [transaction.pure.string("DeepbookV3")],
  });

  // Set that display object to our info object.
  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_display`,
    arguments: [transaction.object(packageInfo), display],
  });

  // transfer the `PackageInfo` object to a safe address.
  transaction.moveCall({
    target: `@mvr/metadata::package_info::transfer`,
    arguments: [
      transaction.object(packageInfo),
      transaction.pure.address(
        "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e"
      ),
    ],
  }); // PackageInfo transferred to Admincap Owner

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0x37f187e1e54e9c9b8c78b6c46a7281f644ebc62e75493623edcaa6d1dfcf64d2"
  ); // Owner of UpgradeCap

  console.dir(res, { depth: null });
})();
