// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Argument, Transaction } from "@mysten/sui/transactions";
import { fromBase64 } from "@mysten/sui/utils";
import {
  predictMathUpgradeCapID,
  propbookUpgradeCapID,
} from "../config/constants.js";
import {
  assertSenderOwns,
  buildUpgradeTx,
  network,
  writeSimulatedTx,
} from "./upgradeAndEnableVersion.js";

// Upgrades propbook and predict_math in one transaction.
//
// Neither package links the other, so neither build reads the other's
// Published.toml record and the two upgrades can share a transaction. Predict,
// predict_orders and sessions link both, and a transaction cannot link a package
// it upgrades, so build those only after this executes and both records are
// committed.
//
// Upgrade only. Propbook's permissionless migrate calls then move its stores and
// Pyth feed to the new version, which stops every write through the old package,
// so its writers have to move to the new package right after the migrate.

// Appends the authorize_upgrade, Upgrade and commit_upgrade commands that
// buildUpgradeTx checked in `source` to `tx`, with the same inputs.
const appendUpgrade = (tx: Transaction, source: Transaction): void => {
  const data = source.getData();
  const [authorize, upgrade, commit] = data.commands;

  const input = (arg: Argument) => {
    if (arg.$kind !== "Input") {
      throw new Error(`expected an input, got ${JSON.stringify(arg)}`);
    }
    return data.inputs[arg.Input];
  };
  const pure = (arg: Argument) => {
    const value = input(arg);
    if (value.$kind !== "Pure") {
      throw new Error(`expected a pure input, got ${JSON.stringify(value)}`);
    }
    return tx.pure(fromBase64(value.Pure.bytes));
  };
  const ownedObject = (arg: Argument) => {
    const value = input(arg);
    if (value.Object?.$kind !== "ImmOrOwnedObject") {
      throw new Error(`expected an owned object, got ${JSON.stringify(value)}`);
    }
    return tx.objectRef(value.Object.ImmOrOwnedObject);
  };

  const authorizeCall = authorize.MoveCall!;
  const commitCall = commit.MoveCall!;
  for (const [call, fn] of [
    [authorizeCall, "authorize_upgrade"],
    [commitCall, "commit_upgrade"],
  ] as const) {
    if (call.module !== "package" || call.function !== fn) {
      throw new Error(
        `expected package::${fn}, got ${call.module}::${call.function}`,
      );
    }
  }

  const [cap, policy, digest] = authorizeCall.arguments;
  const capArg = ownedObject(cap);
  const ticket = tx.moveCall({
    package: authorizeCall.package,
    module: authorizeCall.module,
    function: authorizeCall.function,
    arguments: [capArg, pure(policy), pure(digest)],
  });
  const receipt = tx.upgrade({
    modules: upgrade.Upgrade!.modules,
    dependencies: upgrade.Upgrade!.dependencies,
    package: upgrade.Upgrade!.package,
    ticket,
  });
  tx.moveCall({
    package: commitCall.package,
    module: commitCall.module,
    function: commitCall.function,
    arguments: [capArg, receipt],
  });
};

const propbookPredictMathPackageUpgrade = async () => {
  const currentDir = process.cwd();
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  const propbook = await buildUpgradeTx(
    `${currentDir}/../packages/propbook`,
    propbookUpgradeCapID[network],
  );
  const predictMath = await buildUpgradeTx(
    `${currentDir}/../packages/predict_math`,
    predictMathUpgradeCapID[network],
  );

  // A package that linked the other would link its current version, not the one
  // this transaction publishes, so it would have to be built after the other's
  // upgrade is recorded.
  for (const [name, build, other] of [
    ["propbook", propbook, predictMath],
    ["predict_math", predictMath, propbook],
  ] as const) {
    if (build.dependencies.includes(other.currentPackage)) {
      throw new Error(
        `${name} links ${other.currentPackage}, which this transaction ` +
          `upgrades. Upgrade them in separate transactions`,
      );
    }
  }

  const { tx } = propbook;
  appendUpgrade(tx, predictMath.tx);

  await assertSenderOwns(tx, {
    PropbookUpgradeCap: propbookUpgradeCapID[network],
    PredictMathUpgradeCap: predictMathUpgradeCapID[network],
  });

  await writeSimulatedTx(tx, txFilePath);
};

propbookPredictMathPackageUpgrade().catch((error: any) => {
  console.error(
    "Error during propbook and predict math package upgrade:",
    error.message,
  );
  console.error("stderr:", error.stderr?.toString());
  console.error("stdout:", error.stdout?.toString());
  process.exit(1);
});
