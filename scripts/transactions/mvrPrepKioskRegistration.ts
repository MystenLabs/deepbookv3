// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

  /// We pass in our UpgradeCap
  const packageInfo = transaction.moveCall({
    target: `@mvr/metadata::package_info::new`,
    arguments: [
      transaction.object(
        "0x19aa128f36c3ef97b8a20a0ce8ffc998fbbc03d9f86e5b39c2ef3d3bd49a1ad1"
      ), // Kiosk UpgradeCap
    ],
  });

  // We also need to create the visual representation of our "info" object.
  // You can also call `@mvr/metadata::display::new` instead,
  // that allows customizing the colors of your metadata object!
  const display = transaction.moveCall({
    target: `@mvr/metadata::display::default`,
    arguments: [transaction.pure.string("Kiosk - Metadata")],
  });

  // Set that display object to our info object.
  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_display`,
    arguments: [transaction.object(packageInfo), display],
  });

  const appCapObjectId =
    "0x476cbd1df24cf590d675ddde59de4ec535f8aff9eea22fd83fed57001cfc9426";

  // 1. Sets git versioning for mainnet
  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/apps"),
      transaction.pure.string("kiosk"),
      transaction.pure.string("e159ab3fc45a6f1ca46025c46c915988023af8b6"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [packageInfo, transaction.pure.u64(`4`), git],
  });

  const gitv1 = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/apps"),
      transaction.pure.string("kiosk"),
      transaction.pure.string("59bf087985bf854575d3d28ad843166711b0bc99"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [packageInfo, transaction.pure.u64(`1`), gitv1],
  });

  const gitv3 = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/apps"),
      transaction.pure.string("kiosk"),
      transaction.pure.string("66ad6dc651d93adfd030bd09015d1fa5e8f5e55e"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [packageInfo, transaction.pure.u64(`3`), gitv3],
  });

  // 2. Set metadata for mainnet (description, icon_url, documentation_url, homepage_url)
  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "Collection of rules and extensions for Kiosk and creator Transfer Policies."
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("documentation_url"), // key
      transaction.pure.string("https://docs.sui.io/standards/kiosk"), // value
    ],
  });

  // 3. Set default metadata for mainnet

  transaction.moveCall({
    target: "@mvr/metadata::package_info::set_metadata",
    arguments: [
      packageInfo,
      transaction.pure.string("default"),
      transaction.pure.string("@mysten/kiosk"),
    ],
  });

  // 4. Links testnet packageInfo
  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        "0x0b96a1e1dbdfac8c2a27b0172eabd9f4b59ed2200a2c0c349aa903dba3a0bf7e" // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        "0xe308bb3ed5367cd11a9c7f7e7aa95b2f3c9a8f10fa1d2b3cff38240f7898555d" // V1 of the package on testnet
      ),
      transaction.pure.option("address", null),
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_network`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("4c78adac"), // testnet
      appInfo,
    ],
  });

  // 5. Linked mainnet packageInfo with appCap
  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
      ),
      transaction.object(appCapObjectId),
      packageInfo,
    ],
  });

  // transfer the `PackageInfo` object to a safe address.
  transaction.moveCall({
    target: `@mvr/metadata::package_info::transfer`,
    arguments: [
      packageInfo,
      transaction.pure.address(
        "0xcb6a5c15cba57e5033cf3c2b8dc56eafa8a0564a1810f1f2f1341a663b575d54"
      ),
    ],
  }); // PackageInfo transferred to Kiosk UpgradeCap Owner

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xcb6a5c15cba57e5033cf3c2b8dc56eafa8a0564a1810f1f2f1341a663b575d54"
  ); // Owner of Kiosk UpgradeCap

  console.dir(res, { depth: null });
})();
