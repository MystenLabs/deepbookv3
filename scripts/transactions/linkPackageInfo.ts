// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { newTransaction } from "./transaction";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = newTransaction();
  const appCapObjectId = ""; // TODO
  const packageInfoId = ""; // TODO

  // 1. Sets git versioning for mainnet
  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/deepbookv3"),
      transaction.pure.string("packages/deepbook"),
      transaction.pure.string("b9082548ee8181e118fcab618778cf2a9bae3b2e"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [
      transaction.object(packageInfoId),
      transaction.pure.u64(`1`),
      git,
    ],
  });

  // 2. Links testnet packageInfo
  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        "0x35f509124a4a34981e5b1ba279d1fdfc0af3502ae1edf101e49a2d724a4c1a34" // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        "0x984757fc7c0e6dd5f15c2c66e881dd6e5aca98b725f3dbd83c445e057ebb790a" // V2 of the package on testnet
      ),
      transaction.pure.option("address", null),
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_network`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(appCapObjectId),
      transaction.pure.string("4c78adac"), // testnet
      appInfo,
    ],
  });

  // 3. Linked mainnet packageInfo with appCap
  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
      ),
      transaction.object(appCapObjectId),
      transaction.object(packageInfoId),
    ],
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e"
  ); // Deepbook Admin Account

  console.dir(res, { depth: null });
})();
