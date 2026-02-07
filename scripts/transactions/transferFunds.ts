// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction, coinWithBalance } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

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
    USDC: {
      type: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
      scalar: 1_000_000,
    },
  };

  // admin address
  const adminAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";

  // Update receiving address as needed
  const recevingAddress =
    "0x3298a2fdc3949db7c066fbaff92671b7ffc519e473cd89956f0c0d27e5a6326d";
  const coinType = "USDC"; // "SUI" or "DEEP" or "USDC"
  const amount = 5;

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
