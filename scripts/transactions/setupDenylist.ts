// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  const env = "mainnet";
  const transaction = new Transaction();

  // appcap holding address
  const holdingAddress =
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  // const MVRAppCaps = {
  //   denylist:
  //     "0x8816fd949b3191040855a77a834d98aa822eb63bd2e63de2aaa0064586200882",
  //   // "deny-list":
  //   //   "0xbfa432f8d0424e61b175137135e2f5ee533609ee9039534f9109784be9aa7f7e",
  // };

  // // Set metadata for deny-list appcap
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.pure.string("icon_url"), // key
  //     transaction.pure.string("https://docs.suins.io/logo.svg"), // value
  //   ],
  // });

  const repository = "https://github.com/MystenLabs/suins-contracts";
  const latestSha = "releases/core/4";

  const data = {
    denylist: {
      packageInfo:
        "0x5007c0681ff36e9efcb5d655af758c5eeb4825b39ef4ec2ccacd195f4f65d4f5",
      sha: latestSha,
      version: "1",
      path: "packages/redirect-denylist",
    },
    // "deny-list": {
    //   packageInfo:
    //     "0x8db617063bf735f1c265800f0f48dcb7a98f542553a89b8f8ada11bd37729134",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/denylist",
    // },
  };

  // Set git versioning for deny-list, unset for denylist
  for (const [name, { packageInfo, sha, version, path }] of Object.entries(
    data
  )) {
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

  // // Set all metadata for deny-list
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.pure.string("description"), // key
  //     transaction.pure.string(
  //       "The SuiNS denylist package. Used to manage a list of disallowed names including banned names."
  //     ), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.pure.string("documentation_url"), // key
  //     transaction.pure.string("https://docs.suins.io/"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.pure.string("homepage_url"), // key
  //     transaction.pure.string("https://suins.io/"), // value
  //   ],
  // });

  // Unset reverse resolution for denylist
  // transaction.moveCall({
  //   target: `@mvr/metadata::package_info::unset_metadata`,
  //   arguments: [
  //     transaction.object(data.denylist.packageInfo),
  //     transaction.pure.string("default"), // key
  //   ],
  // });

  // // Set reverse resolution for deny-list
  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::set_metadata",
  //   arguments: [
  //     transaction.object(data["deny-list"].packageInfo),
  //     transaction.pure.string("default"),
  //     transaction.pure.string("@suins/deny-list"),
  //   ],
  // });

  // Set testnet information for deny-list
  // const appInfo = transaction.moveCall({
  //   target: `@mvr/core::app_info::new`,
  //   arguments: [
  //     transaction.pure.option(
  //       "address",
  //       "0xb82af529b54f90474e523467123c7e255903d0713ec8b7f0125794f94742c7bc" // PackageInfo object on testnet
  //     ),
  //     transaction.pure.option(
  //       "address",
  //       "0xa86c05fbc6371788eb31260dc5085f4bfeab8b95c95d9092c9eb86e63fae3d49" // V1 of the denylist package on testnet
  //     ),
  //     transaction.pure.option("address", null),
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_network`,
  //   arguments: [
  //     // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.pure.string("4c78adac"), // testnet
  //     appInfo,
  //   ],
  // });

  // Link deny-list to correct packageInfo
  // Important to check these two
  // 0xbfa432f8d0424e61b175137135e2f5ee533609ee9039534f9109784be9aa7f7e
  // 0x8db617063bf735f1c265800f0f48dcb7a98f542553a89b8f8ada11bd37729134
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::assign_package`,
  //   arguments: [
  //     transaction.object(
  //       `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
  //     ),
  //     transaction.object(MVRAppCaps["deny-list"]),
  //     transaction.object(data["deny-list"].packageInfo),
  //   ],
  // });

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of all MVR caps

  console.dir(res, { depth: null });
})();
