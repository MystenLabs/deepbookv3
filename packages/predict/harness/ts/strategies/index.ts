// Strategy registry. A strategy is selected by name via the STRATEGY env (the runner) and by
// the campaign command (per-localnet). Add a new strategy by dropping a module here.
import { type Strategy } from "../strategy.js";
import { createCapacityStrategy } from "./capacity.js";
import { createCleanupStrategy } from "./cleanupEconomics.js";
import fuzz from "./fuzz.js";
import mintOnly from "./mintOnly.js";
import mixedChurn from "./mixedChurn.js";

export const STRATEGIES: Record<string, Strategy> = {
  [fuzz.name]: fuzz,
  [mintOnly.name]: mintOnly,
  [mixedChurn.name]: mixedChurn,
};

// The capacity and cleanup profiles build their books with batched immediate mints
// (`submitMintBatch`), which delayed execution retired, so they are not registered. Their
// modules stay for the queued-flow redesign. Selecting one fails with this reason instead of
// running a strategy that can only fail.
const DISABLED_REASON =
  "disabled pending a queued-flow redesign: it builds its book with batched immediate mints, which delayed execution retired";
export const DISABLED_STRATEGIES: Record<string, string> = Object.fromEntries(
  [
    createCapacityStrategy("single"),
    createCapacityStrategy("pool"),
    createCapacityStrategy("tree"),
    createCleanupStrategy("survivor"),
  ].map((strategy) => [strategy.name, DISABLED_REASON]),
);

export function getStrategy(name: string): Strategy {
  const disabled = DISABLED_STRATEGIES[name];
  if (disabled) throw new Error(`strategy '${name}' is ${disabled}`);
  const s = STRATEGIES[name];
  if (!s) throw new Error(`unknown strategy '${name}' (have: ${Object.keys(STRATEGIES).join(", ")})`);
  return s;
}
