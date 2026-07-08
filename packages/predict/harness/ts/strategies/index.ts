// Strategy registry. A strategy is selected by name via the STRATEGY env (the runner) and by
// the campaign command (per-localnet). Add a new strategy by dropping a module here.
import { type Strategy } from "../strategy.js";
import batchMaxBook from "./batchMaxBook.js";
import batchMaxMarkets from "./batchMaxMarkets.js";
import cleanoutGas from "./cleanoutGas.js";
import cleanoutGasLiq from "./cleanoutGasLiq.js";
import fuzz from "./fuzz.js";
import liqChurn from "./liqChurn.js";
import mintBatch from "./mintBatch.js";
import mintOnly from "./mintOnly.js";
import mixedChurn from "./mixedChurn.js";
import navStress from "./navStress.js";
import navStressAtm from "./navStressAtm.js";
import navStressMulti from "./navStressMulti.js";

export const STRATEGIES: Record<string, Strategy> = {
  [fuzz.name]: fuzz,
  [mintOnly.name]: mintOnly,
  [mixedChurn.name]: mixedChurn,
  [liqChurn.name]: liqChurn,
  [navStress.name]: navStress,
  [navStressAtm.name]: navStressAtm,
  [navStressMulti.name]: navStressMulti,
  [mintBatch.name]: mintBatch,
  [batchMaxBook.name]: batchMaxBook,
  [batchMaxMarkets.name]: batchMaxMarkets,
  [cleanoutGas.name]: cleanoutGas,
  [cleanoutGasLiq.name]: cleanoutGasLiq,
};

export function getStrategy(name: string): Strategy {
  const s = STRATEGIES[name];
  if (!s) throw new Error(`unknown strategy '${name}' (have: ${Object.keys(STRATEGIES).join(", ")})`);
  return s;
}
