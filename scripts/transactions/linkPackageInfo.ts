// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const transaction = new Transaction();
  // const appCapObjectId =
  //   "0xae2d10803aa2f22e3756235d0f98da17e3aa3e4de8dd0062822e2e899e901a04";
  const packageInfoId =
    "0x4874e126c490e495ff7490523841bdba57e2a01ed36db7610f07d417c8b5a988";

  // 1. Sets git versioning for mainnet
  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string("https://github.com/MystenLabs/deepbookv3"),
      transaction.pure.string("packages/deepbook"),
      transaction.pure.string("v3.0.0"),
    ],
  });

  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_git_versioning`,
    arguments: [
      transaction.object(packageInfoId),
      transaction.pure.u64(`3`),
      git,
    ],
  });

  // // 2. Set metadata for mainnet (description, icon_url, documentation_url, homepage_url)
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("description"), // key
  //     transaction.pure.string(
  //       "DeepBook V3 is a next-generation decentralized central limit order book (CLOB) built on Sui. DeepBook leverages Sui's parallel execution and low transaction fees to bring a highly performant, low-latency exchange on chain."
  //     ), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("icon_url"), // key
  //     transaction.pure.string("https://images.deepbook.tech/icon.svg"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("documentation_url"), // key
  //     transaction.pure.string("https://docs.sui.io/standards/deepbookv3"), // value
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::set_metadata`,
  //   arguments: [
  //     transaction.object(
  //       "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("homepage_url"), // key
  //     transaction.pure.string("https://deepbook.tech/"), // value
  //   ],
  // });

  // // 3. Set default metadata for mainnet

  // transaction.moveCall({
  //   target: "@mvr/metadata::package_info::set_metadata",
  //   arguments: [
  //     transaction.object(packageInfoId),
  //     transaction.pure.string("default"),
  //     transaction.pure.string("@deepbook/core"),
  //   ],
  // });

  // // 4. Links testnet packageInfo
  // const appInfo = transaction.moveCall({
  //   target: `@mvr/core::app_info::new`,
  //   arguments: [
  //     transaction.pure.option(
  //       "address",
  //       "0x35f509124a4a34981e5b1ba279d1fdfc0af3502ae1edf101e49a2d724a4c1a34" // PackageInfo object on testnet
  //     ),
  //     transaction.pure.option(
  //       "address",
  //       "0x984757fc7c0e6dd5f15c2c66e881dd6e5aca98b725f3dbd83c445e057ebb790a" // V2 of the package on testnet
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
  //     transaction.object(appCapObjectId),
  //     transaction.pure.string("4c78adac"), // testnet
  //     appInfo,
  //   ],
  // });

  // // 5. Linked mainnet packageInfo with appCap
  // transaction.moveCall({
  //   target: `@mvr/core::move_registry::assign_package`,
  //   arguments: [
  //     transaction.object(
  //       `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`
  //     ),
  //     transaction.object(appCapObjectId),
  //     transaction.object(packageInfoId),
  //   ],
  // });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e"
  ); // Deepbook Admin Account
  // coin = "0x963fd41bec98d100d3575c551445f5ea7f924b507d9fb6857dd3a0867dfaa80e"

  console.dir(res, { depth: null });
})();
