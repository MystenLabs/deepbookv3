#!/usr/bin/env tsx
/**
 * Update EnclaveConfig PCRs on-chain.
 *
 * Usage:
 *   npx tsx transactions/maker-incentives/update-pcrs.ts --network testnet --debug
 *   npx tsx transactions/maker-incentives/update-pcrs.ts --network testnet \
 *     --pcr0 abc123... --pcr1 abc123... --pcr2 def456...
 */

import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "./sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    debug: { type: "boolean", default: false },
    pcr0: { type: "string" },
    pcr1: { type: "string" },
    pcr2: { type: "string" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, `deployed.${NETWORK}.json`);

const ENCLAVE_PKG =
  "0x8ecf22e78c90c3e32833d76d82415d7e4227ea370bec4efdad4c4830cbda9e49";

function hexToBytes(hex: string): number[] {
  const clean = hex.replace(/^0x/, "");
  return clean.match(/.{1,2}/g)!.map((b) => parseInt(b, 16));
}

async function main() {
  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const client = getClient(NETWORK);
  const signer = getSigner();

  let pcr0: number[], pcr1: number[], pcr2: number[];

  if (args.debug) {
    console.log("Updating PCRs to all-zeros (debug mode)...");
    pcr0 = pcr1 = pcr2 = new Array(48).fill(0);
  } else if (args.pcr0 && args.pcr1 && args.pcr2) {
    console.log("Updating PCRs to production values...");
    pcr0 = hexToBytes(args.pcr0);
    pcr1 = hexToBytes(args.pcr1);
    pcr2 = hexToBytes(args.pcr2);
    console.log(`  PCR0: ${args.pcr0}`);
    console.log(`  PCR1: ${args.pcr1}`);
    console.log(`  PCR2: ${args.pcr2}`);
  } else {
    console.error(
      "Error: provide --debug or all three --pcr0 --pcr1 --pcr2 flags."
    );
    process.exit(1);
  }

  const tx = new Transaction();
  tx.moveCall({
    target: `${ENCLAVE_PKG}::enclave::update_pcrs`,
    typeArguments: [
      `${config.packageId}::maker_incentives::MAKER_INCENTIVES`,
    ],
    arguments: [
      tx.object(config.enclaveConfigId),
      tx.object(config.enclaveCapId),
      tx.pure("vector<u8>", pcr0),
      tx.pure("vector<u8>", pcr1),
      tx.pure("vector<u8>", pcr2),
    ],
  });
  tx.setGasBudget(50_000_000);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Transaction failed:", result.effects?.status?.error);
    process.exit(1);
  }
  console.log("Status:", status);
  console.log("Tx:", result.digest);
}

main().catch((err) => {
  console.error("Failed:", err.message);
  process.exit(1);
});
