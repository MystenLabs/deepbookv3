#!/usr/bin/env tsx
/**
 * Register the Nautilus enclave on-chain.
 *
 * Usage:
 *   npx tsx transactions/maker-incentives/contract/register-enclave.ts --network testnet --enclave-url http://<ip>:3000
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, getActiveAddress } from "../lib/sui-helpers.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const { values: args } = parseArgs({
  options: {
    network: { type: "string", short: "n", default: "testnet" },
    "enclave-url": { type: "string", default: "http://localhost:3000" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const CONFIG_FILE = path.resolve(__dirname, '..', `deployed.${NETWORK}.json`);
const ENCLAVE_URL = args["enclave-url"]!;

const CLOCK_ID = "0x6";
const ENCLAVE_PACKAGE_ID =
  "0x8ecf22e78c90c3e32833d76d82415d7e4227ea370bec4efdad4c4830cbda9e49";

function log(step: string, msg: string) {
  const ts = new Date().toISOString().split("T")[1].split(".")[0];
  console.log(`[${ts}] ${step.padEnd(12)} | ${msg}`);
}

async function main() {
  console.log("\n" + "=".repeat(60));
  console.log("  MAKER INCENTIVES — REGISTER ENCLAVE");
  console.log("=".repeat(60));

  const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
  const client = getClient(NETWORK);
  const signer = getSigner();

  console.log(`  Network:        ${NETWORK}`);
  console.log(`  Enclave URL:    ${ENCLAVE_URL}`);
  console.log(`  EnclaveConfig:  ${config.enclaveConfigId}`);
  console.log(`  Package:        ${config.packageId}`);
  console.log();

  log("ATTEST", "Fetching attestation from enclave...");
  const attestRes = await fetch(`${ENCLAVE_URL}/get_attestation`);
  if (!attestRes.ok) {
    console.error(`Attestation fetch failed: ${attestRes.status}`);
    process.exit(1);
  }

  const attestData = (await attestRes.json()) as { attestation: string };
  const attestHex = attestData.attestation;
  log("ATTEST", `Got attestation (${attestHex.length / 2} bytes)`);

  const attestBytes = new Uint8Array(
    attestHex.match(/.{1,2}/g)!.map((b: string) => parseInt(b, 16))
  );

  log("REGISTER", "Building transaction...");
  const tx = new Transaction();

  const [document] = tx.moveCall({
    target: `0x2::nitro_attestation::load_nitro_attestation`,
    arguments: [
      tx.pure("vector<u8>", Array.from(attestBytes)),
      tx.object(CLOCK_ID),
    ],
  });

  tx.moveCall({
    target: `${ENCLAVE_PACKAGE_ID}::enclave::register_enclave`,
    typeArguments: [
      `${config.packageId}::maker_incentives::MAKER_INCENTIVES`,
    ],
    arguments: [tx.object(config.enclaveConfigId), document],
  });

  tx.setGasBudget(100_000_000);

  log("REGISTER", "Executing transaction...");
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Transaction failed:", result.effects?.status?.error);
    process.exit(1);
  }

  log("REGISTER", `Tx: ${result.digest}`);
  await client.waitForTransaction({ digest: result.digest });

  const enclaveObjId =
    (
      result.objectChanges?.find(
        (c: any) =>
          c.type === "created" && (c as any).objectType?.includes("Enclave<")
      ) as any
    )?.objectId ?? "";

  log("REGISTER", `Enclave object: ${enclaveObjId}`);

  config.enclaveObjectId = enclaveObjId;
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  log("CONFIG", "Updated deployed config with new enclave object ID.");

  console.log("\n" + "=".repeat(60));
  console.log("  ENCLAVE REGISTERED");
  console.log("=".repeat(60));
  console.log(`  Enclave ID: ${enclaveObjId}`);
  console.log(
    `  The enclave can now sign epoch results that will be accepted on-chain.\n`
  );
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
