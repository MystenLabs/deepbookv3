// Strategy registry. A strategy is selected by name via the STRATEGY env (the runner) and by
// the campaign command (per-localnet). Add a new strategy by dropping a module here.
import { type Strategy } from "../strategy.js";
import { createCapacityStrategy } from "./capacity.js";
import { createCleanupStrategy } from "./cleanupEconomics.js";
import fuzz from "./fuzz.js";
import mintOnly from "./mintOnly.js";
import mixedChurn from "./mixedChurn.js";

const capacity = [
  createCapacityStrategy("single"),
  createCapacityStrategy("pool"),
  createCapacityStrategy("tree"),
  createCapacityStrategy("user-off"),
  createCapacityStrategy("user-on"),
];
const cleanup = [createCleanupStrategy("survivor")];

export const STRATEGIES: Record<string, Strategy> = {
  [fuzz.name]: fuzz,
  [mintOnly.name]: mintOnly,
  [mixedChurn.name]: mixedChurn,
  ...Object.fromEntries(capacity.map((strategy) => [strategy.name, strategy])),
  ...Object.fromEntries(cleanup.map((strategy) => [strategy.name, strategy])),
};

export function getStrategy(name: string): Strategy {
  const s = STRATEGIES[name];
  if (!s) throw new Error(`unknown strategy '${name}' (have: ${Object.keys(STRATEGIES).join(", ")})`);
  return s;
}
