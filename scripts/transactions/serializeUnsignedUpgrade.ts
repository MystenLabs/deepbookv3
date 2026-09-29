// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execFileSync } from "child_process";

const SUI_OBJECT_ID = /^0x[0-9a-fA-F]{1,64}$/;

function requireGasObjectId(): string {
  const gasObjectId = process.env.GAS_OBJECT?.trim();
  if (!gasObjectId) {
    throw new Error("No gas object supplied for a mainnet transaction");
  }
  if (!SUI_OBJECT_ID.test(gasObjectId)) {
    throw new Error(
      `Invalid GAS_OBJECT: expected 0x followed by 1-64 hex characters, got ${JSON.stringify(gasObjectId)}`,
    );
  }
  return gasObjectId;
}

/** Run `sui client upgrade --serialize-unsigned-transaction` without a shell. */
export function serializeUnsignedUpgrade(options: {
  cwd: string;
  extraArgs?: string[];
}): string {
  const gasObjectId = requireGasObjectId();
  const sui = process.env.SUI_BINARY ?? "sui";
  return execFileSync(
    sui,
    [
      "client",
      "upgrade",
      ...(options.extraArgs ?? []),
      "--gas-budget",
      "2000000000",
      "--gas",
      gasObjectId,
      // Use gas-price of 1000 to avoid RGP increases between tx generation and execution
      "--gas-price",
      "1000",
      "--serialize-unsigned-transaction",
    ],
    {
      cwd: options.cwd,
      stdio: "pipe",
      encoding: "utf8",
    },
  );
}
