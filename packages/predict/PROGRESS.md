# Predict Package - Progress Tracker

Branch: `at/predict`

## Architecture Overview

Binary options prediction market protocol built on DeepBook. Users buy UP/DOWN positions on underlying assets (BTC, ETH) at specific strikes and expiries. A vault takes the opposite side of every trade. Prices are derived from oracle data (Block Scholes volatility surface).

**Flow:** Registry (admin) -> Oracle (price data) -> Predict (orchestrator + pricing logic) -> Vault (state) + PredictManager (user positions)

## Module Status

### Core (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `registry.move` | Done | init, AdminCap, create_predict, create_oracle, create_oracle_cap, pause flags |
| `predict.move` | Done | Orchestrator + pricing: mint, redeem, mint/redeem_collateralized, settle, supply, withdraw, get_quote, mark_to_market, risk checks |
| `vault/vault.move` | Done | State machine: execute_mint/redeem, collateralized mint/redeem, exposure tracking (max/min liability), unrealized liability/assets, finalize_settlement |
| `vault/supply_manager.move` | Done | LP share accounting: supply (shares minted), withdraw (shares burned), lockup enforcement, vault_value = balance + unrealized_assets - unrealized_liability |
| `predict_manager.move` | Done | User-side: wraps BalanceManager, tracks positions (free/locked), collateral lock/release |
| `market_manager/market_key.move` | Done | Positional struct: (oracle_id, expiry, strike, direction), UP/DOWN helpers, opposite(), up_down_pair() |
| `market_manager/market_manager.move` | Done | VecSet of enabled MarketKeys, enable/disable/assert_enabled |
| `config/pricing_config.move` | Done | base_spread (1%), max_skew_multiplier (1x) |
| `config/risk_config.move` | Done | max_total_exposure_pct (80%), max_per_market_exposure_pct (20%) |
| `config/lp_config.move` | Done | lockup_period_ms (24h default) |
| `helper/constants.move` | Done | FLOAT_SCALING (1e9), USDC_UNIT (1e6), defaults, time constants |
| `helper/math.move` | Done | ln, exp, normal_cdf, signed arithmetic (add/sub/mul) |

### Oracle (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `oracle_block_scholes.move` | Done | SVI parametric oracle: stores SVI params (a,b,rho,m,sigma) + spot/forward prices. `compute_iv()` implements SVI formula. `get_pricing_data()` returns (forward, iv, rfr, tte_ms). `get_binary_price()` computes full Black-Scholes digital option price. |

## Key TODOs

### P0 - Blocking
All P0 items complete.

### P1 - Important
- [x] **Dynamic spread**: spread adjusts based on vault net exposure. Widens on heavy side (0x-2x base_spread), tightens on light side. Configurable via `max_skew_multiplier`.
- [ ] **Tests**: No test files exist yet

### P2 - Nice to Have
- [ ] **Events**: Most modules don't emit events beyond oracle. Add events for mints, redeems, settlements, supply/withdraw.
- [ ] **Admin functions**: No admin setters exposed through predict.move for risk_config, lp_config, pricing_config params
- [ ] **Registry oracle_block_scholes integration**: Registry only creates `Oracle`, not `OracleSVI`
- [ ] **Pause enforcement**: trading_paused/withdrawals_paused exist in Registry but aren't checked in predict.move
- [ ] **PredictManager creation**: `predict_manager::new()` is `public(package)` but no public entry point exists for users to create one

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

## Established Patterns
- **Section ordering**: Errors → Structs → Public Functions → Public-Package Functions → Private Functions
- **Config pattern**: pure data struct (`has store`) in `config/` with public getters, `public(package)` setters and `new()`
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
