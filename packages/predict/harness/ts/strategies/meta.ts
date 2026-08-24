// Print campaign config as JSON for the Python orchestrator, from the same source of truth as the
// runtime: per-strategy runner config (tickMs/maxOps/fund/gasBudget/requiresTimeout/inventoryImpactMaxRate) + the enabled cadence set (id + period + window)
// that every keeper runs and the oracle grid must cover.
//   { "strategies": { "<name>": { "tickMs", "maxOps", "fund", "gasBudget", "requiresTimeout", "inventoryImpactMaxRate" } }, "cadences": [ { "id", "windowSize", "periodMs" } ] }
import { CADENCES, CADENCE_PERIOD_MS } from "../predictConfig.js";
import { DEFAULT_TRADER_GAS_BUDGET } from "../runnerConfig.js";
import { STRATEGIES } from "./index.js";

const strategies = Object.fromEntries(
  Object.values(STRATEGIES).map((s) => [s.name, {
    tickMs: s.tickMs,
    maxOps: s.maxOps,
    fund: s.fund.toString(),
    gasBudget: s.gasBudget ?? DEFAULT_TRADER_GAS_BUDGET,
    requiresTimeout: s.maxOps === 0 && !s.done,
    inventoryImpactMaxRate: (s.inventoryImpactMaxRate ?? 0n).toString(),
  }]),
);
const cadences = Object.entries(CADENCES).map(([id, c]) => ({
  id: Number(id),
  windowSize: Number(c.windowSize),
  periodMs: CADENCE_PERIOD_MS[Number(id)],
}));
console.log(JSON.stringify({ strategies, cadences }));
