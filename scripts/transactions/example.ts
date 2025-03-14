// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { execSync } from "child_process";
import { readFileSync } from "fs";
import { homedir } from "os";
import path from "path";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Secp256k1Keypair } from "@mysten/sui/keypairs/secp256k1";
import { Secp256r1Keypair } from "@mysten/sui/keypairs/secp256r1";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64 } from "@mysten/sui/utils";

import { newTransaction } from "./transaction";

const SUI = process.env.SUI_BINARY ?? `sui`;

export const getActiveAddress = () => {
  return execSync(`${SUI} client active-address`, { encoding: "utf8" }).trim();
};

export const getSigner = () => {
  if (process.env.PRIVATE_KEY) {
    console.log("Using supplied private key.");
    const { schema, secretKey } = decodeSuiPrivateKey(process.env.PRIVATE_KEY);

    if (schema === "ED25519") return Ed25519Keypair.fromSecretKey(secretKey);
    if (schema === "Secp256k1")
      return Secp256k1Keypair.fromSecretKey(secretKey);
    if (schema === "Secp256r1")
      return Secp256r1Keypair.fromSecretKey(secretKey);

    throw new Error("Keypair not supported.");
  }

  const sender = getActiveAddress();

  const keystore = JSON.parse(
    readFileSync(
      path.join(homedir(), ".sui", "sui_config", "sui.keystore"),
      "utf8"
    )
  );

  for (const priv of keystore) {
    const raw = fromBase64(priv);
    if (raw[0] !== 0) {
      continue;
    }

    const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
    if (pair.getPublicKey().toSuiAddress() === sender) {
      return pair;
    }
  }

  throw new Error(`keypair not found for sender: ${sender}`);
};

export const signAndExecute = async (txb: Transaction, network: Network) => {
  const client = getClient(network);
  const signer = getSigner();

  return client.signAndExecuteTransaction({
    transaction: txb,
    signer,
    options: {
      showEffects: true,
      showObjectChanges: true,
    },
  });
};
export const getClient = (network: Network) => {
  const url = process.env.RPC_URL || getFullnodeUrl(network);
  return new SuiClient({ url });
};

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

(async () => {
  // Update constant for env
  const env = "testnet";
  const transaction = newTransaction();

  // /// We pass in our UpgradeCap
  // const packageInfo = transaction.moveCall({
  //   target: `@mvr/metadata::package_info::new`,
  //   arguments: [
  //     transaction.object(
  //       "0x479467ad71ba0b7f93b38b26cb121fbd181ae2db8c91585d3572db4aaa764ffb"
  //     ),
  //   ],
  // });

  // // We also need to create the visual representation of our "info" object.
  // // You can also call `@mvr/metadata::display::new` instead,
  // // that allows customizing the colors of your metadata object!
  // const display = transaction.moveCall({
  //   target: `@mvr/metadata::display::default`,
  //   arguments: [transaction.pure.string("DeepbookV3")],
  // });

  // // Set that display object to our info object.
  // transaction.moveCall({
  //   target: `@mvr/metadata::package_info::set_display`,
  //   arguments: [transaction.object(packageInfo), display],
  // });

  // // transfer the `PackageInfo` object to a safe address.
  // transaction.moveCall({
  //   target: `@mvr/metadata::package_info::transfer`,
  //   arguments: [
  //     transaction.object(packageInfo),
  //     transaction.pure.address(
  //       "0xb3d277c50f7b846a5f609a8d13428ae482b5826bb98437997373f3a0d60d280e"
  //     ),
  //   ],
  // });

  // const git = transaction.moveCall({
  //   target: `@mvr/metadata::git::new`,
  //   arguments: [
  //     transaction.pure.string("https://github.com/MystenLabs/deepbookv3"),
  //     transaction.pure.string("packages/deepbook"),
  //     transaction.pure.string("b9082548ee8181e118fcab618778cf2a9bae3b2e"),
  //   ],
  // });

  // transaction.moveCall({
  //   target: `@mvr/metadata::package_info::set_git_versioning`,
  //   arguments: [
  //     transaction.object(
  //       `0x35f509124a4a34981e5b1ba279d1fdfc0af3502ae1edf101e49a2d724a4c1a34`
  //     ),
  //     transaction.pure.u64(`1`),
  //     git,
  //   ],
  // });

  //   public fun set_metadata(registry: &mut MoveRegistry, cap: &AppCap, key: String, value: String) {
  //     registry.borrow_record_mut(cap).set_metadata_key(key, value);
  // }

  const appCap = transaction.moveCall({
    target: `@mvr/core::move_registry::register`,
    arguments: [
      // the registry obj: Can also be resolved as `registry-obj@mvr` from mainnet SuiNS.
      transaction.object(
        "0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"
      ),
      transaction.object(
        "0xd0815f9867a0a02690a9fe3b5be9a044bb381f96c660ba6aa28dfaaaeb76af76"
      ), // deepbook domain
      transaction.pure.string("core"), // name
      transaction.object.clock(),
    ],
  });

  transaction.transferObjects(
    [appCap],
    "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e"
  ); // This is the deepbook adminCap owner

  let res = await signAndExecute(transaction, env);

  console.dir(res, { depth: null });
})();
