// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

const SENDER =
  "0x33658dde444806a0f1811843380b3af8f15fc9387e320e8ba094277c7da80b0c";

const SLUSH_STRATEGIES_PACKAGE =
  "0xbd6bde9b35e9aeae9e846e1f12ba900ece01a29fcb4806cadd396e36f58433aa";
const USDSUI_PACKAGE =
  "0x44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1";
const USDSUI_TYPE = `${USDSUI_PACKAGE}::usdsui::USDSUI`;

// Shared objects
const SlushPool =
  "0xe4c0f299e853b1d158d3bbd7f405a056736bca175ae384b89e28be8d951533a4";
const IronBankPool =
  "0x7b794774900fa303c4c2534dbce05991a82e7cea105cad579f1f657dfd964f4f";
const IronBankRegistry =
  "0x21f02f2539e5856e20bfb4ff8936d4bfbefd58db6b71e46c41d4d8dc427bbdf7";

const amount = 1_000;
const scalar = 1_000_000;

(async () => {
  const env = "mainnet";
  const tx = new Transaction();

  const inputCoin = coinWithBalance({
    type: USDSUI_TYPE,
    balance: amount * scalar,
  })(tx);

  tx.moveCall({
    target: `${SLUSH_STRATEGIES_PACKAGE}::slush_pool::supply`,
    arguments: [
      tx.object(SlushPool),
      tx.object(IronBankPool),
      tx.object(IronBankRegistry),
      inputCoin,
      tx.object.clock(),
    ],
  });

  let res = await prepareMultisigTx(tx, env, SENDER);

  console.dir(res, { depth: null });
})();
