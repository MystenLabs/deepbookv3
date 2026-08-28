// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { writeFileSync } from "fs";
import { upgradeCapID } from "../config/constants.js";
import { serializeUnsignedUpgrade } from "./serializeUnsignedUpgrade.js";

const network = "mainnet";

// Active env of sui has to be the same with the env we're publishing to.
// if upgradeCap & gasObject is on mainnet, it has to be on mainnet.
// Github actions are always on mainnet.
const mainPackageUpgrade = async () => {
  const currentDir = process.cwd();
  const deepbookDir = `${currentDir}/../packages/deepbook`;
  const txFilePath = `${currentDir}/tx/tx-data.txt`;

  try {
    const output = serializeUnsignedUpgrade({
      cwd: deepbookDir,
      extraArgs: ["--upgrade-capability", upgradeCapID[network]],
    });

    writeFileSync(txFilePath, output);
    console.log(
      "Upgrade transaction successfully created and saved to tx-data.txt"
    );
  } catch (error: any) {
    console.error("Error during protocol upgrade:", error.message);
    console.error("stderr:", error.stderr?.toString());
    console.error("stdout:", error.stdout?.toString());
    console.error("Command:", error.cmd);
    process.exit(1); // Exit with an error code
  }
};

mainPackageUpgrade();
