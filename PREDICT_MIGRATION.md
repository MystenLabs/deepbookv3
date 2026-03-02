# DeepBook Predict - Migration Plan

Source branch: `at/predict`

Each PR is a self-contained vertical slice — one component plus only the dependencies it
needs. No dead code, no "will be used later" functions. Every line is reachable.

All modules live in one Move package (`deepbook_predict`). Each PR accumulates — it includes
all previously merged modules plus the new ones. Reviewers focus on the diff.

Tests ship separately at the end (split into unit + integration).

---

## Phase 1: Smart Contracts (source only, no tests)

### PR 1 — Oracle
> SVI volatility oracle with Black-Scholes binary option pricing (~700 lines)

**New files:**
- [ ] `packages/predict/Move.toml`
- [ ] `packages/predict/sources/helper/constants.move` (only 3 macros: `float_scaling`, `staleness_threshold_ms`, `ms_per_year`)
- [ ] `packages/predict/sources/helper/math.move`
- [ ] `packages/predict/sources/oracle.move`

**What ships:**
- `OracleSVI<Underlying>` — shared object: SVI params, spot/forward, settlement
- `OracleCapSVI` — operator capability for price feeds
- `compute_nd2` → Black-Scholes N(d2) via SVI surface
- `get_binary_price` — main pricing entry point
- Staleness checks, activation, settlement
- Math library: `ln`, `exp`, `normal_cdf`, signed arithmetic
- Constants: only the 3 macros oracle actually uses

**Helper usage:**
| Helper | Functions used |
|--------|--------------|
| `constants` | `float_scaling!()`, `staleness_threshold_ms!()`, `ms_per_year!()` |
| `math` | `ln()`, `exp()`, `normal_cdf()`, `sub_signed_u64()`, `add_signed_u64()`, `mul_signed_u64()` |
| `deepbook::math` | `mul()`, `div()`, `sqrt()` |

---

### PR 2 — Vault + Configs
> Protocol treasury, exposure tracking, tunable parameters (~230 lines)

**New files:**
- [ ] `packages/predict/sources/vault/vault.move`
- [ ] `packages/predict/sources/config/pricing_config.move`
- [ ] `packages/predict/sources/config/risk_config.move`

**Update existing:**
- [ ] `packages/predict/sources/helper/constants.move` — add 4 config default macros: `default_base_spread`, `default_max_skew_multiplier`, `default_utilization_multiplier`, `default_max_total_exposure_pct`

**What ships:**
- `Vault<Quote>` — holds protocol USDC, tracks per-oracle UP/DOWN short exposure
- `execute_mint` / `execute_redeem` — atomic balance + exposure updates
- `assert_total_exposure` — risk invariant: max liability ≤ balance × max_pct
- `PricingConfig` — base_spread, max_skew_multiplier, utilization_multiplier
- `RiskConfig` — max_total_exposure_pct

---

### PR 3 — Market Key + Predict Manager
> Position identifiers and per-user state (~250 lines)

**New files:**
- [ ] `packages/predict/sources/market_key/market_key.move`
- [ ] `packages/predict/sources/predict_manager.move`

**What ships:**
- `MarketKey(oracle_id, expiry, strike, direction)` — compact position key (UP/DOWN)
- `PredictManager` — per-user shared object wrapping DeepBook `BalanceManager`
- Position table: `Table<MarketKey, UserPosition>` (free + locked)
- Collateral table: `Table<CollateralKey, u64>` (paired position locks)

---

### PR 4 — Predict Core + Registry
> Main protocol logic, admin controls (~700 lines)

**New files:**
- [ ] `packages/predict/sources/predict.move`
- [ ] `packages/predict/sources/registry.move`

**What ships:**
- `Predict<Quote>` — main shared object, owns `Vault` + configs
- `mint` / `redeem` — user trading (buy/sell binary positions via USDC)
- `mint_collateralized` / `redeem_collateralized` — zero-cost paired trades
- `get_quote` — bid/ask = oracle price ± (base_spread + skew + utilization)
- `Registry` — admin entry: create predict, create/manage oracles, config setters
- `AdminCap` — created at package init, transferred to deployer

---

### PR 5a — Unit Tests
> Tests for individual modules (~2600 lines)

- [ ] `packages/predict/tests/math_tests.move`
- [ ] `packages/predict/tests/oracle_tests.move`
- [ ] `packages/predict/tests/vault/vault_tests.move`
- [ ] `packages/predict/tests/market_key_tests.move`
- [ ] `packages/predict/tests/predict_manager_tests.move`

### PR 5b — Integration Tests
> End-to-end protocol tests (~1200 lines)

- [ ] `packages/predict/tests/predict_tests.move`
- [ ] `packages/predict/tests/cross_validation_tests.move`

---

## Phase 2: Indexer + Server

### PR 6 — Schema + Migrations
- [ ] `crates/predict-schema/` (full crate)

### PR 7 — Indexer
- [ ] `crates/predict-indexer/` (full crate)

### PR 8 — Server (API)
- [ ] `crates/predict-server/` (full crate)

---

## Phase 3: Scripts + Services

### PR 9 — Deployment Scripts
- [ ] `scripts/transactions/predict/`
- [ ] `scripts/config/predict-oracles.ts`

### PR 10 — Oracle Services
- [ ] `scripts/services/blockscholes-oracle.ts`
- [ ] `scripts/services/oracle-feed.ts`
- [ ] `scripts/services/oracle-dashboard.ts`

---

## Phase 4: Infra + CI

### PR 11 — Docker + CI
- [ ] `docker/predict-indexer/`
- [ ] `docker/predict-server/`
- [ ] `docker/oracle-feed/`
- [ ] `.github/workflows/deploy-predict.yml`

---

## Dependency Graph

```
PR 1  Oracle (+ constants, math)       ← no deps, start here
  │
  ├── PR 2  Vault + Configs            ← can parallel with PR 3
  │
  ├── PR 3  Market Key + Predict Mgr   ← can parallel with PR 2
  │
  └── PR 4  Predict + Registry         ← blocked on PR 2 + PR 3
        │
        ├── PR 5a  Unit Tests
        └── PR 5b  Integration Tests
              │
              ├── PR 6 → PR 7 → PR 8   (schema → indexer → server)
              ├── PR 9  Deploy Scripts
              ├── PR 10 Oracle Services
              └── PR 11 Docker + CI
```

## Module → PR Map

| Module | Introduced in | Depends on (internal) |
|--------|--------------|----------------------|
| constants (3 macros) | PR 1 | — |
| constants (+4 macros) | PR 2 | — |
| math | PR 1 | constants |
| oracle | PR 1 | constants, math |
| vault | PR 2 | — |
| pricing_config | PR 2 | constants |
| risk_config | PR 2 | constants |
| market_key | PR 3 | oracle |
| predict_manager | PR 3 | market_key |
| predict | PR 4 | all of the above |
| registry | PR 4 | oracle, predict |

---

## PR Log

| PR | Branch | Status | Link |
|----|--------|--------|------|
| 1 | | pending | |
| 2 | | blocked on 1 | |
| 3 | | blocked on 1 | |
| 4 | | blocked on 2,3 | |
| 5a | | blocked on 4 | |
| 5b | | blocked on 5a | |
