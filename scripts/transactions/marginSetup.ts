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

  const data = {
    packageInfo:
      "0x11c2e0f7292ea1b84ed894302b96146872fea53a99b933122fb193e48dac1005",
    sha: "margin-v1.0.0",
    version: "1",
    path: "packages/deepbook_margin",
  };

  const display = transaction.moveCall({
    target: `@mvr/metadata::display::default`,
    arguments: [transaction.pure.string("DeepBookV3 - Margin Metadata")],
  });

  // Set that display object to our info object.
  transaction.moveCall({
    target: `@mvr/metadata::package_info::set_display`,
    arguments: [transaction.object(data.packageInfo), display],
  });

  const git = transaction.moveCall({
    target: `@mvr/metadata::git::new`,
    arguments: [
      transaction.pure.string(repository),
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

  // Link margin to correct packageInfo
  // Important to check these two
  transaction.moveCall({
    target: `@mvr/core::move_registry::assign_package`,
    arguments: [
      transaction.object(
        `0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727`,
      ),
      transaction.object(appCap),
      transaction.object(data.packageInfo),
    ],
  });

  let res = await prepareMultisigTx(
    transaction,
    env,
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e",
  ); // multisig address

  console.dir(res, { depth: null });
})();
