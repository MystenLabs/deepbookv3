// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { namedPackagesPlugin, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const mainnetPlugin = namedPackagesPlugin({
  url: "https://mainnet.mvr.mystenlabs.com",
});
(async () => {
  const env = "mainnet";
  const transaction = new Transaction();
  transaction.addSerializationPlugin(mainnetPlugin);

  // appcap holding address
  const holdingAddress =
    "0x10a1fc2b9170c6bac858fdafc7d3cb1f4ea659fed748d18eff98d08debf82042";

  const MVRAppCaps = {
    site: "", // TODO
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

  const repository = "https://github.com/MystenLabs/walrus-sites";
  const latestSha = "walrus_sites_v0.1.0_1748855538_main_ci";

  const data = {
    site: {
      packageInfo: "", // TODO
      sha: latestSha,
      version: "1",
      path: "move/walrus_site",
    },
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

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.site),
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "The Walrus sites package. Walrus Sites are websites built using decentralized tech such as Walrus, a decentralized storage network, and the Sui blockchain."
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.site),
      transaction.pure.string("documentation_url"), // key
      transaction.pure.string("https://docs.wal.app/walrus-sites/intro.html"), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.site),
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://walrus.site/"), // value
    ],
  });

  transaction.moveCall({
    target: "@mvr/metadata::package_info::set_metadata",
    arguments: [
      transaction.object(data.site.packageInfo),
      transaction.pure.string("default"),
      transaction.pure.string("@walrus/sites"),
    ],
  });

  // const appInfo = transaction.moveCall({
  //   target: `@mvr/core::app_info::new`,
  //   arguments: [
  //     transaction.pure.option(
  //       "address",
  //       "0xb82af529b54f90474e523467123c7e255903d0713ec8b7f0125794f94742c7bc" // PackageInfo object on testnet
  //     ),
  //     transaction.pure.option(
  //       "address",
  //       "0xa86c05fbc6371788eb31260dc5085f4bfeab8b95c95d9092c9eb86e63fae3d49" // V1 of the walrus sites package on testnet
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
  //     transaction.object(MVRAppCaps.site),
  //     transaction.pure.string("4c78adac"), // testnet
  //     appInfo,
  //   ],
  // });

  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
      ),
      transaction.object(MVRAppCaps.site),
      transaction.object(data.site.packageInfo),
    ],
  });

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of all MVR caps

  console.dir(res, { depth: null });
})();
