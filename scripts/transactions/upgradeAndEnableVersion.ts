// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { readFileSync, writeFileSync } from "fs";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { normalizeSuiAddress, toBase64 } from "@mysten/sui/utils";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

// Shared by the scripts that upgrade a package and enable its new version in the
// same transaction (mainPackageUpgradeEnableVersion.ts,
// marginPackageUpgradeEnableVersion.ts).
//
// The upgrade commands are the ones `sui client upgrade` builds for the
// upgrade-only scripts. Calls appended after them target the package being
// upgraded, since a transaction cannot call a package it publishes; the
// version-management functions they call skip the version gate.

export const network = "mainnet";

// The fullnode the workflow's sui CLI env points at.
const GRPC_URL = "https://fullnode.mainnet.sui.io:443";
const GRAPHQL_URL = "https://graphql.mainnet.sui.io/graphql";

// Sui caps the signed transaction, signatures included, at max_tx_size_bytes, and
// a simulation does not count the multisig signature. A 4-of-9 multisig signature
// is under 1 KiB.
const SIGNATURE_RESERVE_BYTES = 4 * 1024;

export const client = new SuiGrpcClient({ network, baseUrl: GRPC_URL });

export const readJson = async (objectId: string): Promise<any> => {
  const { object } = await client.core.getObject({
    objectId,
    include: { json: true },
  });
  return object.json;
};

const ownerAddress = async (objectId: string): Promise<string> => {
  const { object } = await client.core.getObject({ objectId });
  const owner: any = object.owner;
  if (owner?.$kind !== "AddressOwner") {
    throw new Error(
      `${objectId} is not address-owned (${JSON.stringify(owner)})`,
    );
  }
  return owner.AddressOwner;
};

export const gql = async (query: string): Promise<any> => {
  const res = await fetch(GRAPHQL_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) throw new Error(`GraphQL ${res.status} ${res.statusText}`);
  const body: any = await res.json();
  if (body.errors) {
    throw new Error(`GraphQL errors: ${JSON.stringify(body.errors)}`);
  }
  return body.data;
};

// The version the upgraded package will assert, as compiled.
export const readVersionConstant = (path: string, name: string): number => {
  const match = readFileSync(path, "utf8").match(
    new RegExp(`const ${name}: u64 = (\\d+);`),
  );
  if (!match) throw new Error(`${name} not found in ${path}`);
  return Number(match[1]);
};

// The inner struct of a registry, which sits in a dynamic field of the
// registry's Versioned wrapper.
export const readVersionedInner = async (registryId: string): Promise<any> => {
  const registry = await readJson(registryId);
  const versionedId = registry?.inner?.id;
  if (!versionedId) throw new Error(`${registryId} has no inner Versioned id`);
  const { dynamicFields } = await client.core.listDynamicFields({
    parentId: versionedId,
  });
  if (dynamicFields.length !== 1) {
    throw new Error(
      `expected 1 inner field on ${registryId}, found ${dynamicFields.length}`,
    );
  }
  return (await readJson(dynamicFields[0].fieldId))?.value;
};

// The registry's allowed versions. Refuses a version already in the set, since
// enable_version would abort EVersionAlreadyEnabled.
export const readAllowedVersions = (
  inner: any,
  version: number,
  constantName: string,
): number[] => {
  const allowed: number[] = (inner?.allowed_versions?.contents ?? [])
    .map(Number)
    .sort((a: number, b: number) => a - b);
  console.log(`registry allowed_versions: {${allowed.join(", ")}}`);
  if (allowed.includes(version)) {
    throw new Error(
      `version ${version} is already enabled, so enable_version would abort ` +
        `EVersionAlreadyEnabled. Bump ${constantName} before upgrading`,
    );
  }
  return allowed;
};

// The CLI's upgrade transaction for the package in `packageDir`, checked to be
// exactly authorize_upgrade, Upgrade and commit_upgrade on the package the
// UpgradeCap controls. Returns that package, which appended calls target, and
// the package IDs the upgrade links.
export const buildUpgradeTx = async (
  packageDir: string,
  upgradeCapId: string,
): Promise<{
  tx: Transaction;
  currentPackage: string;
  dependencies: string[];
}> => {
  const cap = await readJson(upgradeCapId);
  const currentPackage: string = cap?.package;
  if (!currentPackage) throw new Error("UpgradeCap has no package");
  console.log(`upgrading from package ${currentPackage}`);

  // The CLI can print progress lines before the bytes, which come last.
  const lines = serializeUnsignedUpgrade({
    cwd: packageDir,
    extraArgs: ["--upgrade-capability", upgradeCapId],
  })
    .trim()
    .split("\n");
  const tx = Transaction.from(lines[lines.length - 1].trim());

  const data = tx.getData();
  const kinds = data.commands.map((command) => command.$kind).join(", ");
  if (kinds !== "MoveCall, Upgrade, MoveCall") {
    throw new Error(`unexpected upgrade commands from the sui CLI: ${kinds}`);
  }
  const upgrade = data.commands[1].Upgrade!;
  if (upgrade.package !== currentPackage) {
    throw new Error(
      `the CLI upgrades ${upgrade.package}, but the UpgradeCap controls ` +
        currentPackage,
    );
  }
  return {
    tx,
    currentPackage,
    dependencies: upgrade.dependencies.map((id) => normalizeSuiAddress(id)),
  };
};

// One sender signs the whole transaction, so it must own every cap it spends.
// The CLI sets the sender to the gas coin's owner.
export const assertSenderOwns = async (
  tx: Transaction,
  caps: Record<string, string>,
): Promise<void> => {
  const sender = tx.getData().sender;
  for (const [name, id] of Object.entries(caps)) {
    const owner = await ownerAddress(id);
    if (owner !== sender) {
      throw new Error(
        `${name} ${id} is owned by ${owner}, not the sender ${sender}. One ` +
          `transaction needs every cap and the gas coin at one address`,
      );
    }
  }
  console.log(`sender: ${sender} (owns the ${Object.keys(caps).join(", ")})`);
};

// Builds the transaction, refuses one too large to sign, simulates it against
// Mainnet, and writes the bytes to `txFilePath`.
export const writeSimulatedTx = async (
  tx: Transaction,
  txFilePath: string,
): Promise<void> => {
  const bytes = await tx.build({ client });
  const maxTxBytes = Number(
    (
      await gql(
        `{ protocolConfigs { config(key: "max_tx_size_bytes") { value } } }`,
      )
    ).protocolConfigs.config.value,
  );
  if (bytes.length + SIGNATURE_RESERVE_BYTES > maxTxBytes) {
    throw new Error(
      `the transaction is ${bytes.length} bytes, too close to the ` +
        `${maxTxBytes}-byte limit to leave room for the multisig signature`,
    );
  }
  console.log(`transaction size: ${bytes.length} of ${maxTxBytes} bytes`);

  const simulation = await client.core.simulateTransaction({
    transaction: bytes,
    include: { effects: true },
  });
  const effects = (simulation.Transaction ?? simulation.FailedTransaction)
    ?.effects;
  if (!effects?.status.success) {
    throw new Error(
      `simulation failed: ${JSON.stringify(effects?.status ?? simulation)}`,
    );
  }
  console.log(`simulation succeeded, gas ${JSON.stringify(effects.gasUsed)}`);
  console.log(`digest: ${await Transaction.from(bytes).getDigest()}`);

  writeFileSync(txFilePath, toBase64(bytes));
  console.log("Upgrade and enable-version transaction saved to tx-data.txt");
};
