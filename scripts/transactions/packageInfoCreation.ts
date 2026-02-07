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
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  /// We pass in our UpgradeCap
  const packageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(
        "0x1cab3c76c48c023b60db0a56696d197569f006e406fb9627a8a8d1a119b1c23c"
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

  // const MVRAppCaps = {
  //   core: "0xf30a07fc1fadc8bd33ed4a9af5129967008201387b979a9899e52fbd852b29a9",
  //   payments:
  //     "0xcb44143e2921ed0fb82529ba58f5284ec77da63a8640e57c7fa8c12e87fa8baf",
  //   subnames:
  //     "0x969978eba35e57ad66856f137448da065bc27962a1bc4a6dd8b6cc229c899d5a",
  //   coupons:
  //     "0x4f3fa0d4da16578b8261175131bc7a24dcefe3ec83b45690e29cbc9bb3edc4de",
  //   discounts:
  //     "0x327702a5751c9582b152db81073e56c9201fad51ecbaf8bb522ae8df49f8dfd1",
  //   tempSubnameProxy:
  //     "0x3b2582036fe9aa17c059e7b3993b8dc97ae57d2ac9e1fe603884060c98385fb2",
  // };

  // const packageInfos = {
  //   core: "0xf709e4075c19d9ab1ba5acb17dfbf08ddc1e328ab20eaa879454bf5f6b98758e",
  //   payments:
  //     "0xa46d971d0e9298488605e1850d64fa067db9d66570dda8dad37bbf61ab2cca21",
  //   subnames:
  //     "0x9470cf5deaf2e22232244da9beeabb7b82d4a9f7b9b0784017af75c7641950ee",
  //   coupons:
  //     "0xf7f29dce2246e6c79c8edd4094dc3039de478187b1b13e871a6a1a87775fe939",
  //   discounts:
  //     "0xcb8d0cefcda3949b3ff83c0014cb50ca2a7c7b2074a5a7c1f2fce68cb9ad7dd6",
  //   tempSubnameProxy:
  //     "0x9accbc6d7c86abf91dcbe247fd44c6eb006d8f1864ff93b90faaeb09114d3b6f",
  // };

  // // Transfer all app cap + package info objects
  // const allAppCaps: string[] = [];

  // for (const value of Object.values(MVRAppCaps)) {
  //   allAppCaps.push(value);
  // }
  // transaction.transferObjects(allAppCaps, holdingAddress);

  // for (const packageInfoId of Object.values(packageInfos)) {
  //   transaction.moveCall({
  //     target: `@mvr/metadata::package_info::transfer`,
  //     arguments: [
  //       transaction.object(packageInfoId),
  //       transaction.pure.address(holdingAddress),
  //     ],
  //   }); // PackageInfo transferred to MVR account
  // }

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0x23eb7ccbbb4a21afea8b1256475e255b3cd84083ca79fa1f1a9435ab93d2b71b"
  ); // Owner of walrus sites UpgradeCap

  console.dir(res, { depth: null });
})();
