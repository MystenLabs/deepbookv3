// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction, coinWithBalance } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  const env = "mainnet";
  const transaction = new Transaction();
  const config = {
    SUI: {
      type: "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
      scalar: 1_000_000_000,
    },
    DEEP: {
      type: "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
      scalar: 1_000_000,
    },
  };

  // admin address
  const adminAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";

  // Update receiving address as needed
  const recevingAddress =
    "0xdca69f2c3651edc4037bf4621817a807b4346e5e4460ec3f410fcf07e3b743a7";
  const coinType = "SUI"; // "SUI" or "DEEP"
  const amount = 10_000;

  const totalAmount = amount * config[coinType].scalar;
  const coin = coinWithBalance({
    balance: totalAmount,
    type: config[coinType].type,
    useGasCoin: false,
  })(transaction);

  transaction.transferObjects([coin], recevingAddress);
  let res = await prepareMultisigTx(transaction, env, adminAddress);

  console.dir(res, { depth: null });
})();
