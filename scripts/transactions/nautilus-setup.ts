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
    nautilus:
      "0x8a159edc9ee8d809a980b3eb66510b6a6b608d8a79abb0576916430e4a7389b8",
    seal: "0x5c05d47053b0b3126dc99ee97264bf0d8b52e5789ca33917b88d83eb63f0e434",
    sites: "0x31bcfbe17957dae74f7a5dc7439f8e954870646317054ff880084c80d64f2390",
  };

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.nautilus),
      transaction.pure.string("icon_url"), // key
      transaction.pure.string("https://svg-host.vercel.app/mystenlogo.svg"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.seal),
      transaction.pure.string("icon_url"), // key
      transaction.pure.string(
        "https://drive.google.com/file/d/1MwZmWh2GiEzxfw5zIeoNrst3v7fbnuO5/view?usp=sharing"
      ),
    ],
  });

  const data = {
    nautilus: {
      repository: "https://github.com/MystenLabs/nautilus",
      packageInfo:
        "0x427579e9f0f3200cc51a634b33088895879f38783655297f4ed2442351cd53d0",
      sha: "d919402aadf15e21b3cf31515b3a46d1ca6965e4",
      version: "1",
      path: "move/enclave",
    },
    // seal: {
    //   repository: "https://github.com/MystenLabs/seal",
    //   packageInfo:
    //     "0x78969731e1f29f996e24261a13dd78c6a0932bc099aa02e27965bbfb1a643d86",
    //   sha: "9aafac05433aa86c7ee1d6d971f253cc4f6e8edb", // TODO: update sha
    //   version: "1",
    //   path: "",
    // },
    // deepbook: {
    //   repository: "https://github.com/MystenLabs/deepbookv3",
    //   packageInfo: "", // TODO
    //   sha: "v3.0.0",
    //   version: "3",
    //   path: "packages/deepbook",
    // },
  };

  for (const [
    name,
    { repository, packageInfo, sha, version, path },
  ] of Object.entries(data)) {
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
      transaction.object(MVRAppCaps.nautilus),
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "Nautilus is a framework for secure and verifiable off chain computation on Sui."
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.nautilus),
      transaction.pure.string("documentation_url"), // key
      transaction.pure.string(
        "https://docs.sui.io/concepts/cryptography/nautilus"
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.nautilus),
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://sui.io/nautilus"), // value
    ],
  });

  transaction.moveCall({
    target: "@mvr/metadata::package_info::set_metadata",
    arguments: [
      transaction.object(data.nautilus.packageInfo),
      transaction.pure.string("default"),
      transaction.pure.string("@mysten/nautilus"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.seal),
      transaction.pure.string("description"), // key
      transaction.pure.string(
        "Seal is a decentralized secrets management (DSM) service that relies on access control policies defined and validated on Sui."
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.seal),
      transaction.pure.string("documentation_url"), // key
      transaction.pure.string(
        "https://github.com/MystenLabs/seal/blob/main/UsingSeal.md"
      ), // value
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.seal),
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://seal.mystenlabs.com"), // value
    ],
  });

  const appInfo = transaction.moveCall({
    target: `@mvr/core::app_info::new`,
    arguments: [
      transaction.pure.option(
        "address",
        "0xfe94e6c85433a1a933760d7111bf7e26dfef12403f7c8f90f2bd7f184715abeb" // PackageInfo object on testnet
      ),
      transaction.pure.option(
        "address",
        "0x0f16e84a49dec8425e6900cfdfe3730aaf1e8bc608d9f0500fcfa2c2267abfb4" // V1 of the seal package on testnet
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
      transaction.object(MVRAppCaps.seal),
      transaction.pure.string("4c78adac"), // testnet
      appInfo,
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
      ),
      transaction.object(MVRAppCaps.nautilus),
      transaction.object(data.nautilus.packageInfo),
    ],
  });

  // Sites changes
  transaction.moveCall({
    target: `@mvr/core::move_registry::unset_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.sites),
      transaction.pure.string("homepage_url"), // key
    ],
  });

  transaction.moveCall({
    target: `@mvr/core::move_registry::set_metadata`,
    arguments: [
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
      ),
      transaction.object(MVRAppCaps.sites),
      transaction.pure.string("homepage_url"), // key
      transaction.pure.string("https://wal.app/"), // value
    ],
  });

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of all MVR caps

  console.dir(res, { depth: null });
})();
