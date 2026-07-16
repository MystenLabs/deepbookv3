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
  const packageInfo =
    "0x11c2e0f7292ea1b84ed894302b96146872fea53a99b933122fb193e48dac1005"; // @deepbook/margin-trading PackageInfo
  const path = "packages/deepbook_margin";

  // Package versions to point at their source tag. MVR already holds 1-3; v5 and
  // v6 are both published on chain with tags but were never registered. Each `sha`
  // must be a tag that exists in the repository, and its `packages/deepbook_margin`
  // tree must be the source that was published as that package version.
  const versions = [
    { sha: "margin-v5.0.0", version: "5" },
    { sha: "margin-v6.0.0", version: "6" },
  ];

  versions.forEach(({ sha, version }) => {
    const git = transaction.moveCall({
      target: `@mvr/metadata::git::new`,
      arguments: [
        transaction.pure.string(repository),
        transaction.pure.string(path),
        transaction.pure.string(sha),
      ],
    });

    transaction.moveCall({
      target: `@mvr/metadata::package_info::set_git_versioning`,
      arguments: [
        transaction.object(packageInfo),
        transaction.pure.u64(version),
        git,
      ],
    });
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e",
  ); // multisig address

  console.dir(res, { depth: null });
})();
