// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, adminCapID } from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";

  const coinMap = {
    // Native USDC
    usdc: {
      address:
        "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7",
      type: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
      scalar: 0,
    },
    // Wormhole USDC
    wormholeUsdc: {
      address:
        "0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf",
      type: "0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN",
      scalar: 0,
    },
    // Bridge USDT
    usdt: {
      address:
        "0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068",
      type: "0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT",
      scalar: 0,
    },
    // Wormhole USDT
    wormholeUsdt: {
      address:
        "0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c",
      type: "0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN",
      scalar: 0,
    },
    // AUSD
    ausd: {
      address:
        "0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2",
      type: "0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2::ausd::AUSD",
      scalar: 0,
    },
    // BUCK (Bucket USD)
    buck: {
      address:
        "0xce7ff77a83ea0cb6fd39bd8748e2ec89a3f41e8efdc3f4eb123e0ca37b184db2",
      type: "0xce7ff77a83ea0cb6fd39bd8748e2ec89a3f41e8efdc3f4eb123e0ca37b184db2::buck::BUCK",
      scalar: 0,
    },
    // FDUSD
    fdusd: {
      address:
        "0xf16e6b723f242ec745dfd7634ad072c42d5c1d9ac9d62a39c381303eaa57693a",
      type: "0xf16e6b723f242ec745dfd7634ad072c42d5c1d9ac9d62a39c381303eaa57693a::fdusd::FDUSD",
      scalar: 0,
    },
    // MUSD
    musd: {
      address:
        "0xe44df51c0b21a27ab915fa1fe2ca610cd3eaa6d9666fe5e62b988bf7f0bd8722",
      type: "0xe44df51c0b21a27ab915fa1fe2ca610cd3eaa6d9666fe5e62b988bf7f0bd8722::musd::MUSD",
      scalar: 0,
    },
  };

  const client = new SuiGrpcClient({
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      adminCap: adminCapID[env],
      coins: coinMap,
    }),
  );

  const tx = new Transaction();
  const stableCoins = [
    "usdc", // Native USDC
    "wormholeUsdc", // Wormhole USDC
    "usdt", // Bridge USDT
    "wormholeUsdt", // Wormhole USDT
    "ausd", // AUSD
    "buck", // BUCK (Bucket USD)
    "fdusd", // FDUSD
    "musd", // MUSD
  ];

  for (const coin of stableCoins) {
    client.deepbook.deepBookAdmin.addStableCoin(coin)(tx);
  }

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
