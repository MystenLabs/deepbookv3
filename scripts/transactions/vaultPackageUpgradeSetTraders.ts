// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { normalizeSuiAddress } from "@mysten/sui/utils";
import {
  liquidationAdminCapID,
  liquidationUpgradeCapID,
  liquidationVaultID,
  liquidationVaultTraders,
  marginUpgradeCapID,
  upgradeCapID,
} from "../config/constants.js";
import {
  assertSenderOwns,
  buildUpgradeTx,
  client,
  network,
  readJson,
  writeSimulatedTx,
} from "./upgradeAndEnableVersion.js";

// Upgrades margin_liquidation and sets the LiquidationVault's authorized traders
// in one transaction.
//
// An authorized trader can swap the vault's funds through any DeepBook pool with
// an output minimum it chooses, so every trader must be as well protected as the
// funds. The trader list is stored on the vault, not in the package, so changing
// it binds on every package version at once. This authorizes each address in
// liquidationVaultTraders that the vault lacks and deauthorizes every other one.
//
// The upgrade links the core and margin packages their Published.toml records
// name, so this refuses to build unless both are the newest on chain.

// The vault's current traders, from its AuthorizedTradersKey dynamic field.
const readVaultTraders = async (vaultId: string): Promise<string[]> => {
  const { dynamicFields } = await client.core.listDynamicFields({
    parentId: vaultId,
  });
  const field = dynamicFields.find((f: any) =>
    f.name.type.endsWith("::liquidation_vault::AuthorizedTradersKey"),
  );
  if (!field) return [];
  const contents: string[] = (await readJson(field.fieldId))?.value?.contents;
  if (!contents) throw new Error(`cannot read the trader list on ${vaultId}`);
  return contents.map((address) => normalizeSuiAddress(address));
};

const vaultPackageUpgradeSetTraders = async () => {
  const currentDir = process.cwd();
  const vaultDir = `${currentDir}/../packages/margin_liquidation`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  const vaultId = liquidationVaultID[network];
  const target = liquidationVaultTraders[network].map((address) =>
    normalizeSuiAddress(address),
  );
  const current = await readVaultTraders(vaultId);
  const toAuthorize = target.filter((address) => !current.includes(address));
  const toDeauthorize = current.filter((address) => !target.includes(address));
  console.log(`vault traders now: {${current.join(", ")}}`);
  console.log(`authorizing: {${toAuthorize.join(", ")}}`);
  console.log(`deauthorizing: {${toDeauthorize.join(", ")}}`);

  const { tx, currentPackage, dependencies } = await buildUpgradeTx(
    vaultDir,
    liquidationUpgradeCapID[network],
  );

  // Each UpgradeCap always points at the newest package it controls.
  for (const [name, capId, record] of [
    ["core", upgradeCapID[network], "packages/deepbook/Published.toml"],
    [
      "margin",
      marginUpgradeCapID[network],
      "packages/deepbook_margin/Published.toml",
    ],
  ]) {
    const latest = normalizeSuiAddress((await readJson(capId)).package);
    if (!dependencies.includes(latest)) {
      throw new Error(
        `this build does not link the newest ${name} package ${latest}. It ` +
          `links {${dependencies.join(", ")}}. Record the ${name} upgrade in ` +
          `${record} before upgrading margin_liquidation`,
      );
    }
    console.log(`links ${name} package ${latest}, the newest on chain`);
  }

  await assertSenderOwns(tx, {
    LiquidationUpgradeCap: liquidationUpgradeCapID[network],
    LiquidationAdminCap: liquidationAdminCapID[network],
  });

  for (const address of toAuthorize) {
    tx.moveCall({
      target: `${currentPackage}::liquidation_vault::authorize_trader`,
      arguments: [
        tx.object(vaultId),
        tx.object(liquidationAdminCapID[network]),
        tx.pure.address(address),
      ],
    });
  }
  for (const address of toDeauthorize) {
    tx.moveCall({
      target: `${currentPackage}::liquidation_vault::deauthorize_trader`,
      arguments: [
        tx.object(vaultId),
        tx.object(liquidationAdminCapID[network]),
        tx.pure.address(address),
      ],
    });
  }

  await writeSimulatedTx(tx, txFilePath);
  console.log(
    `after this executes, the vault's traders are {${target.join(", ")}}`,
  );
};

vaultPackageUpgradeSetTraders().catch((error: any) => {
  console.error("Error during vault package upgrade:", error.message);
  console.error("stderr:", error.stderr?.toString());
  console.error("stdout:", error.stdout?.toString());
  process.exit(1);
});
