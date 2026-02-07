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

  const data = {
    core: {
      appCap:
        "0x673bac45d749730e71c3ad2395c2942f7dd61167308752b564963228b147edc0",
      description:
        "The foundational component of the Move Registry (MVR). It provides essential on-chain functionality for application registration and resolution in the Sui ecosystem.",
      documentation_url: "https://docs.suins.io/move-registry",
    },
    "subnames-proxy": {
      appCap:
        "0xa24ad6dee0fa4b4a59839a78b638e3157638ac9774b6734af0250b372bf10881",
      description: "Enables registering applications using SuiNS Subnames.",
      documentation_url: "https://docs.suins.io/move-registry",
    },
    metadata: {
      appCap:
        "0x8e5af7f91bcdbcb637eb6774fbb4b23022db864d125f7e74ab17f64646ac73da",
      description:
        "Defines PackageInfo objects, which contain metadata associated with registered Move packages. These objects track upgrade caps, package addresses, Git versioning metadata, and on-chain display configuration.",
      documentation_url: "https://docs.suins.io/move-registry",
    },
    "public-names": {
      appCap:
        "0x4e9264ba30222c1701457ed3d4745c74fd9d736c6609558aafd46ec734e60d78",
      description:
        "This package provides an open interface for creating and managing public names. Public names allow anyone to register apps under the namespace. The core use case for this is the global @pkg name supported on MVR.",
      documentation_url: "https://docs.suins.io/move-registry",
    },
  };

  for (const [
    name,
    { appCap, description, documentation_url },
  ] of Object.entries(data)) {
    transaction.moveCall({
      target: "@mvr/core::move_registry::set_metadata",
      arguments: [
        transaction.object(
          "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
        ),
        transaction.object(appCap),
        transaction.pure.string("description"), // key
        transaction.pure.string(description), // value
      ],
    });

    transaction.moveCall({
      target: "@mvr/core::move_registry::set_metadata",
      arguments: [
        transaction.object(
          "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727" // Move registry
        ),
        transaction.object(appCap),
        transaction.pure.string("documentation_url"), // key
        transaction.pure.string(documentation_url), // value
      ],
    });
  }

  let res = await prepareMultisigTx(transaction, env, holdingAddress); // Owner of appcap for MVR

  console.dir(res, { depth: null });
})();
