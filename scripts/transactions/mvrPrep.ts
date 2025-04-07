// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { newTransaction } from "./transaction";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = newTransaction();

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
      transaction.pure.string("core"), // name
      transaction.object.clock(),
    ],
  });

  transaction.transferObjects(
    [appCap],
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e"
  ); // This is the deepbook adminCap owner

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xb5b39d11ddbd0abb0166cd369c155409a2cca9868659bda6d9ce3804c510b949"
  ); // Owner of @deepbook

  console.dir(res, { depth: null });
})();
