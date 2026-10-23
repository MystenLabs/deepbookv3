// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { readFileSync, writeFileSync } from "fs";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { toBase64 } from "@mysten/sui/utils";
import { adminCapID, registryID, upgradeCapID } from "../config/constants.js";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

// Upgrades DeepBook core and enables the new package's version in one transaction.
//
// An upgrade alone is dead on arrival: every gated entrypoint asserts its
// constants::CURRENT_VERSION is allowed, by the Registry and by each Pool's cached
// copy of the Registry's set. So after the upgrade commands this appends
// registry::enable_version for the new CURRENT_VERSION, then
// pool::update_pool_allowed_versions on every pool.
//
// The upgrade commands are the ones `sui client upgrade` builds for
// mainPackageUpgrade.ts. The appended calls target the package being upgraded,
// since a transaction cannot call a package it publishes, and both functions skip
// the version gate.
//
// One sender signs the whole transaction, so the UpgradeCap, the DeepbookAdminCap
// and the gas coin must share an owner.

const network = "mainnet";

// The fullnode the workflow's sui CLI env points at.
const GRPC_URL = "https://fullnode.mainnet.sui.io:443";
const GRAPHQL_URL = "https://graphql.mainnet.sui.io/graphql";

const client = new SuiGrpcClient({ network, baseUrl: GRPC_URL });

const readJson = async (objectId: string): Promise<any> => {
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

const gql = async (query: string): Promise<any> => {
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
const readCurrentVersion = (deepbookDir: string): number => {
  const source = readFileSync(
    `${deepbookDir}/sources/helper/constants.move`,
    "utf8",
  );
  const match = source.match(/const CURRENT_VERSION: u64 = (\d+);/);
  if (!match) throw new Error("CURRENT_VERSION not found in constants.move");
  return Number(match[1]);
};

// RegistryInner sits in a dynamic field of the Registry's Versioned wrapper.
const readRegistryInner = async (registryId: string): Promise<any> => {
  const registry = await readJson(registryId);
  const versionedId = registry?.inner?.id;
  if (!versionedId) throw new Error("Registry has no inner Versioned id");
  const { dynamicFields } = await client.core.listDynamicFields({
    parentId: versionedId,
  });
  if (dynamicFields.length !== 1) {
    throw new Error(
      `expected 1 RegistryInner field, found ${dynamicFields.length}`,
    );
  }
  return (await readJson(dynamicFields[0].fieldId))?.value;
};

// Split the type arguments of `Pool<Base, Quote>`, respecting nested generics.
const poolTypeArgs = (type: string): [string, string] => {
  const inner = type.slice(type.indexOf("<") + 1, type.lastIndexOf(">"));
  let depth = 0;
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === "<") depth++;
    else if (inner[i] === ">") depth--;
    else if (inner[i] === "," && depth === 0) {
      return [inner.slice(0, i).trim(), inner.slice(i + 1).trim()];
    }
  }
  throw new Error(`cannot split the type arguments of ${type}`);
};

// Every Pool object by type, not just the pools the Registry lists: an
// unregistered pool keeps trading on its own cached allowed versions.
const listPools = async (
  originalId: string,
): Promise<{ id: string; typeArgs: [string, string] }[]> => {
  const pools: { id: string; typeArgs: [string, string] }[] = [];
  let after: string | null = null;
  do {
    const cursor: string = after ? `, after: "${after}"` : "";
    const data = await gql(
      `{ objects(filter: { type: "${originalId}::pool::Pool" }, first: 50${cursor}) {
        pageInfo { hasNextPage endCursor }
        nodes { address asMoveObject { contents { type { repr } } } }
      } }`,
    );
    for (const node of data.objects.nodes) {
      const type = node.asMoveObject?.contents?.type?.repr;
      if (!type) throw new Error(`pool ${node.address} returned no type`);
      pools.push({ id: node.address, typeArgs: poolTypeArgs(type) });
    }
    after = data.objects.pageInfo.hasNextPage
      ? data.objects.pageInfo.endCursor
      : null;
  } while (after);
  return pools;
};

const mainPackageUpgradeEnableVersion = async () => {
  const currentDir = process.cwd();
  const deepbookDir = `${currentDir}/../packages/deepbook`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  const version = readCurrentVersion(deepbookDir);
  console.log(`enabling version ${version} (CURRENT_VERSION in this build)`);

  // The package the upgrade replaces. The appended calls target it.
  const cap = await readJson(upgradeCapID[network]);
  const currentPackage: string = cap?.package;
  if (!currentPackage) throw new Error("UpgradeCap has no package");
  console.log(`upgrading from package ${currentPackage}`);

  const inner = await readRegistryInner(registryID[network]);
  const allowed: number[] = (inner?.allowed_versions?.contents ?? [])
    .map(Number)
    .sort((a: number, b: number) => a - b);
  console.log(`registry allowed_versions: {${allowed.join(", ")}}`);
  if (allowed.includes(version)) {
    throw new Error(
      `version ${version} is already enabled, so enable_version would abort ` +
        `EVersionAlreadyEnabled. Bump CURRENT_VERSION before upgrading`,
    );
  }

  const tx = Transaction.from(
    serializeUnsignedUpgrade({
      cwd: deepbookDir,
      extraArgs: ["--upgrade-capability", upgradeCapID[network]],
    }).trim(),
  );
  const data = tx.getData();
  const kinds = data.commands.map((command) => command.$kind).join(", ");
  if (kinds !== "MoveCall, Upgrade, MoveCall") {
    throw new Error(`unexpected upgrade commands from the sui CLI: ${kinds}`);
  }
  if (data.commands[1].Upgrade?.package !== currentPackage) {
    throw new Error(
      `the CLI upgrades ${data.commands[1].Upgrade?.package}, but the ` +
        `UpgradeCap controls ${currentPackage}`,
    );
  }

  const sender = data.sender;
  const [capOwner, adminOwner] = await Promise.all([
    ownerAddress(upgradeCapID[network]),
    ownerAddress(adminCapID[network]),
  ]);
  if (sender !== capOwner || sender !== adminOwner) {
    throw new Error(
      `sender ${sender}, UpgradeCap owner ${capOwner} and AdminCap owner ` +
        `${adminOwner} must be one address to sign one transaction`,
    );
  }
  console.log(`sender: ${sender} (owns the UpgradeCap and the AdminCap)`);

  tx.moveCall({
    target: `${currentPackage}::registry::enable_version`,
    arguments: [
      tx.object(registryID[network]),
      tx.pure.u64(version),
      tx.object(adminCapID[network]),
    ],
  });

  const registryType = (
    await client.core.getObject({ objectId: registryID[network] })
  ).object.type;
  const originalId = registryType.split("::")[0];
  const pools = await listPools(originalId);
  // A lower bound on the enumeration: every registered pool is a Pool object.
  const registered = Number(inner?.pools?.size ?? 0);
  if (pools.length < registered) {
    throw new Error(
      `found ${pools.length} pools but the Registry lists ${registered}. ` +
        `The pool enumeration is incomplete`,
    );
  }
  console.log(
    `updating allowed versions on ${pools.length} pools ` +
      `(${registered} registered)`,
  );
  for (const pool of pools) {
    tx.moveCall({
      target: `${currentPackage}::pool::update_pool_allowed_versions`,
      typeArguments: pool.typeArgs,
      arguments: [tx.object(pool.id), tx.object(registryID[network])],
    });
  }

  // The CLI budgets 2 SUI for the upgrade alone. Rewriting every pool adds
  // storage: the 91-pool build on 2026-10-23 charged 1.70 SUI gross before
  // rebates, so leave room for pool growth before execution.
  tx.setGasBudget(3_000_000_000);

  const bytes = await tx.build({ client });
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
  console.log(
    `after this executes, the registry and every pool above allow ` +
      `{${[...allowed, version].sort((a, b) => a - b).join(", ")}}`,
  );
  console.log(`digest: ${await Transaction.from(bytes).getDigest()}`);

  writeFileSync(txFilePath, toBase64(bytes));
  console.log("Upgrade and enable-version transaction saved to tx-data.txt");
};

mainPackageUpgradeEnableVersion().catch((error: any) => {
  console.error("Error during protocol upgrade:", error.message);
  console.error("stderr:", error.stderr?.toString());
  console.error("stdout:", error.stdout?.toString());
  process.exit(1);
});
