// Print campaign config as JSON for the Python orchestrator, from the same source of truth as the
// runtime: per-strategy runner config (tickMs/maxOps/fund/gasBudget/requiresTimeout) + the enabled cadence set (id + window)
// that every keeper runs and the oracle grid must cover.
//   { "strategies": { "<name>": { "tickMs", "maxOps", "fund", "gasBudget", "requiresTimeout" } }, "cadences": [ { "id", "windowSize" } ] }
import { CADENCES } from "../predictConfig.js";
import { DEFAULT_TRADER_GAS_BUDGET } from "../runnerConfig.js";
import { STRATEGIES } from "./index.js";

const strategies = Object.fromEntries(
  Object.values(STRATEGIES).map((s) => [s.name, {
    tickMs: s.tickMs,
    maxOps: s.maxOps,
    fund: s.fund.toString(),
    gasBudget: s.gasBudget ?? DEFAULT_TRADER_GAS_BUDGET,
    requiresTimeout: s.maxOps === 0 && !s.done,
  }]),
);
const cadences = Object.entries(CADENCES).map(([id, c]) => ({ id: Number(id), windowSize: Number(c.windowSize) }));
console.log(JSON.stringify({ strategies, cadences }));
