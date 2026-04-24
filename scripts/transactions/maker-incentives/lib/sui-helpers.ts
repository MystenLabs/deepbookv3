/**
 * Minimal Sui client helpers for maker-incentives scripts.
 * Self-contained — no dependency on the shared utils.ts which may
 * import packages not available in the local node_modules.
 */

import { execSync } from "child_process";
import { readFileSync } from "fs";
import { homedir } from "os";
import path from "path";
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { fromBase64 } from "@mysten/sui/utils";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const SUI = process.env.SUI_BINARY ?? "sui";

export function getActiveAddress(): string {
  return execSync(`${SUI} client active-address`, { encoding: "utf8" }).trim();
}

export function getSigner(): Ed25519Keypair {
  if (process.env.PRIVATE_KEY) {
    const { decodeSuiPrivateKey } = require("@mysten/sui/cryptography");
    const { schema, secretKey } = decodeSuiPrivateKey(process.env.PRIVATE_KEY);
    if (schema === "ED25519") return Ed25519Keypair.fromSecretKey(secretKey);
    throw new Error(`Unsupported key schema: ${schema}`);
  }

  const sender = getActiveAddress();
  const keystorePath = path.join(
    homedir(),
    ".sui",
    "sui_config",
    "sui.keystore"
  );
  const keystore: string[] = JSON.parse(readFileSync(keystorePath, "utf8"));

  for (const priv of keystore) {
    const raw = fromBase64(priv);
    if (raw[0] !== 0) continue;
    const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
    if (pair.getPublicKey().toSuiAddress() === sender) return pair;
  }

  throw new Error(`Keypair not found for sender: ${sender}`);
}

export function getClient(network: Network): SuiJsonRpcClient {
  const url = process.env.RPC_URL || getJsonRpcFullnodeUrl(network);
  return new SuiJsonRpcClient({ url });
}
