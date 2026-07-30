import { createLocalBsSignerConfig } from "./localBlockScholes.js";
import { createLocalPythConfig } from "./localPyth.js";

// Python captures this one-shot bootstrap payload in memory. Private signer
// material is written only to the mode-0600 runtime environment.
process.stdout.write(
  JSON.stringify({ ...createLocalPythConfig(), ...createLocalBsSignerConfig() }) + "\n",
);
