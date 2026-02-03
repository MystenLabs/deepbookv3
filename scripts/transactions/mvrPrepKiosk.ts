// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

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
      transaction.pure.string("kiosk"), // name
      transaction.object.clock(),
    ],
  });

  transaction.transferObjects(
    [appCap],
    "0xcb6a5c15cba57e5033cf3c2b8dc56eafa8a0564a1810f1f2f1341a663b575d54"
  ); // This is the kiosk UpgradeCap owner, who will finish the registration process

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xa81a2328b7bbf70ab196d6aca400b5b0721dec7615bf272d95e0b0df04517e72"
  ); // Owner of @kiosk
  // coin: 0xae841028e9c704badbeb0f3f837b371f663bf647e6f9c984ce47284869a8754e

  console.dir(res, { depth: null });
})();
