// Strategy registry. A strategy is selected by name via the STRATEGY env (the runner) and by
// the campaign command (per-localnet). Add a new strategy by dropping a module here.
import { type Strategy } from "../strategy.js";
import { createCapacityStrategy } from "./capacity.js";
import { createCleanupStrategy } from "./cleanupEconomics.js";
import { createLiqBudgetStrategy } from "./liqBudget.js";
import fuzz from "./fuzz.js";
import liqChurn from "./liqChurn.js";
import mintOnly from "./mintOnly.js";
import mixedChurn from "./mixedChurn.js";

const capacity = [
  createCapacityStrategy("single"),
  createCapacityStrategy("pool"),
  createCapacityStrategy("tree"),
];
const liqBudget = [createLiqBudgetStrategy("healthy"), createLiqBudgetStrategy("adverse")];
const cleanup = [
  createCleanupStrategy("survivor"),
  createCleanupStrategy("liquidated"),
  createCleanupStrategy("claim"),
];

export const STRATEGIES: Record<string, Strategy> = {
  [fuzz.name]: fuzz,
  [mintOnly.name]: mintOnly,
  [mixedChurn.name]: mixedChurn,
  [liqChurn.name]: liqChurn,
  ...Object.fromEntries(capacity.map((strategy) => [strategy.name, strategy])),
  ...Object.fromEntries(cleanup.map((strategy) => [strategy.name, strategy])),
  ...Object.fromEntries(liqBudget.map((strategy) => [strategy.name, strategy])),
};

export function getStrategy(name: string): Strategy {
  const s = STRATEGIES[name];
  if (!s) throw new Error(`unknown strategy '${name}' (have: ${Object.keys(STRATEGIES).join(", ")})`);
  return s;
}
