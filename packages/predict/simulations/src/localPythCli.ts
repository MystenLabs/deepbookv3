import { writeFileSync } from "node:fs";

import { createLocalBsSignerConfig } from "./localBlockScholes.js";
import { createLocalPythConfig } from "./localPyth.js";

const outputPath = process.argv[2];
if (!outputPath) {
  throw new Error("usage: tsx src/localPythCli.ts <output-json-path>");
}

// One per-instance signer config file: the local Pyth guardian/signer keys plus
// the local Block Scholes signer key (registered via `registry::set_signer`).
writeFileSync(
  outputPath,
  JSON.stringify({ ...createLocalPythConfig(), ...createLocalBsSignerConfig() }, null, 2) + "\n",
);
