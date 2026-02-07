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
    // oldsite:
    //   "0xac82d5c6d183087007b1101ff71c7982c6365c2cd1a36fc9a1b3ea8fe966f545",
    site: "0x31bcfbe17957dae74f7a5dc7439f8e954870646317054ff880084c80d64f2390",
  };

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.site),
  //     transaction.pure.string("icon_url"), // key
  //     transaction.pure.string(
  //       "https://cdn.prod.website-files.com/67bf314c789da9e4d7c30c50/67e506a7980c586cba295748_67c20e44c97b05da454f35f3_walrus-site.svg"
  //     ),
  //   ],
  // });

  const repository = "https://github.com/MystenLabs/walrus-sites";
  const latestSha = "walrus_sites_v0.1.0_1750151671_main_ci";

  const data = {
    site: {
      packageInfo:
        "0x78969731e1f29f996e24261a13dd78c6a0932bc099aa02e27965bbfb1a643d86",
      sha: latestSha,
      version: "1",
      path: "move/walrus_site",
    },
  };

  for (const [name, { packageInfo, sha, version, path }] of Object.entries(
    data
  )) {
    transaction.moveCall({
      target: `@mvr/metadata::package_info::unset_git_versioning`,
      arguments: [
        transaction.object(packageInfo),
        transaction.pure.u64(version),
      ],
    });
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
  //     transaction.object(MVRAppCaps.site),
  //     transaction.pure.string("description"), // key
  //     transaction.pure.string(
  //       "The Walrus sites package. Walrus Sites are websites built using decentralized tech such as Walrus, a decentralized storage network, and the Sui blockchain."
  //     ), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.site),
  //     transaction.pure.string("documentation_url"), // key
  //     transaction.pure.string("https://docs.wal.app/walrus-sites/intro.html"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.site),
  //     transaction.pure.string("homepage_url"), // key
  //     transaction.pure.string("https://walrus.site/"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::unset_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.oldsite),
  //     transaction.pure.string("description"), // key
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::unset_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.oldsite),
  //     transaction.pure.string("documentation_url"), // key
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::unset_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(MVRAppCaps.oldsite),
  //     transaction.pure.string("homepage_url"), // key
  //   ],
  // });

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::unset_metadata",
  //   arguments: [
  //     transaction.object(data.oldsite.packageInfo),
  //     transaction.pure.string("default"),
  //   ],
  // });

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::set_metadata",
  //   arguments: [
  //     transaction.object(data.site.packageInfo),
  //     transaction.pure.string("default"),
  //     transaction.pure.string("@walrus/sites"),
  //   ],
  // });

  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        "0x97be021af63c8b6c5e668f4d398b3a7457ff4c87cf9c347a1da3618e6a0223e4" // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        "0xf99aee9f21493e1590e7e5a9aea6f343a1f381031a04a732724871fc294be799" // V1 of the walrus sites package on testnet
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
      transaction.object(MVRAppCaps.site),
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
  //     transaction.object(MVRAppCaps.site),
  //     transaction.object(data.site.packageInfo),
  //   ],
  // });

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of all MVR caps

  console.dir(res, { depth: null });
})();
