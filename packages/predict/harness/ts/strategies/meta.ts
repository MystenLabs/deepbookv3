// Print campaign config as JSON for the Python orchestrator, from the same source of truth as the
// runtime: per-strategy runner config (tickMs/maxOps/fund) + the enabled cadence set (id + window)
// that every keeper runs and the oracle grid must cover.
//   { "strategies": { "<name>": { "tickMs", "maxOps", "fund" } }, "cadences": [ { "id", "windowSize" } ] }
import { CADENCES } from "../predictConfig.js";
import { STRATEGIES } from "./index.js";

const strategies = Object.fromEntries(
  Object.values(STRATEGIES).map((s) => [s.name, { tickMs: s.tickMs, maxOps: s.maxOps, fund: s.fund.toString() }]),
);
const cadences = Object.entries(CADENCES).map(([id, c]) => ({ id: Number(id), windowSize: Number(c.windowSize) }));
console.log(JSON.stringify({ strategies, cadences }));
