// Strategy registry. A strategy is selected by name via the STRATEGY env (the runner) and by
// the campaign command (per-localnet). Add a new strategy by dropping a module here.
import { type Strategy } from "../strategy.js";
import fuzz from "./fuzz.js";
import liqChurn from "./liqChurn.js";
import mintOnly from "./mintOnly.js";
import mixedChurn from "./mixedChurn.js";
import navStress from "./navStress.js";

export const STRATEGIES: Record<string, Strategy> = {
  [fuzz.name]: fuzz,
  [mintOnly.name]: mintOnly,
  [mixedChurn.name]: mixedChurn,
  [liqChurn.name]: liqChurn,
  [navStress.name]: navStress,
};

export function getStrategy(name: string): Strategy {
  const s = STRATEGIES[name];
  if (!s) throw new Error(`unknown strategy '${name}' (have: ${Object.keys(STRATEGIES).join(", ")})`);
  return s;
}
