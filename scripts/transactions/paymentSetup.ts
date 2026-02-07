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

  const mainnetPackageInfo =
    "0xa7fe44196e9d3c130643250d8742b6b886c0d297fa2febf11858fe4f3787eb3a";

  const testnetPackageInfo =
    "0x5ddfe36e164a18927ca50bb9f9cf797f2f557462a93f028bdca9f47acf12f69c";

  const testnetPackageId =
    "0x7e069abe383e80d32f2aec17b3793da82aabc8c2edf84abbf68dd7b719e71497";

  const appCap = transaction.moveCall({
    target: `@mvr/core::move_registry::register`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(
        "0x9dc2cd7decc92ec8a66ba32167fb7ec279b30bc36c3216096035db7d750aa89f"
      ), // mysten domain ID
      transaction.pure.string("payment-kit"), // name
      transaction.object.clock(),
    ],
  });

  // Set all metadata for payment-kit
  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      appCap,
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "A robust, open-source payment processing toolkit for the Sui blockchain that provides secure payment verification, receipt management, and duplicate prevention."
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
      transaction.pure.string("https://github.com/MystenLabs/sui-payment-kit"), // value
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
      transaction.pure.string("https://github.com/MystenLabs/sui-payment-kit"), // value
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
      transaction.pure.string("https://svg-host.vercel.app/mystenlogo.svg"), // value
    ],
  });

  // Set testnet information for payment-kit
  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        testnetPackageInfo // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        testnetPackageId // V1 of the payment-kit package on testnet
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

  // Link payment-kit to correct packageInfo
  // Important to check these two
  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
      ),
      appCap,
      transaction.object(mainnetPackageInfo),
    ],
  });

  transaction.transferObjects([appCap], holdingAddress);
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
    "0xa81a2328b7bbf70ab196d6aca400b5b0721dec7615bf272d95e0b0df04517e72"
  ); // multisig address

  console.dir(res, { depth: null });
})();
