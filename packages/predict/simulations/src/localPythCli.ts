import { writeFileSync } from "node:fs";

import { createLocalPythConfig } from "./localPyth.js";

const outputPath = process.argv[2];
if (!outputPath) {
  throw new Error("usage: tsx src/localPythCli.ts <output-json-path>");
}

writeFileSync(outputPath, JSON.stringify(createLocalPythConfig(), null, 2) + "\n");
