// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";

  const coins = {
    // Define custom coins as needed
    COIN_A: {
      address: "", // ex: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7
      type: "", // ex: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
      scalar: 0, // scalar, 1000000 for 6 decimals as example
    },
    COIN_B: {
      address: "", // ex: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7
      type: "", // ex: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
      scalar: 0, // scalar, 1000000 for 6 decimals as example
    },
  };

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      coins,
    }),
  );

  const tx = new Transaction();

  // follow conventions defined in https://docs.sui.io/standards/deepbookv3/permissionless-pool for tick/lot/min sizes
  client.deepbook.deepBook.createPermissionlessPool({
    baseCoinKey: "COIN_A",
    quoteCoinKey: "COIN_B",
    tickSize: 0.00001, // true value of tick size
    lotSize: 0.1, // true value of lot size
    minSize: 1, // true value of min size
  })(tx);
})();
