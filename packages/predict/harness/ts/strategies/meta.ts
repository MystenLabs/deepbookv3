// Print each strategy's campaign-relevant config as JSON, so the Python campaign sets the
// keeper (cadence, funding) per localnet from the same source of truth as the runner.
//   { "<name>": { "tickMs", "maxOps", "fund" (DUSDC string), "cadence" }, ... }
import { STRATEGIES } from "./index.js";

const meta = Object.fromEntries(
  Object.values(STRATEGIES).map((s) => [s.name, { tickMs: s.tickMs, maxOps: s.maxOps, fund: s.fund.toString(), cadence: s.cadence }]),
);
console.log(JSON.stringify(meta));
