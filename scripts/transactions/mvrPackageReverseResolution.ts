// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0x9a8859bbe68679bcc6dfd06ede1cce7309d59ef21bb0caf2e4c901320489a466";

  // const MVRAppCaps = {
  //   core: "0x673bac45d749730e71c3ad2395c2942f7dd61167308752b564963228b147edc0",
  //   "subnames-proxy":
  //     "0xa24ad6dee0fa4b4a59839a78b638e3157638ac9774b6734af0250b372bf10881",
  //   metadata:
  //     "0x8e5af7f91bcdbcb637eb6774fbb4b23022db864d125f7e74ab17f64646ac73da",
  //   "public-names":
  //     "0x4e9264ba30222c1701457ed3d4745c74fd9d736c6609558aafd46ec734e60d78",
  // };

  const latestSha = "releases/metadata/2";
  const repository = "https://github.com/mystenlabs/mvr";

  const data = {
    // core: {
    //   packageInfo:
    //     "0xb68f1155b210ef649fa86c5a1b85d419b1593e08e2ee58d400d1090d36c93543",
    //   sha: latestSha,
    //   version: "3",
    //   path: "packages/mvr",
    // },
    // "subnames-proxy": {
    //   packageInfo:
    //     "0x04de61f83f793aa89349263e04af8e186cffbbb4f4582422afd054a8bfb2c706",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/proxy",
    // },
    metadata: {
      packageInfo:
        "0x7ffeae2cd612960c7f208c68da064aa462e2fbb23fcf64faf2af9c2f67e7d4ca",
      sha: latestSha,
      version: "2",
      path: "packages/package_info",
    },
    // "public-names": {
    //   packageInfo:
    //     "0xe91836471642e44ba0c52b1f5223fcfa74686272192390295f7c8cbb2f44b51c",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/public_names",
    // },
  };

  for (const [name, { packageInfo, sha, version, path }] of Object.entries(
    data
  )) {
    // transaction.moveCall({
    //   target: "@mvr/metadata::package_info::set_metadata",
    //   arguments: [
    //     transaction.object(packageInfo),
    //     transaction.pure.string("default"),
    //     transaction.pure.string(`@mvr/${name}`),
    //   ],
    // });

    // transaction.moveCall({
    //   target: `@mvr/metadata::package_info::unset_git_versioning`,
    //   arguments: [
    //     transaction.object(packageInfo),
    //     transaction.pure.u64(version),
    //   ],
    // });

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
  }

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of appcap for MVR

  console.dir(res, { depth: null });
})();
