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

  const coins = {
    COINGR: {
      address:
        "0xd2e5cb84b33e2acadff5d1c8a30181e8871de44b5bfbea5b8c615ec6218b2fca",
      type: "0xd2e5cb84b33e2acadff5d1c8a30181e8871de44b5bfbea5b8c615ec6218b2fca::coin_gr::COIN_GR",
      scalar: 1000000000,
    },
    USDC: {
      address:
        "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7",
      type: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
      scalar: 1000000,
    },
  };

  const pools = {
    COINGR_USDC: {
      address: "0xb04a92daba7e164a0eb31d13f642d3de50233b07c09637698de6ee376beb5c4a",
      baseCoin: "COINGR",
      quoteCoin: "USDC",
    },
  };

  const client = new SuiGrpcClient({
    baseUrl: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      adminCap: adminCapID[env],
      coins,
      pools,
    }),
  );

  const tx = new Transaction();

  client.deepbook.deepBookAdmin.adjustMinLotSize("COINGR_USDC", 0.01, 0.1)(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
