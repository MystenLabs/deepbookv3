# Predict Package - Progress Tracker

Branch: `at/predict`

## Architecture Overview

Binary options prediction market protocol built on DeepBook. Users buy UP/DOWN positions on underlying assets (BTC, ETH) at specific strikes and expiries. A vault takes the opposite side of every trade. Prices are derived from oracle data (Block Scholes volatility surface).

**Flow:** Registry (admin) -> Oracle (price data) -> Predict (orchestrator + pricing) -> Vault (aggregate state) + PredictManager (user positions)

## Module Status

### Core (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `registry.move` | Done | init, AdminCap, create_predict, create_oracle, create_oracle_cap, pause setters, config setters (lockup, spread, skew, exposure limit) |
| `predict.move` | Done | Orchestrator + pricing: create_manager, mint, redeem, mint/redeem_collateralized, get_quote (additive 3-component spread: base + skew + utilization), quantity-based inventory skew, risk checks, pause enforcement, config forwarders |
| `vault/vault.move` | Done | Aggregate state machine: execute_mint/redeem (is_up, quantity), collateralized mint/redeem, total_up_short/total_down_short/max_liability tracking, assert_total_exposure. Admin deposit/withdraw. |
| `predict_manager.move` | Done | User-side: wraps BalanceManager (deposit/withdraw caps), tracks positions (free/locked), collateral lock/release |
| `market_key/market_key.move` | Done | Positional struct: (oracle_id, expiry, strike, direction), UP/DOWN helpers, assert_matches_oracle() |
| `config/pricing_config.move` | Done | base_spread (1%), max_skew_multiplier (1x), utilization_multiplier (2x) |
| `config/risk_config.move` | Done | max_total_exposure_pct (80%) |
| `helper/constants.move` | Done | `public macro fun`: FLOAT_SCALING (1e9), config defaults, ms_per_year, staleness_threshold_ms |
| `helper/math.move` | Done | ln, exp, normal_cdf, signed arithmetic (add/sub/mul) |

### Oracle (Done)
| Module | Status | Notes |
|--------|--------|-------|
| `oracle.move` | Done | SVI parametric oracle: stores SVI params (a,b,rho,m,sigma) + spot/forward prices. Single `get_binary_price()` inlines SVI total variance + Black-Scholes d2 in one pass (no intermediate IV computation — time cancels out of d2). |

## Key TODOs

### P1 - Important
- [x] **Continuous strikes**: removed discrete market enablement system entirely. Any strike is valid if the oracle can price it.
- [x] **Dynamic spread**: spread adjusts based on vault net exposure. Widens on heavy side (0x-2x base_spread), tightens on light side. Configurable via `max_skew_multiplier`.
- [x] **Admin functions**: All config setters wired through registry.move (lockup, spread, skew, exposure limit)
- [x] **PredictManager creation**: `predict::create_manager()` public function added
- [x] **Tests**: All modules tested — oracle (5), vault (36), predict_manager (31), predict (26), market_key (18), math (47), cross-validation (14). 177 total.
- [x] **Cross-validation**: Move binary option pricing verified against Python/scipy reference implementation. Max deviation ~0.000007% (68 parts per billion).

### P2 - Nice to Have
- [x] **Events**: All modules now emit events — oracle (OracleActivated, OracleSettled, OraclePricesUpdated, OracleSVIUpdated), registry (PredictCreated, OracleCreated, AdminVaultBalanceChanged), predict (PositionMinted, PositionRedeemed, CollateralizedPositionMinted/Redeemed, TradingPauseUpdated, PricingConfigUpdated, RiskConfigUpdated), predict_manager (PredictManagerCreated). Indexer covers all 15.
- [x] **Pause enforcement**: trading_paused/withdrawals_paused in Predict struct, checked in mint/mint_collateralized/withdraw. Redeems always allowed.
- [ ] **Settled-side liability cleanup**: after settlement, losing-side liability never pays out but stays in max_liability until redeemed. A future function could zero out losing-side counts for settled oracles.

## Design Decisions Made
- Vault is the counterparty to all trades (short every position)
- Quantities are in USDC units (1_000_000 = 1 contract = $1)
- Prices use FLOAT_SCALING (1e9): 500_000_000 = 50%
- Oracle owns the pricing math (`get_binary_price`), predict.move handles spread/cost/payout
- Config structs (PricingConfig, RiskConfig) are pure data in `config/` with getters + `public(package)` setters
- Pricing logic (get_quote, spread calculation) lives in predict.move as private functions
- Collateralized minting lives in PredictManager (free/locked positions), not a separate CollateralManager
- **Aggregate-only vault**: no per-market Table, just total_up_short/total_down_short/total_collateralized counters. Skew pricing uses aggregate quantity imbalance.
- Risk limits: 80% max total exposure (as % of vault balance). No per-market limit (unnecessary with aggregate tracking).
- **No settle function**: oracle freezes settlement price at expiry. Redeems return 100%/0% for settled oracles. max_liability decreases naturally as positions are redeemed.
- Pause state lives in `Predict` (not `Registry`) to avoid circular dependency (registry → predict)
- Pause blocks mints only, not redeems — users can always exit positions
- **Continuous strikes**: any strike is valid if the oracle can price it. No admin market enablement required.

## Established Patterns
- **Section ordering**: Errors → Structs → Public Functions → Public-Package Functions → Private Functions
- **Config pattern**: pure data struct (`has store`) in `config/` with public getters, `public(package)` setters and `new()`
- **Constants pattern**: `public macro fun` (no `const` + wrapper functions)
- **Constructor**: `public(package) fun new()` for internal structs
- **Getters**: named after field directly (e.g., `balance()`, `max_liability()`)
- **Error naming**: `EPascalCase` with sequential numbering starting at 0
- **Import aliasing**: `deepbook::math` as `math` everywhere; `deepbook_predict::math` as `predict_math` when needed (e.g., oracle.move for signed arithmetic)
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
- Extracted `PricingConfig` to `config/pricing_config.move` (pure data + getters + setters, matches RiskConfig pattern)
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
  - Config module merge: separation is meaningful (pricing/risk are distinct concerns), keeps struct layout stable
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
  - P2: Spread discontinuity at zero positions (doubles on first trade)

### Session: 2026-02-17
- **Renamed `oracle_block_scholes.move` → `oracle.move`**: updated module declaration and all 6 import sites across 4 files
- **Replaced magic numbers with named constants**: all `1_000_000_000` → `constants::float_scaling!()` in math.move (18 occurrences) and oracle.move (2 occurrences). Added `staleness_threshold_ms!()` constant for the 30s oracle staleness check.
- **Simplified pricing math**: inlined `compute_iv` + `get_pricing_data` + `get_binary_price` into a single `get_binary_price`. Key insight: SVI gives total_variance directly, and `iv²*t = total_var`, `iv*√t = √(total_var)`, so d2 = `(-k - total_var/2) / √(total_var)` — time cancels out of d2 entirely, IV is never computed. Saves 1 `ln`, 1 `sqrt`, several `mul`/`div` per call. Net -45 lines.
- **First test file**: `tests/oracle_tests.move` with 5 tests — UP+DOWN sum to discount factor invariant, directional correctness (OTM call/put), parameter variations (shifted m, positive rho), short expiry (1 day).

### Session: 2026-02-18 (aggregate vault)
- **Vault refactored to aggregate-only tracking**: replaced `Table<MarketKey, PositionData>` with simple counters (`total_up_short`, `total_down_short`, `total_collateralized`, `max_liability`). Removed `PositionData` struct, per-market position tracking, `min_liability`, `unrealized_liability`/`unrealized_assets`, MTM functions.
- **Removed mark-to-market**: no more `mark_to_market`, `update_position_mtm`, `update_unrealized`, or `settle` function. LP share pricing uses conservative formula (`balance - max_liability`) instead.
- **Removed per-market risk limit**: deleted `max_per_market_exposure_pct` from `RiskConfig`, `assert_exposure` from vault (kept `assert_total_exposure`), `default_max_exposure_per_market_pct` macro from constants, `set_max_per_market_exposure_pct` from predict.move and registry.move.
- **Removed discrete market enablement**: deleted `market_manager.move` entirely, removed `Markets` field from `Predict` struct, removed `enable_market` from predict.move and registry.move.
- **Unified continuous entry points**: removed gated `mint`/`mint_collateralized` (which called `assert_enabled`), renamed `mint_continuous` → `mint` and `mint_collateralized_continuous` → `mint_collateralized`.
- **Cleanup**: removed dead `up_down_pair()` from market_key.move, renamed `sources/market_manager/` → `sources/market_key/` directory.

### Session: 2026-02-18 (skew analysis + spread refactor)
- **Spread refactored to additive 3-component formula**: `effective_spread = base_spread + skew_component + utilization_component`. Previously spread was multiplicative (`price × base_spread × multiplier`), now additive which gives more predictable behavior.
- **Inventory skew**: uses oracle-weighted expected liability per side. Computes `expected_liability = total_short × oracle.price(avg_strike, is_up)` using strike-weighted averages (`sum_up_strike_qty`, `sum_down_strike_qty`). Only penalizes the heavy side; light side gets no skew penalty.
- **Utilization spread**: `base_spread × util_multiplier × util²` applied to both sides. Gentle-then-aggressive curve as vault approaches capacity.
- **Added `utilization_multiplier`** to `PricingConfig` (default 2x). Wired through predict.move and registry.move.
- **Vault tracks strike-weighted sums**: added `sum_up_strike_qty: u128`, `sum_down_strike_qty: u128`. Updated `execute_mint`/`execute_redeem` to accumulate/decrement `quantity × strike`.
- **Changed `max_liability`** from `max(up, down)` to `up + down` (conservative bound — both sides can win at intermediate settlements).
- **Skew approach analysis** (documented in `SKEW.md`): evaluated 3 approaches for computing imbalance:
  1. Strike-weighted avg + oracle (current) — captures moneyness via expected liability, has bounded Jensen's inequality approximation error
  2. Per-side premiums - payouts — fundamentally flawed due to historical pollution (cumulative P&L mixes closed/open positions)
  3. Quantity-only (`total_up_short` vs `total_down_short`) — clean but ignores moneyness
- **Kept approach #1** (strike-weighted + oracle) after analysis showed premiums-payouts doesn't measure current risk (past redeems pollute the signal), and quantity-only ignores that ITM positions carry far more vault risk than OTM.

### Session: 2026-02-18 (vault value + cleanup)
- **strike_qty fields changed from u128 to u64**: use `math::mul(quantity, strike)` for accumulation (fixed-point aware) and `math::div(sum, qty)` for avg_strike recovery. No u128 needed.
- **Swapped `execute_mint`/`execute_redeem` arg order**: `(is_up, strike, quantity, ...)` groups market identity fields together.
- **Fixed `vault_value` bug**: `vault.max_liability` (field access) → `vault.max_liability()` (function call).
- **LP share pricing switched to expected NAV**: `supply`/`withdraw` now take oracle, compute `expected_vault_value = balance - expected_up - expected_down` using oracle-weighted liabilities. Conservative `max_liability` still used for `assert_total_exposure`. Vault stays oracle-free — receives `vault_value` as a parameter from predict.move.
- **Removed `cumulative_premiums`/`cumulative_payouts`**: unused informational counters — never read on-chain.
- **Collateral + regular redeem interaction is safe**: analyzed scenario where user mints UP-65k (vault-backed), locks it as collateral to mint UP-75k, then redeems UP-75k via regular `redeem`. Vault aggregate accounting (`total_up_short`) stays correct because: (1) the locked UP-65k cannot be redeemed against the vault until the user re-acquires UP-75k (which requires a new vault mint, restoring `total_up_short`), (2) the collateral lock forces re-engagement with the vault before the locked position is accessible, so exposure is genuinely zero in the intermediate state.

### Session: 2026-02-19 (simplify skew to quantity-based)
- **Replaced oracle-weighted skew with quantity-based skew**: `inventory_skew` now uses raw `total_up_short` vs `total_down_short` for imbalance instead of oracle-weighted expected liabilities. Imbalance = `(this_side - other_side) / (this_side + other_side)`. Removes oracle call from spread calculation.
- **Removed `expected_liabilities()` function** from predict.move — no longer needed.
- **Removed `inventory_skew` oracle/clock params**: simplified signature to just `(predict, is_up)`.
- **Removed strike-weighted sum tracking from vault**: deleted 4 struct fields (`sum_up_strike_qty`, `sum_up_strike_qty_negative`, `sum_down_strike_qty`, `sum_down_strike_qty_negative`), their accessor functions, and all signed arithmetic in `execute_mint`/`execute_redeem`.
- **Simplified `execute_mint`/`execute_redeem` signatures**: removed `strike` parameter (only used for strike-qty tracking).
- **Removed `predict_math` import from vault.move**: signed arithmetic (`add_signed_u64`/`sub_signed_u64`) no longer needed in vault. Still used by oracle.move for SVI calculations.
- **Rationale**: every binary contract has the same $1 max payout, so raw quantities already capture imbalance. Oracle-weighted skew added complexity (4 struct fields, signed math on every trade, oracle call during spread calc) with minimal pricing impact.

### Session: 2026-02-19 (vault tests)
- **Created `tests/vault/vault_tests.move`**: 14 tests covering every public and public(package) function in `vault.move`.
- **Test helpers**: `usdc!()` and `contracts!()` macros for realistic USDC-scaled amounts (1_000_000 = $1 / 1 contract), matching codebase conventions.
- **Happy-path tests** (8): `new_vault_empty`, `deposit_increases_balance`, `withdraw_decreases_balance`, `mint_up_updates_exposure`, `mint_down_updates_exposure`, `mint_multiple_oracles_independent`, `redeem_updates_exposure`, `full_cycle_mint_redeem_all`.
- **Custom error tests** (2): `redeem_insufficient_balance_aborts` (EInsufficientBalance), `assert_total_exposure_exceeded` (EExceedsMaxTotalExposure). Uses `constants::float_scaling!()` for percentage limits.
- **Implicit failure tests** (3): `withdraw_insufficient_balance_aborts` (framework balance split), `redeem_more_than_minted_aborts` (arithmetic underflow), `redeem_unknown_oracle_aborts` (table key not found).
- **Exposure boundary test** (1): `assert_total_exposure_ok` — liability within limit passes.
- All 19 tests pass (5 oracle + 14 vault).

### Session: 2026-02-19 (vault edge case tests)
- **Added 22 edge case tests to `tests/vault/vault_tests.move`** (14 → 36 total):
- **Underflow/overflow** (2): wrong-side redeem underflows `total_down_short`, large mint overflows `total_up_short` (2^63 + 2^63).
- **Zero-value edge cases** (3): mint zero quantity (takes payment, no exposure), redeem zero payout (closes exposure for free), deposit/withdraw zero.
- **Exposure boundary precision** (8): exact boundary (liability == balance × pct), one unit over, 50% limit pass/fail, zero balance + zero liability, 0% limit rejects any liability, 80% default boundary exact/exceeded.
- **Balance draining** (3): withdraw exact full balance, redeem drains to exactly zero, one unit over balance aborts.
- **Accumulation/multi-oracle** (5): sequential mints accumulate, same oracle UP+DOWN, partial redeems to zero, max_liability sums both sides across 3 oracles, 5-oracle mint/redeem with per-oracle isolation.

### Session: 2026-02-20 (predict_manager tests)
- **Created `tests/predict_manager_tests.move`**: 31 tests covering position tracking and collateral accounting.
- **Test setup**: `test_scenario`-based (required because `new()` calls `transfer::share_object`), with `setup()`/`teardown()` helpers.
- **Position basics** (6): new manager has no positions, increase creates entry, increase accumulates, decrease subtracts, decrease to zero, independent keys don't interfere.
- **Decrease failures** (3): nonexistent key (`EInsufficientPosition`), more than free (`EInsufficientFreePosition`), locked portion not counted as free.
- **Collateral locking** (7): free→locked transition, lock all free, accumulate same pair, different minted keys, nonexistent position aborts, more than free aborts, partial lock then exceed remaining.
- **Collateral releasing** (5): locked→free transition, release all, nonexistent collateral aborts, more than locked aborts, wrong minted key aborts, wrong locked key aborts.
- **Full cycles** (3): increase→lock→release→decrease, partial release then decrease, lock all then decrease aborts.
- **Zero quantities** (4): increase/decrease/lock/release with 0 are noops.
- **Isolation** (1): two collateral pairs on same locked_key released independently.
- **Owner** (1): owner address set correctly from tx sender.
- All 72 tests pass (5 oracle + 36 vault + 31 predict_manager).

### Session: 2026-02-20 (predict.move tests)
- **Created `tests/predict_tests.move`**: 26 tests covering the main orchestration module — spread pricing, mint/redeem flows, collateralized mint/redeem, and settlement.
- **Test helpers added to source modules**:
  - `predict.move`: `create_test_predict()` (bypasses `share_object`), `vault_mut()`, `vault_balance()`, `vault_exposure()` — all `#[test_only]`.
  - `oracle.move`: `settle_test_oracle()` — force-sets settlement price and deactivates oracle for testing.
- **Pricing / spread behavior** (9): spread is positive (ask > bid), UP+DOWN costs sum near quantity (market completeness), skew widens heavy side after imbalanced mints, skew is zero when balanced or empty, utilization widens spread at high liability/balance ratio, utilization is zero with no liability, settlement winner gets full price (1.0), settlement loser gets zero.
- **Mint orchestration** (4): happy path (balance/position/exposure updates), trading paused aborts (`ETradingPaused`), stale oracle aborts (`EOracleStale`), exposure limit aborts (`EExceedsMaxTotalExposure`).
- **Redeem orchestration** (5): happy path, settled winner gets full payout, settled loser gets zero payout, stale+settled oracle succeeds (stale check skipped), stale+unsettled aborts.
- **Collateralized mint/redeem** (7): UP low→UP high happy path, DOWN high→DOWN low happy path, UP→DOWN direction mismatch aborts (`EInvalidCollateralPair`), wrong strike order aborts, same strike aborts, paused aborts, redeem releases collateral.
- **Full integration** (1): deposit→mint UP+DOWN→settle→redeem winner+loser end-to-end.
- **Design note**: settlement at exactly strike resolves as DOWN win (`settlement_price > strike` is false) — intentional tie-breaking rule.
- All 163 tests pass (5 oracle + 36 vault + 31 predict_manager + 26 predict + 18 market_key + 47 math).

### Session: 2026-02-20 (market_key + math tests)
- **Created `tests/market_key_tests.move`**: 18 tests covering all public functions in `market_key.move`.
- **Constructor tests** (4): `up()`, `down()`, `new(true)`, `new(false)` — verify direction and field values.
- **Equality tests** (7): same params equal, different direction/strike/expiry/oracle_id not equal, `new()` matches `up()`/`down()` constructors.
- **assert_matches_oracle tests** (5): happy path, wrong oracle_id aborts (`EOracleMismatch`), wrong expiry aborts (`EExpiryMismatch`), any strike passes, DOWN direction passes.
- **Edge cases** (2): zero strike/expiry, max u64 strike/expiry.
- **Created `tests/math_tests.move`**: 47 tests covering all public functions in `math.move`.
- **ln tests** (9): ln(1)=0, ln(e)≈1, ln(2)≈0.693, ln(10)≈2.303, ln(<1) negative, ln(0.01), ln(100), inverse symmetry, ln(0) aborts.
- **exp tests** (8): exp(0)=1, exp(1)≈2.718, exp(-1)≈0.368, exp(2)≈7.389, exp(ln2)≈2, large negative→0, exp(ln(x))≈x roundtrip (x=5, x=0.25).
- **normal_cdf tests** (10): Φ(0)=0.5, symmetry at 1.0 and 2.0, Φ(1)≈0.841, Φ(-1)≈0.159, Φ(2)≈0.977, large positive→1, large negative→0, monotonicity, Φ(0.5)≈0.691.
- **Signed arithmetic tests** (20): add_signed_u64 (9 — same/different signs, cancellation, zero identity, -0 normalization), sub_signed_u64 (6 — all sign combinations, equal values), mul_signed_u64 (5 — sign rules, zero, identity).
- **Note**: `supply_manager` no longer exists — removed in earlier refactor. All current source modules now have test coverage.
### Session: 2026-02-20 (cross-validation tests)
- **Created `cross_validation.py`**: Python harness that computes binary option prices using the exact same math path as the Move contract (SVI → total_var → d2 → N(d2) → discount), outputting all values in FLOAT_SCALING (1e9) integer format.
- **Created `tests/cross_validation_tests.move`**: 14 tests comparing Move output against Python/scipy reference values.
- **Scenario 1 — Real BTC (126 days)**: SVI params from live BlockScholes API (a=0.01178, b=0.18226, rho=-0.28796, m=0.02823, sigma=0.34312), spot=$67,293, forward=$68,071, r=3.5%. Tested ATM, OTM (+$10k), ITM (-$10k), Deep ITM (-$20k) — both discounted and undiscounted.
- **Scenario 2 — Synthetic (30 days)**: a=0.04, b=0.1, rho=-0.3, m=0, sigma=0.1, spot=$100k, forward=$100.5k, r=5%. Tested ATM, OTM ($110k), ITM ($90k) — both discounted and undiscounted.
- **Precision results**: maximum deviation between Move and Python is ~68 out of 1,000,000,000 (0.000007%). Tolerance set to 0.01% (100,000) — 1,000x above actual deviation. The Move fixed-point Taylor series (ln/exp) and Abramowitz-Stegun (normal_cdf) approximations are extremely accurate.
- **Also verified**: UP + DOWN sum equals discount factor (put-call parity for binary options) holds in all test cases within tolerance.
- All 177 tests pass (5 oracle + 36 vault + 31 predict_manager + 26 predict + 18 market_key + 47 math + 14 cross-validation).

### Session: 2026-02-20 (testnet deployment)
- **Deployed full predict stack to testnet** with deployment scripts in `scripts/transactions/predict/`:
  - `dusdc` package: mintable test USDC (6 decimals) at `packages/dusdc/`
  - `deepbook_predict` package: published to testnet
  - `Predict<DUSDC>` shared object initialized
  - OracleCap created (owned by deployer)
  - `OracleSVI<SUI>` shared object created (SUI as phantom Underlying for BTC price feed, 30-day expiry)
  - 1M DUSDC deposited into vault
- **Deployment scripts created** (`scripts/transactions/predict/`):
  - `dusdcPublish.ts` / `dusdcMint.ts` — deploy and mint test USDC
  - `publish.ts` — publish predict package, writes IDs to constants
  - `init.ts` — create Predict<DUSDC>, writes object ID to constants
  - `deposit.ts` — mint DUSDC + deposit into vault (default 1M, configurable via `AMOUNT` env var)
  - `createOracleCap.ts` — create OracleCap, writes ID to constants
  - `createOracle.ts` — create Oracle shared object (default 30-day expiry, configurable via `EXPIRY` env var)
- **All scripts auto-write IDs to `scripts/config/constants.ts`** — no manual copy-paste between steps
- **npm scripts added**: `dusdc-publish`, `dusdc-mint`, `predict-publish`, `predict-init`, `predict-deposit`, `predict-create-oracle-cap`, `predict-create-oracle`
- **Testnet state**: package deployed, Predict<DUSDC> initialized, vault funded with 1M DUSDC, OracleCap + Oracle created. Oracle not yet activated or fed data — ready for Block Scholes integration.

### Session: 2026-03-01 (oracle events + indexer + oracle feed)

#### Move Changes
- **Added `OraclePricesUpdated` event** to `oracle.move`: emitted in `update_prices` with `oracle_id`, `spot`, `forward`, `timestamp`
- **Added `OracleSVIUpdated` event** to `oracle.move`: emitted in `update_svi` with `oracle_id`, all SVI params (`a`, `b`, `rho`, `rho_negative`, `m`, `m_negative`, `sigma`), `risk_free_rate`, `timestamp`
- **NOT YET DEPLOYED** — testnet package still has old code without these events

#### Predict Indexer (`crates/predict-indexer/` — new crate)
- Rust indexer using `sui_indexer_alt_framework` with 15 concurrent pipeline handlers
- **Oracle** (4): OracleActivated, OracleSettled, OraclePricesUpdated, OracleSviUpdated
- **Registry** (3): PredictCreated, OracleCreated, AdminVaultBalanceChanged
- **Trading** (4): PositionMinted, PositionRedeemed, CollateralizedPositionMinted, CollateralizedPositionRedeemed
- **Admin** (3): TradingPauseUpdated, PricingConfigUpdated, RiskConfigUpdated
- **User** (1): PredictManagerCreated
- `define_handler!` macro eliminates per-handler boilerplate (~400 lines → ~15 lines each)
- `MoveStruct` trait for BCS event type matching by package address + module + event name
- `is_predict_tx` filter checks input objects, events, and Move calls
- `PredictConfig` supports testnet default + CLI override (`--predict-package-id`)
- Prometheus metrics on `:9185`
- All 15 event structs verified against Move source (field names, types, BCS ordering all match)

#### Predict Schema (`crates/predict-schema/` — new crate)
- 15 Diesel tables (one per event), all with `event_digest` primary key
- Standard metadata columns: `digest`, `sender`, `checkpoint`, `timestamp`, `checkpoint_timestamp_ms`, `package`
- Migration: `2026-03-01-000000_predict_initial/up.sql`

#### Oracle Feed Service (`scripts/services/` — new)
- **`oracle-feed.ts`** — long-running service polling BlockScholes API, pushes data on-chain via PTBs
  - Price updates every 500ms (spot shared across oracles + forward per expiry)
  - SVI parameter updates every 20s
  - Scales floats to u64 (1e9 multiplier), handles signed params (magnitude + negative flag)
  - Activates oracles on startup, hardcoded 3.5% domestic risk-free rate
- **`blockscholes-oracle.ts`** — full pricing library (TypeScript)
  - BlockScholes REST API client (spot, forward, SVI) with X-API-Key auth
  - In-memory data storage with versioning and SHA256-hashed feed keys
  - SVI implied vol calculator, Black-Scholes option pricing (calls, puts, digitals)
  - Greeks: delta, gamma, vega, theta, volga, vanna
  - Derived data provider pattern (SVI → IV → Option Price)

#### Oracle Config & Deployment
- **`scripts/config/predict-oracles.ts`** — 5 testnet BTC oracles (expiries: Mar 6/13/20/27, Apr 24)
- **`scripts/transactions/predict/deployOracles.ts`** — creates OracleSVI objects, writes IDs back to config
- **`scripts/package.json`** — added `oracle-feed` script

#### Local Indexer Testing
- Verified: `cargo build -p predict-indexer` and `cargo build -p predict-schema` both clean
- Ran indexer locally against Postgres (port 5433, database `predict`)
- Migrations ran successfully, all 15 pipelines started
- Caught up to testnet tip at ~700 cps, tailed real-time at ~4 cps
- **No events indexed** — predict package needs redeployment with new oracle events

#### Minor Fixes
- Updated Move formatter command in `.claude/rules/move.md` and `CLAUDE.md` to `npx prettier --plugin @mysten/prettier-plugin-move --write <file>`

#### Current Blocker
~~**Predict package needs redeployment to testnet.**~~ — Resolved in Session 2026-03-01 (redeploy).

#### Not Yet Built
- Server/API layer (HTTP endpoints to query indexed data)
- Database indexes (secondary indexes on oracle_id, trader, checkpoint)
- `down.sql` migration (rollback)
- Deployment config (Dockerfile, K8s, Pulumi)

### Session: 2026-03-01 (redeploy)

#### Unified Redeploy Script (`scripts/transactions/predict/redeploy.ts` — new)
- **Single script** runs full 8-step deployment pipeline end-to-end: discover expiries → publish → init → create oracle cap → deploy oracles → deposit DUSDC → update indexer package ID → reset database
- **Step 1 — Expiry discovery**: probes BlockScholes API (`fetchSVIParams` + `fetchForwardPrice`) for next 12 Thursdays, falls back to Fridays, keeps first 5 with valid data on both endpoints
- **Steps 2–6**: reuse patterns from individual scripts (`publish.ts`, `init.ts`, `createOracleCap.ts`, `deployOracles.ts`, `deposit.ts`), passing IDs as local variables between steps
- **Step 7**: regex-replaces package ID in `crates/predict-indexer/src/lib.rs`
- **Step 8**: resets Postgres database via `psql` (port configurable via `PGPORT`, defaults to 5433)
- `waitForTransaction` after every `signAndExecuteTransaction` to prevent stale shared object / package-not-found errors
- Added `predict-redeploy` npm script to `scripts/package.json`

#### Bug Fixes
- **`blockscholes-oracle.ts`**: guarded top-level `main()` demo so it only runs when executed directly, not when imported by other scripts
- **Expiry discovery**: must probe both `fetchSVIParams` AND `fetchForwardPrice` — some dates have SVI data but no forward price data (causes oracle feed 404s)

#### Oracle Feed Improvements
- **Parallel API fetches**: spot + all forward prices + all SVI params now fetched via `Promise.all` instead of sequentially (cuts API fetch time from ~6 serial round trips to ~1)

#### Redeployment Complete
- Package redeployed with oracle events (`OraclePricesUpdated`, `OracleSVIUpdated`)
- 5 oracles created with BlockScholes-validated expiry dates
- 1M DUSDC deposited into vault
- Indexer package ID updated, database reset
- Oracle feed running, indexer catching up
