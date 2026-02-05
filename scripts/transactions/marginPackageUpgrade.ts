// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from "child_process";
import { writeFileSync } from "fs";

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const marginPackageUpgrade = async () => {
  const gasObjectId = process.env.GAS_OBJECT;

  // Enabling the gas Object check only on mainnet, to allow testnet multisig tests.
  if (!gasObjectId)
    throw new Error("No gas object supplied for a mainnet transaction");

  const currentDir = process.cwd();
  const marginDir = `${currentDir}/../packages/deepbook_margin`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;
  const upgradeCall = `sui client upgrade --gas-budget 2000000000 --gas ${gasObjectId} --serialize-unsigned-transaction`;

  try {
    // Execute the command with the specified working directory and capture the output
    const output = execSync(upgradeCall, {
      cwd: marginDir,
      stdio: "pipe",
    }).toString();

    // Extract only the base64 transaction bytes (last non-empty line)
    const lines = output.trim().split("\n");
    const txBytes = lines[lines.length - 1].trim();

    writeFileSync(txFilePath, txBytes);
    console.log(
      "Margin upgrade transaction successfully created and saved to tx-data.txt",
    );
  } catch (error: any) {
    console.error("Error during margin package upgrade:", error.message);
    console.error("stderr:", error.stderr?.toString());
    console.error("stdout:", error.stdout?.toString());
    console.error("Command:", error.cmd);
    process.exit(1); // Exit with an error code
  }
};

marginPackageUpgrade();
