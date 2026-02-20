// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();

  const appCap =
    "0x9e120e97c91434c8102024edc0a64c2d18ab702333da947791707dee6a45da2c"; // @deepbook/margin-trading appCap

  const repository = "https://github.com/MystenLabs/deepbookv3";

  const data2 = {
    packageInfo:
      "0x11c2e0f7292ea1b84ed894302b96146872fea53a99b933122fb193e48dac1005",
    sha: "margin-v2.0.0",
    version: "2",
    path: "packages/deepbook_margin",
  };

  const git2 = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string(repository),
      transaction.pure.string(data2.path),
      transaction.pure.string(data2.sha),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [
      transaction.object(data2.packageInfo),
      transaction.pure.u64(data2.version),
      git2,
    ],
  });

  const data3 = {
    packageInfo:
      "0x11c2e0f7292ea1b84ed894302b96146872fea53a99b933122fb193e48dac1005",
    sha: "margin-v3.0.0",
    version: "3",
    path: "packages/deepbook_margin",
  };

  const git3 = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string(repository),
      transaction.pure.string(data3.path),
      transaction.pure.string(data3.sha),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [
      transaction.object(data3.packageInfo),
      transaction.pure.u64(data3.version),
      git3,
    ],
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e",
  ); // multisig address

  console.dir(res, { depth: null });
})();
