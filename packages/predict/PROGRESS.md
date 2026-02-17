# Predict Package - Progress Tracker

Branch: `at/predict`

## Architecture Overview

Binary options prediction market protocol built on DeepBook. Users buy UP/DOWN positions on underlying assets (BTC, ETH) at specific strikes and expiries. A vault takes the opposite side of every trade. Prices are derived from oracle data (Block Scholes volatility surface).

**Flow:** Registry (admin) -> Oracle (price data) -> Predict (orchestrator + pricing logic) -> Vault (state) + PredictManager (user positions)

## Module Status

### Core (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `registry.move` | Done | init, AdminCap, create_predict, create_oracle, create_oracle_cap, enable_market, pause setters, config setters (lockup, spread, skew, exposure limits) |
| `predict.move` | Done | Orchestrator + pricing: create_manager, mint, redeem, mint/redeem_collateralized, settle, supply, withdraw, get_quote, mark_to_market, risk checks, pause enforcement, config forwarders |
| `vault/vault.move` | Done | State machine: execute_mint/redeem, collateralized mint/redeem, exposure tracking (max/min liability), unrealized liability/assets, assert_exposure (risk checks), vault_value helper |
| `vault/supply_manager.move` | Done | LP share accounting: supply (shares minted), withdraw (shares burned), lockup enforcement, vault_value param, share_ratio helper |
| `predict_manager.move` | Done | User-side: wraps BalanceManager (deposit/withdraw caps), tracks positions (free/locked), collateral lock/release |
| `market_manager/market_key.move` | Done | Positional struct: (oracle_id, expiry, strike, direction), UP/DOWN helpers, opposite(), up_down_pair(), assert_matches_oracle() |
| `market_manager/market_manager.move` | Done | VecSet of enabled MarketKeys, enable/disable/assert_enabled |
| `config/pricing_config.move` | Done | base_spread (1%), max_skew_multiplier (1x) |
| `config/risk_config.move` | Done | max_total_exposure_pct (80%), max_per_market_exposure_pct (20%) |
| `config/lp_config.move` | Done | lockup_period_ms (24h default) |
| `helper/constants.move` | Done | `public macro fun`: FLOAT_SCALING (1e9), config defaults, ms_per_year, staleness_threshold_ms |
| `helper/math.move` | Done | ln, exp, normal_cdf, signed arithmetic (add/sub/mul) |

### Oracle (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `oracle.move` | Done | SVI parametric oracle: stores SVI params (a,b,rho,m,sigma) + spot/forward prices. Single `get_binary_price()` inlines SVI total variance + Black-Scholes d2 in one pass (no intermediate IV computation — time cancels out of d2). |

## Key TODOs

### P0 - Blocking
All P0 items complete.

### P1 - Important
- [x] **Dynamic spread**: spread adjusts based on vault net exposure. Widens on heavy side (0x-2x base_spread), tightens on light side. Configurable via `max_skew_multiplier`.
- [x] **Admin functions**: All config setters wired through registry.move (lockup, spread, skew, exposure limits, enable_market)
- [x] **PredictManager creation**: `predict::create_manager()` public function added
- [ ] **Tests**: Oracle pricing tests added (`tests/oracle_tests.move`). Need tests for mint/redeem flows, vault, supply_manager.

### P2 - Nice to Have
- [ ] **Events**: Most modules don't emit events beyond oracle. Add events for mints, redeems, settlements, supply/withdraw.
- [x] **Pause enforcement**: trading_paused/withdrawals_paused in Predict struct, checked in mint/mint_collateralized/withdraw. Redeems always allowed.

## Design Decisions Made
- Vault is the counterparty to all trades (short every position)
- Quantities are in USDC units (1_000_000 = 1 contract = $1)
- Prices use FLOAT_SCALING (1e9): 500_000_000 = 50%
- Oracle owns the pricing math (`get_binary_price`), predict.move handles spread/cost/payout
- Config structs (PricingConfig, RiskConfig, LPConfig) are pure data in `config/` with getters + `public(package)` setters
- Pricing logic (get_quote, spread calculation) lives in predict.move as private functions
- Collateralized minting lives in PredictManager (free/locked positions), not a separate CollateralManager
- Mark-to-market runs after every trade on both UP and DOWN for the strike
- Risk limits: 80% max total exposure, 20% max per market (as % of vault balance)
- LP shares use vault_value = balance + unrealized_assets - unrealized_liability
- Pause state lives in `Predict` (not `Registry`) to avoid circular dependency (registry → predict)
- Pause blocks mints only, not redeems — users can always exit positions

## Established Patterns
- **Section ordering**: Errors → Structs → Public Functions → Public-Package Functions → Private Functions
- **Config pattern**: pure data struct (`has store`) in `config/` with public getters, `public(package)` setters and `new()`
- **Constants pattern**: `public macro fun` (no `const` + wrapper functions)
- **Constructor**: `public(package) fun new()` for internal structs
- **Getters**: named after field directly (e.g., `balance()`, `max_liability()`)
- **Error naming**: `EPascalCase` with sequential numbering starting at 0
- **Import aliasing**: `deepbook::math` as `math` everywhere; `deepbook_predict::math` as `predict_math` when both needed
- **Copyright header**: every file starts with `// Copyright (c) Mysten Labs, Inc.` + `// SPDX-License-Identifier: Apache-2.0`

## Session Log

### Session: 2026-02-09
- Reviewed full codebase state after ~40 commits
- Created this progress tracker
- Package builds successfully (`sui move build`)
- No tests written yet

### Session: 2026-02-11 (earlier)
- Implemented `get_pricing_data()` in oracle_block_scholes.move — returns (forward, iv, rfr, tte_ms)
- Updated pricing formula to use forward price instead of spot (matches Python demo: `ln(F/K)` not `ln(S/K)`)
- Implemented `calculate_binary_price()` — full Black-Scholes digital option: `e^(-rT) * N(±d2)`
- Fixed post-settlement claim flow: `redeem` now skips staleness check when oracle is settled

### Session: 2026-02-11 (mid)
- Implemented dynamic spread in `pricing.move`: spread adjusts based on vault exposure imbalance (0x-2x range)
- Added `max_skew_multiplier` config to `Pricing` struct (default 1x) and `constants.move`
- Moved `calculate_binary_price` from `pricing.move` to `oracle_block_scholes.move` as `get_binary_price()` — oracle is now the single source of truth for fair price

### Session: 2026-02-11 (latest)
- **Codebase cleanup**: standardized patterns across all modules
- Deleted empty `collateral/collateral.move` and `collateral/record.move` skeletons
- Standardized section ordering to Errors → Structs → Public → Public-Package → Private (fixed predict.move)
- Added copyright header and doc comment to `math.move`
- Removed dead `DIRECTION_UP/DOWN` constants from `constants.move` (only used in `market_key.move`)
- Consolidated oracle_block_scholes.move sections into standard Public → Public-Package layout
- Fixed import aliasing: `deepbook::math` as `math`, `deepbook_predict::math` as `predict_math`
- Extracted `PricingConfig` to `config/pricing_config.move` (pure data + getters + setters, matches RiskConfig/LPConfig pattern)
- Moved pricing logic (get_quote, spread calc) from `pricing/pricing.move` into `predict.move` as private functions
- Deleted `pricing/pricing.move` and `pricing/` directory
- Documented established patterns in PROGRESS.md

### Session: 2026-02-11 (pause enforcement)
- Implemented pause enforcement: `trading_paused` blocks `mint` and `mint_collateralized`, `withdrawals_paused` blocks `withdraw`
- Redeems (`redeem`, `redeem_collateralized`) and `settle` always allowed — users can exit even when paused
- Pause state lives in `Predict` struct (not `Registry`) to avoid circular dependency
- Admin setters in `registry.move` (`set_trading_paused`, `set_withdrawals_paused`) call through to predict's `public(package)` setters
- Fixed pre-existing mutable borrow conflict in `supply_manager.move` (moved `share_ratio()` call before `&mut self.supplies` borrow)

### Session: 2026-02-11 (audit + fixes)
- **Full codebase audit**: read all 12 source files, identified bugs, dead code, and missing wiring
- **Fixed `compute_iv` bug #1**: `rho_negative` was ignored in SVI formula — now uses `mul_signed_u64` for correct signed `rho * (k-m)` product
- **Fixed `compute_iv` bug #2**: time-to-expiry divided by ms_per_day instead of ms_per_year — IV was off by sqrt(365). Now uses `constants::ms_per_year!()`
- **Wired admin config setters**: added `public(package)` forwarders in predict.move + public admin functions in registry.move for: `enable_market`, `set_lockup_period`, `set_base_spread`, `set_max_skew_multiplier`, `set_max_total_exposure_pct`, `set_max_per_market_exposure_pct`
- **Added `create_manager`**: public function in predict.move so users can create their own PredictManager
- **Removed dead code**: 9 unused constants (usdc_unit, bps_scaling, staleness, grace_period, max_strikes, ms_per_second/minute/hour/day), unused `trade_cap` field + TradeCap import from PredictManager

### Session: 2026-02-11 (refactor)
- **Removed duplicate logic and improved encapsulation across all modules:**
  1. Removed redundant collateral pair asserts in `mint_collateralized` (oracle transitivity)
  2. Extracted `assert_matches_oracle()` onto `MarketKey` — replaced 10 lines of asserts across 4 functions in predict.move
  3. Extracted `apply_exposure_delta()` in vault.move — centralized max/min liability delta math
  4. Extracted `share_ratio()` in supply_manager.move — deduplicated vault_value/share calculation
  5. Internalized `pair_position` into `get_quote` — removed boilerplate from all callers, simplified `update_position_mtm` signature
  6. `market_liability` and `finalize_settlement` now delegate to `exposure()` — removed reimplemented max/min logic
  7. Simplified SupplyManager API — takes single `vault_value` param instead of 3 decomposed vault internals; added `vault_value()` helper to vault
  8. Moved risk check into vault as `assert_exposure()` — vault owns its own risk validation, predict.move just passes thresholds
  9. Converted all constants from `const` + wrapper functions to `public macro fun` — updated 8 call sites across 5 files

### Session: 2026-02-11 (simplification review)
- Reviewed 6 proposed simplifications, applied 3:
  1. **MarketKey cleanup**: simplified `opposite()` to use `new()`, simplified `up_down_pair()` to use `up()`/`down()` directly, removed unused `direction()` getter
  2. **Oracle dead code**: removed unused `assert_active()` and `EOracleNotActive` error constant
  3. **Renamed `PositionData`** in predict_manager.move to `UserPosition` — resolved name collision with vault's `PositionData`
- Skipped 3 proposed changes:
  - Config module merge: separation is meaningful (LP/pricing/risk are distinct concerns), keeps struct layout stable
  - Predict.move forwarder removal: forwarders provide proper encapsulation of Predict internals
  - ~~Inline `get_pricing_data`~~: done in 2026-02-17 session (total variance cancellation made it clearly better)

### Session: 2026-02-11 (deep review)
- **Thorough review of all 13 source files** — traced flows, verified invariants, identified bugs
- **Fixed `finalize_settlement` idempotency bug**: calling `settle()` twice applied the same liability delta repeatedly, corrupting `max_liability`/`min_liability`. Removed `finalize_settlement` entirely — `settle()` now only calls `mark_to_market` (naturally idempotent). Liability headroom releases as users redeem.
- **Analyzed and dismissed 3 issues as non-problems:**
  - `vault_value` underflow: unreachable with current parameters (80% exposure cap keeps `unrealized_liability < balance`)
  - Missing ownership check on `redeem`: `deposit()` catches it atomically; worst case (zero-payout skip) only burns worthless positions
  - Oracle IV units: already fixed in earlier session (`ms_per_year` confirmed)
- **Remaining issues documented** (not yet addressed):
  - P1: No events emitted (skipped for now)
  - P2: Unused `grace_period_ms` / `max_strikes_quantity` constants (never enforced)
  - P2: Spread discontinuity at zero positions (doubles on first trade)
  - P3: `VecSet` for markets is O(n) (could use `Table`)
  - P3: Registry `oracle_ids` is write-only (dead storage)

### Session: 2026-02-17
- **Renamed `oracle_block_scholes.move` → `oracle.move`**: updated module declaration and all 6 import sites across 4 files
- **Replaced magic numbers with named constants**: all `1_000_000_000` → `constants::float_scaling!()` in math.move (18 occurrences) and oracle.move (2 occurrences). Added `staleness_threshold_ms!()` constant for the 30s oracle staleness check.
- **Simplified pricing math**: inlined `compute_iv` + `get_pricing_data` + `get_binary_price` into a single `get_binary_price`. Key insight: SVI gives total_variance directly, and `iv²*t = total_var`, `iv*√t = √(total_var)`, so d2 = `(-k - total_var/2) / √(total_var)` — time cancels out of d2 entirely, IV is never computed. Saves 1 `ln`, 1 `sqrt`, several `mul`/`div` per call. Net -45 lines.
- **First test file**: `tests/oracle_tests.move` with 5 tests — UP+DOWN sum to discount factor invariant, directional correctness (OTM call/put), parameter variations (shifted m, positive rho), short expiry (1 day).
