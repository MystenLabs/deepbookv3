// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { normalizeSuiAddress } from "@mysten/sui/utils";
import {
  marginAdminCapID,
  marginRegistryID,
  marginUpgradeCapID,
  upgradeCapID,
} from "../config/constants.js";
import {
  assertSenderOwns,
  buildUpgradeTx,
  network,
  readAllowedVersions,
  readJson,
  readVersionConstant,
  readVersionedInner,
  writeSimulatedTx,
} from "./upgradeAndEnableVersion.js";

// Upgrades DeepBook margin and enables the new package's version in one
// transaction.
//
// Every gated margin entrypoint asserts that margin_constants::MARGIN_VERSION is
// in the MarginRegistry's allowed set, so an upgrade alone lands unusable. After
// the upgrade commands this appends margin_registry::enable_version for the new
// MARGIN_VERSION. Margin pools and managers read the MarginRegistry's set rather
// than caching it, so there is no sweep.
//
// Margin calls core through the core package it links, which the core
// Published.toml record decides. A margin package linked to an older core stops
// working when that core version is disabled, so this refuses to build unless
// margin links the newest core package on chain.

const marginPackageUpgradeEnableVersion = async () => {
  const currentDir = process.cwd();
  const marginDir = `${currentDir}/../packages/deepbook_margin`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  const version = readVersionConstant(
    `${marginDir}/sources/helper/margin_constants.move`,
    "MARGIN_VERSION",
  );
  console.log(`enabling version ${version} (MARGIN_VERSION in this build)`);

  const inner = await readVersionedInner(marginRegistryID[network]);
  const allowed = readAllowedVersions(inner, version, "MARGIN_VERSION");

  const { tx, currentPackage, dependencies } = await buildUpgradeTx(
    marginDir,
    marginUpgradeCapID[network],
  );

  // The core UpgradeCap always points at the newest core package.
  const latestCore = normalizeSuiAddress(
    (await readJson(upgradeCapID[network])).package,
  );
  if (!dependencies.includes(latestCore)) {
    throw new Error(
      `this build does not link the newest core package ${latestCore}. It ` +
        `links {${dependencies.join(", ")}}. Record the core upgrade in ` +
        `packages/deepbook/Published.toml before upgrading margin`,
    );
  }
  console.log(`links core package ${latestCore}, the newest on chain`);

  await assertSenderOwns(tx, {
    MarginUpgradeCap: marginUpgradeCapID[network],
    MarginAdminCap: marginAdminCapID[network],
  });

  tx.moveCall({
    target: `${currentPackage}::margin_registry::enable_version`,
    arguments: [
      tx.object(marginRegistryID[network]),
      tx.pure.u64(version),
      tx.object(marginAdminCapID[network]),
    ],
  });

  await writeSimulatedTx(tx, txFilePath);
  console.log(
    `after this executes, the MarginRegistry allows ` +
      `{${[...allowed, version].sort((a, b) => a - b).join(", ")}}`,
  );
};

marginPackageUpgradeEnableVersion().catch((error: any) => {
  console.error("Error during margin package upgrade:", error.message);
  console.error("stderr:", error.stderr?.toString());
  console.error("stdout:", error.stdout?.toString());
  process.exit(1);
});
