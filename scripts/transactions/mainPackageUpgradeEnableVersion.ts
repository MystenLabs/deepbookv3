// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { normalizeSuiAddress } from "@mysten/sui/utils";
import { adminCapID, registryID, upgradeCapID } from "../config/constants.js";
import {
  assertSenderOwns,
  buildUpgradeTx,
  client,
  gql,
  network,
  readAllowedVersions,
  readVersionConstant,
  readVersionedInner,
  writeSimulatedTx,
} from "./upgradeAndEnableVersion.js";

// Upgrades DeepBook core and enables the new package's version in one transaction.
//
// An upgrade alone is dead on arrival: every gated entrypoint asserts its
// constants::CURRENT_VERSION is allowed, by the Registry and by each Pool's cached
// copy of the Registry's set. So after the upgrade commands this appends
// registry::enable_version for the new CURRENT_VERSION, then
// pool::update_pool_allowed_versions on every pool.
//
// The pool sweep covers the pools that exist when the transaction is built. Pool
// creation is permissionless, and a pool created before the transaction executes
// copies the Registry's set without the new version, so sweep and check every
// pool again after execution.

// The pool ID of every entry in the Registry's `pools` Bag.
const listRegisteredPoolIds = async (bagId: string): Promise<string[]> => {
  const fieldIds: string[] = [];
  let cursor: string | null = null;
  do {
    const page = await client.core.listDynamicFields({
      parentId: bagId,
      cursor,
    });
    fieldIds.push(...page.dynamicFields.map((field) => field.fieldId));
    cursor = page.hasNextPage ? page.cursor : null;
  } while (cursor);

  const ids: string[] = [];
  for (let i = 0; i < fieldIds.length; i += 50) {
    const { objects } = await client.core.getObjects({
      objectIds: fieldIds.slice(i, i + 50),
      include: { json: true },
    });
    for (const object of objects) {
      if (object instanceof Error) throw object;
      ids.push(normalizeSuiAddress((object.json as any).value));
    }
  }
  return ids;
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

  const version = readVersionConstant(
    `${deepbookDir}/sources/helper/constants.move`,
    "CURRENT_VERSION",
  );
  console.log(`enabling version ${version} (CURRENT_VERSION in this build)`);

  const inner = await readVersionedInner(registryID[network]);
  const allowed = readAllowedVersions(inner, version, "CURRENT_VERSION");

  const { tx, currentPackage } = await buildUpgradeTx(
    deepbookDir,
    upgradeCapID[network],
  );
  await assertSenderOwns(tx, {
    UpgradeCap: upgradeCapID[network],
    AdminCap: adminCapID[network],
  });

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
  // Every registered pool must be in the enumeration. Comparing counts is not
  // enough, since the unregistered pools could hide a registered one it missed.
  const registered = await listRegisteredPoolIds(inner?.pools?.id);
  if (registered.length !== Number(inner?.pools?.size)) {
    throw new Error(
      `read ${registered.length} Registry pool entries, but its Bag holds ` +
        `${inner?.pools?.size}`,
    );
  }
  const found = new Set(pools.map((pool) => normalizeSuiAddress(pool.id)));
  const missing = registered.filter((id) => !found.has(id));
  if (missing.length > 0) {
    throw new Error(
      `the pool enumeration misses ${missing.length} registered pool(s): ` +
        missing.join(", "),
    );
  }
  console.log(
    `updating allowed versions on ${pools.length} pools ` +
      `(all ${registered.length} registered pools among them)`,
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

  await writeSimulatedTx(tx, txFilePath);
  console.log(
    `after this executes, the registry and every pool above allow ` +
      `{${[...allowed, version].sort((a, b) => a - b).join(", ")}}`,
  );
  console.log(
    `REQUIRED after execution: a pool created before this transaction ` +
      `executes is not in it and does not allow ${version}. Run ` +
      `pool::update_pool_allowed_versions on every such pool, then check that ` +
      `every pool allows ${version}.`,
  );
};

mainPackageUpgradeEnableVersion().catch((error: any) => {
  console.error("Error during protocol upgrade:", error.message);
  console.error("stderr:", error.stderr?.toString());
  console.error("stdout:", error.stdout?.toString());
  process.exit(1);
});
