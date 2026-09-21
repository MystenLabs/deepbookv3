// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { writeFileSync } from "fs";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
//
// No `--upgrade-capability` is passed: packages/sessions/Published.toml records the
// mainnet upgrade capability, so the CLI resolves it the same way margin, vault and
// predict do. The spot script passes one explicitly only because packages/deepbook
// predates that field.
//
// Sessions depends on `deepbook_predict` locally, so this builds against whatever
// packages/predict/Published.toml records as the mainnet Predict package. Upgrade
// Predict and commit its publication record before building this transaction, or the
// upgrade links against the superseded package.
const sessionsPackageUpgrade = async () => {
  const currentDir = process.cwd();
  const sessionsDir = `${currentDir}/../packages/sessions`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  try {
    const output = serializeUnsignedUpgrade({
      cwd: sessionsDir,
    });

    // Extract only the base64 transaction bytes (last non-empty line)
    const lines = output.trim().split("\n");
    const txBytes = lines[lines.length - 1].trim();

    writeFileSync(txFilePath, txBytes);
    console.log(
      "Sessions upgrade transaction successfully created and saved to tx-data.txt",
    );
  } catch (error: any) {
    console.error("Error during sessions package upgrade:", error.message);
    console.error("stderr:", error.stderr?.toString());
    console.error("stdout:", error.stdout?.toString());
    console.error("Command:", error.cmd);
    process.exit(1); // Exit with an error code
  }
};

sessionsPackageUpgrade();
