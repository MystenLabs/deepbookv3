# deepbook_predict

Binary options protocol built on Sui. Users bet on whether asset prices will be above (UP) or below (DOWN) a strike price at expiration. The vault acts as counterparty to all trades.

## Architecture

A single `Predict` shared object orchestrates all operations. It holds the vault, pricing config, LP config, and risk config. Users interact through `PredictManager` objects that hold their USDC balances and position state.

Pricing uses an on-chain SVI volatility surface oracle (provided by Block Scholes) to compute Black-Scholes binary option prices for any strike.

## Module Structure

```
sources/
├── predict.move              # Entry point: mint, redeem, collateral, supply, withdraw, pricing
├── registry.move             # AdminCap, Registry shared object, oracle/predict creation
├── oracle.move               # SVI oracle: volatility surface, binary pricing, settlement
├── predict_manager.move      # User state: USDC balance, positions, collateral locks
│
├── vault/
│   ├── vault.move            # Vault: USDC balance, exposure tracking, LP supply/withdraw
│   └── supply_manager.move   # LP share accounting, lockup enforcement
│
├── config/
│   ├── pricing_config.move   # Spread parameters (base_spread, skew, utilization)
│   ├── risk_config.move      # Exposure limits (max_total_exposure_pct)
│   └── lp_config.move        # LP settings (lockup period)
│
├── market_key/
│   └── market_key.move       # MarketKey: (oracle_id, expiry, strike, direction)
│
└── helper/
    ├── constants.move        # Scaling factors, default config, time constants
    └── math.move             # ln, exp, normal_cdf, signed arithmetic
```

## Key Concepts

### Vault as Counterparty

The vault holds LP-supplied USDC and takes the opposite side of every trade. When a user mints UP, the vault goes short UP. When the user redeems, the vault buys back that exposure. Vault value is `balance - expected_liabilities`, used to price LP shares.

### Two Ways to Mint

1. **Regular mint**: User pays USDC. Vault takes on short exposure.
2. **Collateralized mint**: User locks an existing position to mint a new one (e.g., lock UP-50k to mint UP-60k). No USDC, no additional vault exposure — the locked collateral always covers the minted position.

### Spread Pricing

Spread has three additive components:
- **Base spread**: fixed parameter
- **Inventory skew**: penalizes the heavy side using oracle-weighted expected liability per direction
- **Utilization**: penalizes both sides as vault approaches capacity (uses util²)

### Settlement

After expiry, the oracle freezes a settlement price. Winners receive $1 per contract (= `quantity` in USDC units), losers receive $0. Redeem works both pre-expiry (at bid price) and post-expiry (at settlement value).

## Public Functions

### Trading

```move
get_trade_amounts(predict, oracle, key, quantity, clock) → (mint_cost, redeem_payout)
mint(predict, manager, oracle, key, quantity, clock, ctx)
redeem(predict, manager, oracle, key, quantity, clock, ctx)
```

### Collateral

```move
mint_collateralized(predict, manager, oracle, locked_key, minted_key, quantity, clock)
redeem_collateralized(predict, manager, locked_key, minted_key, quantity)
```

### LP Operations

```move
supply(predict, oracle, coin, clock, ctx) → shares
withdraw(predict, oracle, shares, clock, ctx) → Coin<Quote>
```

### Admin (via Registry + AdminCap)

```move
create_predict(registry, admin_cap, ctx)
create_oracle_cap(admin_cap, ctx)
create_oracle(registry, admin_cap, cap, expiry, ctx)
set_trading_paused(predict, admin_cap, paused)
set_withdrawals_paused(predict, admin_cap, paused)
set_lockup_period(predict, admin_cap, period_ms)
set_base_spread(predict, admin_cap, spread)
set_max_skew_multiplier(predict, admin_cap, multiplier)
set_utilization_multiplier(predict, admin_cap, multiplier)
set_max_total_exposure_pct(predict, admin_cap, pct)
```

### Oracle (via OracleCapSVI)

```move
activate(oracle, cap, clock)
update_prices(oracle, cap, prices, clock)
update_svi(oracle, cap, svi, risk_free_rate, clock)
```

## Dependencies

- Sui Framework (Clock, Coin, Balance, Table)
- DeepBook (math, BalanceManager)
