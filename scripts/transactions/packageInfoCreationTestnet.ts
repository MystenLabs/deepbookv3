// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { namedPackagesPlugin, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const plugin = namedPackagesPlugin({
  url: "https://testnet.mvr.mystenlabs.com",
});

Transaction.registerGlobalSerializationPlugin("namedPackagesPlugin", plugin);

(async () => {
  // Update constant for env
  const env = "testnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0x0aa9f6e9cda08ff6fa15c7fedcfd8266203fa9dfdec7f793dd5855365eecea5a";

  /// We pass in our UpgradeCap
  const packageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(
        "0x719b3b518ed7a2060243fbb04bcb7b635a3817cfb361f81807d551c277bdb647"
      ), // Walrus Sites Package UpgradeCap
    ],
  });

  // We also need to create the visual representation of our "info" object.
  // You can also call `@mvr/metadata::display::new` instead,
  // that allows customizing the colors of your metadata object!
  const display = transaction.moveCall({
    target: `@mvr/metadata::display::default`,
    arguments: [transaction.pure.string("Walrus - Sites Metadata")],
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
      transaction.pure.address(holdingAddress),
    ],
  }); // PackageInfo transferred to MVR account

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0x23eb7ccbbb4a21afea8b1256475e255b3cd84083ca79fa1f1a9435ab93d2b71b"
  ); // Owner of walrus sites UpgradeCap

  console.dir(res, { depth: null });
})();
