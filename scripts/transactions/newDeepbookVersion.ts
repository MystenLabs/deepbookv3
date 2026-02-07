// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e";

  const deepbookPackageInfo =
    "0x4874e126c490e495ff7490523841bdba57e2a01ed36db7610f07d417c8b5a988";

  const data = {
    repository: "https://github.com/MystenLabs/deepbookv3",
    packageInfo: deepbookPackageInfo,
    sha: "v6.0.0",
    version: "6",
    path: "packages/deepbook",
  };

  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string(data.repository),
      transaction.pure.string(data.path),
      transaction.pure.string(data.sha),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [
      transaction.object(data.packageInfo),
      transaction.pure.u64(data.version),
      git,
    ],
  });

  let res = await prepareMultisigTx(transaction, env, holdingAddress);

  console.dir(res, { depth: null });
})();
