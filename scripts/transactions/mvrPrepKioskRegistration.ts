// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { newTransaction } from "./transaction";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = newTransaction();

  // const appCap = transaction.moveCall({
  //   target: `@mvr/core::move_registry::register`,
  //   arguments: [
  //     // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
  //     ),
  //     transaction.object(
  //       "0x798078c3d1357222a40ce64cc430270e095f5f39da1d7e5f7a381551661eda5b"
  //     ), // kiosk domain ID
  //     transaction.pure.string("core"), // name
  //     transaction.object.clock(),
  //   ],
  // });

  // transaction.transferObjects(
  //   [appCap],
  //   "0xcb6a5c15cba57e5033cf3c2b8dc56eafa8a0564a1810f1f2f1341a663b575d54"
  // ); // This is the kiosk UpgradeCap owner, who will finish the registration process

  // let res = await prepareMultisigTx(
  //   transaction,
  //   env,
  //   "0xa81a2328b7bbf70ab196d6aca400b5b0721dec7615bf272d95e0b0df04517e72"
  // ); // Owner of @kiosk
  // // coin: 0xae841028e9c704badbeb0f3f837b371f663bf647e6f9c984ce47284869a8754e

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

  const appCapObjectId = ""; // TODO: Kiosk appcap ID

  // 1. Sets git versioning for mainnet
  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/apps"),
      transaction.pure.string("kiosk"),
      transaction.pure.string("24e3830e967d7bdde1fe1e45df83e3a1ee8f25c4"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [packageInfo, transaction.pure.u64(`4`), git],
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
        "Includes collection of transfer policies, kiosk extensions and libraries to work with all of them. It is meant to act as a Kiosk Sui Move monorepo with a set release cycle and a very welcoming setting for external contributions."
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

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://docs.sui.io/standards/kiosk"), // value
    ],
  });

  // 3. Set default metadata for mainnet

  transaction.moveCall({
    target: "@mvr/metadata::package_info::set_metadata",
    arguments: [
      packageInfo,
      transaction.pure.string("default"),
      transaction.pure.string("@kiosk/kiosk"), // TODO: naming?
    ],
  });

  // // 4. Links testnet packageInfo
  // const appInfo = transaction.moveCall({
  //   target: `@mvr/core::app_info::new`,
  //   arguments: [
  //     transaction.pure.option(
  //       "address",
  //       "" // PackageInfo object on testnet
  //     ),
  //     transaction.pure.option(
  //       "address",
  //       "0x0717a13f43deaf5345682153e3633f76cdcf695405959697fcd63f63f289320b" // V3 of the package on testnet
  //     ),
  //     transaction.pure.option("address", null),
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_network`,
  //   arguments: [
  //     // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("4c78adac"), // testnet
  //     appInfo,
  //   ],
  // });

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
      transaction.object(packageInfo),
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
