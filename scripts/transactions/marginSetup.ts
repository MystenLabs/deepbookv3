// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { namedPackagesPlugin, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const mainnetPlugin = namedPackagesPlugin({
  url: "https://mainnet.mvr.mystenlabs.com",
});

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();
  transaction.addSerializationPlugin(mainnetPlugin);

  // appcap holding address
  const holdingAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";

  const testnetPackageInfo =
    "0xe808fd86b2d2ee53c3968c662c4c1149866dcb5d3a7ea525603692de01757b0f";

  const testnetPackageId =
    "0xb8620c24c9ea1a4a41e79613d2b3d1d93648d1bb6f6b789a7c8f261c94110e4b";

  const appCap = transaction.moveCall({
    target: `@mvr/core::move_registry::register`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(
        "0xd0815f9867a0a02690a9fe3b5be9a044bb381f96c660ba6aa28dfaaaeb76af76"
      ), // deepbook domain ID
      transaction.pure.string("margin-trading"), // name
      transaction.object.clock(),
    ],
  });

  // Set all metadata for margin-trading
  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      appCap,
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "DeepBook Margin extends the trading capabilities of DeepBookV3 by enabling leveraged trading positions. With margin trading, users can borrow funds to increase their buying power."
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      appCap,
      transaction.pure.string("documentation_url"), // key
      transaction.pure.string("https://docs.sui.io/standards/deepbook-margin"), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      appCap,
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://deepbook.tech/"), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      appCap,
      transaction.pure.string("icon_url"), // key
      transaction.pure.string("https://images.deepbook.tech/icon.svg"), // value
    ],
  });

  // Set testnet information for margin-trading
  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        testnetPackageInfo // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        testnetPackageId // V1 of the margin-trading package on testnet
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
      appCap,
      transaction.pure.string("4c78adac"), // testnet
      appInfo,
    ],
  });

  // // Link payment-kit to correct packageInfo
  // // Important to check these two
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::assign_package`,
  //   arguments: [
  //     transaction.object(
  //       `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
  //     ),
  //     appCap,
  //     transaction.object(mainnetPackageInfo),
  //   ],
  // });

  transaction.transferObjects([appCap], holdingAddress);
  // transaction.moveCall({
  //   target: `@mvr/metadata::package_info::transfer`,
  //   arguments: [
  //     transaction.object(mainnetPackageInfo),
  //     transaction.pure.address(holdingAddress),
  //   ],
  // });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xb5b39d11ddbd0abb0166cd369c155409a2cca9868659bda6d9ce3804c510b949"
  ); // multisig address

  console.dir(res, { depth: null });
})();
