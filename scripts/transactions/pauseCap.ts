// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { execSync } from "child_process";
import { readFileSync } from "fs";
import { homedir } from "os";
import path from "path";
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Secp256k1Keypair } from "@mysten/sui/keypairs/secp256k1";
import { Secp256r1Keypair } from "@mysten/sui/keypairs/secp256r1";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64 } from "@mysten/sui/utils";
import { deepbook } from "@mysten/deepbook-v3";

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

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

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
  const url = process.env.RPC_URL || getJsonRpcFullnodeUrl(network);
  return new SuiJsonRpcClient({ url, network });
};

(async () => {
  // Update constant for env
  const env = "mainnet";
  const version = 1; // Version to pause
  const pauseCapID = ""; // Fill in the pause cap ID
  const tx = new Transaction();

  const client = new SuiGrpcClient({
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: getActiveAddress(),
      adminCap: "",
    })
  );

  client.deepbook.marginAdmin.disableVersionPauseCap(version, pauseCapID)(tx);

  let res = await signAndExecute(tx, env);

  console.dir(res, { depth: null });
})();
