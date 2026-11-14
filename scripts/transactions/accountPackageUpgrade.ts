// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { writeFileSync } from "fs";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
//
// No `--upgrade-capability` is passed: packages/account/Published.toml records
// the mainnet upgrade capability, so the CLI resolves it the same way predict_math
// does.
//
// Upgrade only. account links only the Sui framework and has no version gate, so
// there is nothing to enable. Predict, predict_orders and sessions link account
// through their own builds, so upgrade account and commit its publication record
// before building them.
const accountPackageUpgrade = async () => {
  const currentDir = process.cwd();
  const accountDir = `${currentDir}/../packages/account`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  try {
    const output = serializeUnsignedUpgrade({
      cwd: accountDir,
    });

    // Extract only the base64 transaction bytes (last non-empty line)
    const lines = output.trim().split("\n");
    const txBytes = lines[lines.length - 1].trim();

    writeFileSync(txFilePath, txBytes);
    console.log(
      "Account upgrade transaction successfully created and saved to tx-data.txt",
    );
  } catch (error: any) {
    console.error("Error during account package upgrade:", error.message);
    console.error("stderr:", error.stderr?.toString());
    console.error("stdout:", error.stdout?.toString());
    console.error("Command:", error.cmd);
    process.exit(1); // Exit with an error code
  }
};

accountPackageUpgrade();
