// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { prepareMultisigTx } from "../utils/utils.js";
import { Transaction } from "@mysten/sui/transactions";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";
  const appCapObjectId =
    "0x5c05d47053b0b3126dc99ee97264bf0d8b52e5789ca33917b88d83eb63f0e434";

  // const appCap = transaction.moveCall({
  //   target: `@mvr/core::move_registry::register`,
  //   arguments: [
  //     // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
  //     ),
  //     transaction.object(
  //       "0x9dc2cd7decc92ec8a66ba32167fb7ec279b30bc36c3216096035db7d750aa89f"
  //     ), // mysten domain ID
  //     transaction.pure.string("nautilus"), // name
  //     transaction.object.clock(),
  //   ],
  // });

  // const appCap2 = transaction.moveCall({
  //   target: `@mvr/core::move_registry::register`,
  //   arguments: [
  //     // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
  //     ),
  //     transaction.object(
  //       "0x9dc2cd7decc92ec8a66ba32167fb7ec279b30bc36c3216096035db7d750aa89f"
  //     ), // mysten domain ID
  //     transaction.pure.string("seal"), // name
  //     transaction.object.clock(),
  //   ],
  // });

  // transaction.transferObjects([appCap, appCap2], holdingAddress);

  transaction.moveCall({
    target: `@mvr/core::move_registry::unset_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("documentation_url"), // key
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
      transaction.pure.string("https://seal-docs.wal.app/UsingSeal/"), // value
    ],
  });

  let res = await prepareMultisigTx(transaction, env, holdingAddress);

  console.dir(res, { depth: null });
})();
