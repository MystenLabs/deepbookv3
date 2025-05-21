// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { prepareMultisigTx } from "../utils/utils";
import { namedPackagesPlugin, Transaction } from "@mysten/sui/transactions";

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
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  const appCap = transaction.moveCall({
    target: `@mvr/core::move_registry::register`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(
        "0x6e670c14a6491cf35c3e33b0b20b77ad41871cc038042532e4aa894a2459fa6f"
      ), // walrus domain ID
      transaction.pure.string("site"), // name
      transaction.object.clock(),
    ],
  });

  transaction.transferObjects([appCap], holdingAddress);

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0x633ae17b3d3eaaeed5fdcc7ef710d26a01bedd3a468e1e390e4c9e1111772ab2"
  ); // Owner of @walrus

  console.dir(res, { depth: null });
})();
