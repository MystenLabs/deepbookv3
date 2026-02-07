// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  const packageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(
        "0xf8083707981031b003db9b0fcd074664efe366ba6926ce5859412495860cf9a9"
      ), // Nautilus Package UpgradeCap
    ],
  });

  // We also need to create the visual representation of our "info" object.
  // You can also call `@mvr/metadata::display::new` instead,
  // that allows customizing the colors of your metadata object!
  const display = transaction.moveCall({
    target: `@mvr/metadata::display::default`,
    arguments: [transaction.pure.string("Mysten - Nautilus Metadata")],
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
    "0xfa469d15a399f7a000214f4630712c6e6207430499278e1c2e19a63d5dd821e5"
  ); // Owner of nautilus UpgradeCap

  console.dir(res, { depth: null });
})();
