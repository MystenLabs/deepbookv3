# Predict Package - Progress Tracker

Branch: `at/predict`

## Architecture Overview

Binary options prediction market protocol built on DeepBook. Users buy UP/DOWN positions on underlying assets (BTC, ETH) at specific strikes and expiries. A vault takes the opposite side of every trade. Prices are derived from oracle data (Block Scholes volatility surface).

**Flow:** Registry (admin) -> Oracle (price data) -> Predict (orchestrator) -> Vault (state) + Pricing (calculations) + PredictManager (user positions)

## Module Status

### Core (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `registry.move` | Done | init, AdminCap, create_predict, create_oracle, create_oracle_cap, pause flags |
| `predict.move` | Done | Orchestrator: mint, redeem, mint_collateralized, redeem_collateralized, settle, supply, withdraw, mark_to_market, risk checks |
| `vault/vault.move` | Done | State machine: execute_mint/redeem, collateralized mint/redeem, exposure tracking (max/min liability), unrealized liability/assets, finalize_settlement |
| `vault/supply_manager.move` | Done | LP share accounting: supply (shares minted), withdraw (shares burned), lockup enforcement, vault_value = balance + unrealized_assets - unrealized_liability |
| `predict_manager.move` | Done | User-side: wraps BalanceManager, tracks positions (free/locked), collateral lock/release |
| `market_manager/market_key.move` | Done | Positional struct: (oracle_id, expiry, strike, direction), UP/DOWN helpers, opposite(), up_down_pair() |
| `market_manager/market_manager.move` | Done | VecSet of enabled MarketKeys, enable/disable/assert_enabled |
| `config/risk_config.move` | Done | max_total_exposure_pct (80%), max_per_market_exposure_pct (20%) |
| `config/lp_config.move` | Done | lockup_period_ms (24h default) |
| `helper/constants.move` | Done | FLOAT_SCALING (1e9), USDC_UNIT (1e6), defaults, time constants |

### Oracle (Done - Two Implementations)
| Module | Status | Notes |
|--------|--------|-------|
| `oracle.move` | Done | Per-strike IV oracle: VecMap<strike, iv>, spot, rfr. Block Scholes pushes pre-computed IVs per strike. Settlement freezing on expiry. |
| `oracle_block_scholes.move` | Done | SVI parametric oracle: stores SVI params (a,b,rho,m,sigma) + spot/forward prices. `compute_iv()` implements SVI formula. `get_pricing_data()` returns (forward, iv, rfr, tte_ms). |

### Pricing (Partial)
| Module | Status | Notes |
|--------|--------|-------|
| `pricing/pricing.move` | Done | get_quote (bid/ask), get_mint_cost, get_redeem_payout all work. `calculate_binary_price()` implements Black-Scholes digital option formula: e^(-rT) * N(±d2) using forward price. Dynamic spread TODO. |

### Collateral (Skeleton)
| Module | Status | Notes |
|--------|--------|-------|
| `collateral/collateral.move` | Skeleton | Empty - just comments describing CollateralManager. Logic moved to PredictManager. |
| `collateral/record.move` | Skeleton | Empty - just comments describing CollateralRecord lifecycle. |

## Key TODOs

### P0 - Blocking
All P0 items complete.

### P1 - Important
- [ ] **Dynamic spread** (`pricing.move:67`): spread should adjust based on vault net exposure (incentivize balance)
- [ ] **Tests**: No test files exist yet

### P2 - Nice to Have
- [ ] **Clean up collateral modules**: `collateral.move` and `record.move` are empty skeletons. Logic lives in PredictManager now - decide if these files should be removed or filled in.
- [ ] **Events**: Most modules don't emit events beyond oracle. Add events for mints, redeems, settlements, supply/withdraw.
- [ ] **Admin functions**: No admin setters exposed through predict.move for risk_config, lp_config, pricing params
- [ ] **Registry oracle_block_scholes integration**: Registry only creates `Oracle`, not `OracleSVI`
- [ ] **Pause enforcement**: trading_paused/withdrawals_paused exist in Registry but aren't checked in predict.move

## Design Decisions Made
- Vault is the counterparty to all trades (short every position)
- Quantities are in USDC units (1_000_000 = 1 contract = $1)
- Prices use FLOAT_SCALING (1e9): 500_000_000 = 50%
- Two oracle designs: per-strike IV (simpler, used now) and SVI parametric (future, more flexible)
- Collateralized minting lives in PredictManager (free/locked positions), not a separate CollateralManager
- Mark-to-market runs after every trade on both UP and DOWN for the strike
- Risk limits: 80% max total exposure, 20% max per market (as % of vault balance)
- LP shares use vault_value = balance + unrealized_assets - unrealized_liability

## Session Log

### Session: 2026-02-09
- Reviewed full codebase state after ~40 commits
- Created this progress tracker
- Package builds successfully (`sui move build`)
- No tests written yet

### Session: 2026-02-11
- Implemented `get_pricing_data()` in oracle_block_scholes.move — returns (forward, iv, rfr, tte_ms)
- Updated pricing formula to use forward price instead of spot (matches Python demo: `ln(F/K)` not `ln(S/K)`)
- Implemented `calculate_binary_price()` — full Black-Scholes digital option: `e^(-rT) * N(±d2)`
- Fixed post-settlement claim flow: `redeem` now skips staleness check when oracle is settled
