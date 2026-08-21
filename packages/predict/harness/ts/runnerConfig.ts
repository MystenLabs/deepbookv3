// Environment-free runner defaults shared by metadata discovery and the trader process.
// Keep this module free of runtime/oracle imports: campaign reads strategy metadata before
// any localnet or `.env.localnet` exists.
export const DEFAULT_TRADER_GAS_BUDGET = 2_000_000_000;

export function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

export function definedEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
}

export function requiredNonnegativeInt(name: string): number {
  const raw = requiredEnv(name);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

/** Parse a non-negative bigint env knob, naming the variable on a bad value.
 *
 * `BigInt(process.env.X || "d")` throws a bare SyntaxError at module load, which kills the keeper
 * before it can write any trace — surfacing as `no-keeper-trace` rather than as the typo it is. */
export function bigintEnv(name: string, fallback: bigint): bigint {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = raw.trim();
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be a non-negative integer, got "${raw}"`);
  }
  return BigInt(value);
}

/** Parse a `0`/`1` env flag, defaulting to off.
 *
 * Validated rather than truthiness-tested for the reason `bigintEnv` gives: a
 * launcher that passes `"false"` or `"off"` would otherwise silently enable the
 * feature it meant to disable. */
export function flagEnv(name: string): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return false;
  const value = raw.trim();
  if (value !== "0" && value !== "1") {
    throw new Error(`${name} must be "0" or "1", got "${raw}"`);
  }
  return value === "1";
}

export interface BudgetRung {
  atMs: number;
  budget: bigint;
}

/** Parse a `TRADE_LIQ_BUDGET_STAGES` ladder: "<elapsedSeconds>:<budget>,…", ordered by time.
 *
 * The ambient liquidation pass costs `min(budget, active_leveraged_orders)`, so one run can measure
 * the whole budget range against a book built once, by stepping the on-chain config as it goes. An
 * empty spec yields no rungs, which leaves the contract default untouched.
 *
 * Shape is validated here and a bad entry throws at load: a typo would otherwise surface as a
 * `BigInt` TypeError an hour into the campaign it was meant to configure. The VALUE range stays the
 * contract's to enforce (`EInvalidTradeLiquidationBudget`) rather than being mirrored here. */
export function budgetLadder(spec: string): BudgetRung[] {
  return spec
    .split(",")
    .filter(Boolean)
    .map((entry) => {
      const match = /^(\d+):(\d+)$/.exec(entry.trim());
      if (!match) {
        throw new Error(`invalid TRADE_LIQ_BUDGET_STAGES entry: ${entry} (want "<elapsedSeconds>:<budget>")`);
      }
      return { atMs: Number(match[1]) * 1000, budget: BigInt(match[2]) };
    })
    .sort((left, right) => left.atMs - right.atMs);
}

export function gridExpiries(spec: string, nowMs = Date.now()): number[] {
  const expiries = spec.split(",").flatMap((part) => {
    const match = /^([1-9]\d*):([1-9]\d*)$/.exec(part);
    if (!match) throw new Error(`invalid GRID_SPEC entry: ${part}`);
    const period = Number(match[1]);
    const count = Number(match[2]);
    if (!Number.isSafeInteger(period) || !Number.isSafeInteger(count)) {
      throw new Error(`GRID_SPEC entry exceeds safe integer range: ${part}`);
    }
    const base = Math.floor(nowMs / period) * period;
    return Array.from({ length: count }, (_, i) => base + (i + 1) * period);
  });
  return [...new Set(expiries)];
}
