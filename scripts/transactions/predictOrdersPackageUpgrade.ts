// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { writeFileSync } from "fs";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
//
// No `--upgrade-capability` is passed: packages/predict_orders/Published.toml records
// the mainnet upgrade capability, so the CLI resolves it the same way margin, vault and
// predict do.
//
// Upgrade only. predict_orders depends on `deepbook_predict`, `deepbook_predict_math`
// and `propbook` locally, so this builds against the mainnet packages their
// Published.toml files record. Upgrade those and commit their publication records
// before building this transaction, or the upgrade links against superseded packages.
const predictOrdersPackageUpgrade = async () => {
  const currentDir = process.cwd();
  const predictOrdersDir = `${currentDir}/../packages/predict_orders`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  try {
    const output = serializeUnsignedUpgrade({
      cwd: predictOrdersDir,
    });

    // Extract only the base64 transaction bytes (last non-empty line)
    const lines = output.trim().split("\n");
    const txBytes = lines[lines.length - 1].trim();

    writeFileSync(txFilePath, txBytes);
    console.log(
      "Predict orders upgrade transaction successfully created and saved to tx-data.txt",
    );
  } catch (error: any) {
    console.error(
      "Error during predict orders package upgrade:",
      error.message,
    );
    console.error("stderr:", error.stderr?.toString());
    console.error("stdout:", error.stdout?.toString());
    console.error("Command:", error.cmd);
    process.exit(1); // Exit with an error code
  }
};

predictOrdersPackageUpgrade();
