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

  const MVRAppCaps = {
    // core: "0xf30a07fc1fadc8bd33ed4a9af5129967008201387b979a9899e52fbd852b29a9",
    // payments:
    //   "0xcb44143e2921ed0fb82529ba58f5284ec77da63a8640e57c7fa8c12e87fa8baf",
    subnames:
      "0x969978eba35e57ad66856f137448da065bc27962a1bc4a6dd8b6cc229c899d5a",
    // coupons:
    //   "0x4f3fa0d4da16578b8261175131bc7a24dcefe3ec83b45690e29cbc9bb3edc4de",
    // discounts:
    //   "0x327702a5751c9582b152db81073e56c9201fad51ecbaf8bb522ae8df49f8dfd1",
    // tempSubnameProxy:
    //   "0x3b2582036fe9aa17c059e7b3993b8dc97ae57d2ac9e1fe603884060c98385fb2",
    // denylist:
    //   "0x8816fd949b3191040855a77a834d98aa822eb63bd2e63de2aaa0064586200882",
  };

  // for (const appCapObjectId of Object.values(MVRAppCaps)) {
  //   transaction.moveCall({
  //     target: `@mvr/core::move_registry::set_metadata`,
  //     arguments: [
  //       transaction.object(
  //         "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //       ),
  //       transaction.object(appCapObjectId),
  //       transaction.pure.string("icon_url"), // key
  //       transaction.pure.string("https://docs.suins.io/logo.svg"), // value
  //     ],
  //   });
  // }

  // const kioskAppCap =
  //   "0x476cbd1df24cf590d675ddde59de4ec535f8aff9eea22fd83fed57001cfc9426";

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(kioskAppCap),
  //     transaction.pure.string("icon_url"), // key
  //     transaction.pure.string("https://svg-host.vercel.app/mystenlogo.svg"),
  //   ],
  // });

  const repository = "https://github.com/MystenLabs/suins-contracts";

  const data = {
    // core: {
    //   packageInfo:
    //     "0xf709e4075c19d9ab1ba5acb17dfbf08ddc1e328ab20eaa879454bf5f6b98758e",
    //   sha: latestSha,
    //   version: "4",
    //   path: "packages/suins",
    // },
    // payments: {
    //   packageInfo:
    //     "0xa46d971d0e9298488605e1850d64fa067db9d66570dda8dad37bbf61ab2cca21",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/payments",
    // },
    subnames: {
      packageInfo:
        "0x9470cf5deaf2e22232244da9beeabb7b82d4a9f7b9b0784017af75c7641950ee",
      sha: "releases/subdomains/2",
      version: "2",
      path: "packages/subdomains",
    },
    // coupons: {
    //   packageInfo:
    //     "0xf7f29dce2246e6c79c8edd4094dc3039de478187b1b13e871a6a1a87775fe939",
    //   sha: latestSha,
    //   version: "2",
    //   path: "packages/coupons",
    // },
    // discounts: {
    //   packageInfo:
    //     "0xcb8d0cefcda3949b3ff83c0014cb50ca2a7c7b2074a5a7c1f2fce68cb9ad7dd6",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/discounts",
    // },
    tempSubnameProxy: {
      packageInfo:
        "0x9accbc6d7c86abf91dcbe247fd44c6eb006d8f1864ff93b90faaeb09114d3b6f",
      sha: "releases/temp_subdomain_proxy/2",
      version: "2",
      path: "packages/temp_subdomain_proxy",
    },
    // denylist: {
    //   packageInfo:
    //     "0x5007c0681ff36e9efcb5d655af758c5eeb4825b39ef4ec2ccacd195f4f65d4f5",
    //   sha: latestSha,
    //   version: "1",
    //   path: "packages/denylist",
    // },
  };

  for (const [name, { packageInfo, sha, version, path }] of Object.entries(
    data
  )) {
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

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.denylist),
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
  //     transaction.object(MVRAppCaps.denylist),
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
  //     transaction.object(MVRAppCaps.denylist),
  //     transaction.pure.string("homepage_url"), // key
  //     transaction.pure.string("https://suins.io/"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::set_metadata",
  //   arguments: [
  //     transaction.object(data.denylist.packageInfo),
  //     transaction.pure.string("default"),
  //     transaction.pure.string("@suins/denylist"),
  //   ],
  // });

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::unset_metadata",
  //   arguments: [
  //     transaction.object(data.tempSubnameProxy.packageInfo),
  //     transaction.pure.string("default"),
  //   ],
  // });

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::set_metadata",
  //   arguments: [
  //     transaction.object(data.tempSubnameProxy.packageInfo),
  //     transaction.pure.string("default"),
  //     transaction.pure.string("@suins/temp-subnames-proxy"),
  //   ],
  // });

  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        "0xfb37e3fc36476472675083ff9990bad760545bd7a6c385da1e87dca58099e09b" // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        "0x5afdc6b0c6c2821cd422f8985aea3c36acc6c76bf35520b3d7f47d1f5dc8bf54" // V1 of the subnames package on testnet
      ),
      transaction.pure.option("address", null),
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::unset_network`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(MVRAppCaps.subnames),
      transaction.pure.string("4c78adac"), // testnet
    ],
  });
  transaction.moveCall({
    target: `@mvr/core::move_registry::set_network`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(MVRAppCaps.subnames),
      transaction.pure.string("4c78adac"), // testnet
      appInfo,
    ],
  });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::assign_package`,
  //   arguments: [
  //     transaction.object(
  //       `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
  //     ),
  //     transaction.object(MVRAppCaps.denylist),
  //     transaction.object(data.denylist.packageInfo),
  //   ],
  // });

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of all MVR caps

  console.dir(res, { depth: null });
})();
