// Testnet-aligned Predict config (from an on-chain audit of testnet, 2026-06-29:
// deployment.testnet.json @ predict-testnet-6-24 + live ProtocolConfig/Registry RPC).
//
// The harness uses contract defaults. Cadence configs have NO default
// (register_underlying seeds them disabled) and MUST be set per id. All money
// values are DUSDC-raw (1e6); ticks are raw price units.
import type { MarketParams } from "./resolver.js";

export interface CadenceConfig {
  tickSize: bigint; // raw price unit ($0.01 = 10_000_000)
  admissionTickSize: bigint; // raw price unit ($1 = 1_000_000_000); admission/tick = 100
  maxExpiryAllocation: bigint; // DUSDC
  initialExpiryCash: bigint; // DUSDC (>= expiry_cash_floor 10k, <= maxExpiryAllocation)
  windowSize: bigint; // number of cadence periods in the rolling future horizon
}

// Fixed protocol cadence periods. The keeper mirrors these when deciding
// whether the contract can admit another market inside a cadence horizon.
export const CADENCE_PERIOD_MS: Record<number, number> = {
  0: 60_000,
  1: 300_000,
  2: 3_600_000,
  3: 86_400_000,
  4: 604_800_000,
  5: 2_592_000_000,
};

// Per cadence id: 0=1m, 1=5m, 2=1h. 3/4/5 (1d/7d/30d) are disabled on testnet.
// Allocation caps are raised ~10x above the testnet values (50k/10k, 250k/50k) so capacity stress
// runs measure the FLUSH GAS wall, not the capital wall: at the 5,000-order per-market cap the
// reserve demand (~$70k+) exceeded the old 1m/5m 50k allocation and the pool-total run OOG'd
// entangled with expiry_cash::EInsufficientCash (stress/capacity-and-gas-findings.md, C-1 follow-up).
// Worst-case total allocation (9 live markets) stays under BOOTSTRAP_SUPPLY.
export const CADENCES: Record<number, CadenceConfig> = {
  0: { tickSize: 10_000_000n, admissionTickSize: 1_000_000_000n, maxExpiryAllocation: 500_000_000_000n, initialExpiryCash: 100_000_000_000n, windowSize: 3n },
  1: { tickSize: 10_000_000n, admissionTickSize: 1_000_000_000n, maxExpiryAllocation: 500_000_000_000n, initialExpiryCash: 100_000_000_000n, windowSize: 3n },
  2: { tickSize: 10_000_000n, admissionTickSize: 1_000_000_000n, maxExpiryAllocation: 1_000_000_000_000n, initialExpiryCash: 200_000_000_000n, windowSize: 3n },
};


// Genesis bootstrap supply: 10M DUSDC (lock_capital mints min_bootstrap_liquidity itself).
export const BOOTSTRAP_SUPPLY = 10_000_000_000_000n;

// Resolver market params — all snapshotted from the contract defaults the market gets.
// tickSize / admissionTickSize are in USD (raw / 1e9).
export const RESOLVER_MARKET: MarketParams = {
  tickSize: 0.01,
  admissionTickSize: 1,
  minEntryProbability: 0.01,
  maxEntryProbability: 0.99,
  lotSize: 10_000, // constants::position_lot_size
};
