# deepbook_predict

Binary options protocol built on Sui. Users bet on whether asset prices will be above or below a strike price at expiration.

## MVP Scope

- Core trading (mint/redeem/get_quote)
- Vault with LP deposits/withdrawals and share accounting
- Oracle integration (Block Scholes volatility surface)
- Exposure tracking
- Inventory-based dynamic spread adjustment
- Position limits and circuit breakers
- Withdrawal delays (24h lockup)
- Admin controls (pause, parameter updates, market creation)
- Collateral manager (position-as-collateral for spreads)

**Not Included:**
- Hedging infrastructure

## Module Structure

```
sources/
├── predict.move                 # Main entry point: all public functions + events
├── registry.move                # Registry + AdminCap + market registration
├── oracle.move                  # Oracle shared object, data updates, staleness
│
├── vault/
│   ├── vault.move               # Vault struct, balance, shares
│   ├── state.move               # Exposure tracking per market
│   └── config.move              # VaultConfig risk parameters
│
├── market/
│   ├── market.move              # Market struct, MarketId, lifecycle
│   ├── position.move            # Position token representation
│   └── settlement.move          # Settlement price, outcome determination
│
├── collateral/
│   ├── collateral.move          # CollateralManager, records table
│   └── record.move              # CollateralRecord struct
│
├── trading/
│   ├── pricing.move             # Black-Scholes calc, spread adjustment
│   └── risk.move                # Position limits, circuit breaker validation
│
└── helper/
    ├── constants.move           # All constants
    └── math.move                # Math utilities (exp, ln, normal CDF)
```

## Components

### Registry (`registry.move`)
- `Registry` shared object - tracks all markets
- `AdminCap` capability for admin operations
- Market registration/lookup
- Global pause flags

### Oracle (`oracle.move`)
- `Oracle` shared object per expiry
- `OracleData` struct (spot_price, volatility_surface, risk_free_rate, timestamp)
- `update()` - oracle provider pushes data
- Staleness check (30s threshold)

### Vault (`vault/`)
- `Vault` shared object holding LP funds
- `VaultShare` object for LP positions (with deposit timestamp for lockup)
- `State` - exposure tracking per market, total liability
- `Config` - risk parameters (limits, spread params, lockup duration)

### Market (`market/`)
- `Market` struct (underlying, strike, expiry, direction)
- `MarketId` - unique identifier for each market
- `Position` - token wrapper for user holdings
- Settlement logic - compare settlement price vs strike

### Collateral Manager (`collateral/`)
- `CollateralManager` shared object
- `CollateralRecord` - tracks locked collateral and minted positions
- Validates collateral rules (same expiry, valid strike relationship)

### Trading (`trading/`)
- `pricing.move` - Black-Scholes for binary options, IV interpolation, dynamic spread
- `risk.move` - position limit checks, circuit breaker conditions

### Helper (`helper/`)
- `constants.move` - scaling factors, default limits, time constants
- `math.move` - fixed-point math, exp/ln approximations, normal CDF

## Public Functions (in `predict.move`)

### LP Actions
```move
public fun deposit(vault, usdc, clock, ctx) → VaultShare
public fun withdraw(vault, share, clock, ctx) → Coin<USDC>
```

### Trading Actions
```move
public fun get_quote(vault, oracle, market_id, clock) → (bid, ask)
public fun mint(vault, oracle, market_id, usdc, clock, ctx) → Position
public fun redeem(vault, oracle, position, clock, ctx) → Coin<USDC>
```

### Collateral Actions (Spreads)
```move
public fun mint_with_collateral(vault, collateral_mgr, collateral_position, target_market, clock, ctx) → (Position, ID)
public fun unlock_collateral(vault, collateral_mgr, oracle, record_id, minted_position_opt, clock, ctx) → Position
```

### Admin Actions (require AdminCap)
```move
public fun create_market(registry, admin_cap, underlying, strike, expiry, clock, ctx)
public fun pause_trading(registry, admin_cap)
public fun unpause_trading(registry, admin_cap)
public fun pause_withdrawals(registry, admin_cap)
public fun unpause_withdrawals(registry, admin_cap)
public fun update_max_single_trade_pct(registry, admin_cap, value)
public fun update_max_exposure_per_market_pct(registry, admin_cap, value)
public fun update_base_spread_bps(registry, admin_cap, value)
// ... etc for each config parameter
```

### Oracle Actions
```move
public fun update_oracle(oracle, oracle_cap, data, clock)
```

## Events (emitted from `predict.move`)

```move
// Trading
PositionMinted { market_id, trader, amount, price, usdc_paid }
PositionRedeemed { market_id, trader, amount, price, usdc_received, is_settlement }

// Vault
LiquidityDeposited { depositor, usdc_amount, shares_minted, share_value }
LiquidityWithdrawn { withdrawer, shares_burned, usdc_received, share_value }

// Market
MarketCreated { market_id, underlying, strike, expiry }
MarketSettled { market_id, settlement_price, up_wins }

// Collateral
CollateralDeposited { record_id, owner, collateral_market_id, minted_market_id, amount }
CollateralUnlocked { record_id, owner }

// Admin
TradingPaused { paused_by }
TradingUnpaused { unpaused_by }
WithdrawalsPaused { paused_by }
WithdrawalsUnpaused { unpaused_by }
RiskParameterUpdated { parameter, old_value, new_value }
```

## Key Design Decisions

1. **Single Vault** - One vault acts as counterparty to all markets
2. **Spread-Only Fees** - No trading fees, vault profits from bid/ask spread (100% to LPs)
3. **Inventory-Based Spreads** - Spread widens when vault exposure is imbalanced
4. **24h LP Lockup** - Prevents deposit-before-settlement attacks
5. **Automatic Settlement** - redeem() handles both pre-expiry (bid price) and post-expiry (settlement)
6. **7-Day Grace Period** - Unclaimed positions after grace period go to vault
7. **AdminCap in Multisig** - Single capability, no timelocks, immediate parameter updates

## Internal Flow

```
mint(market_id, usdc):
  1. Check oracle not stale
  2. Calculate ask price (pricing.move)
  3. Validate against risk limits (risk.move)
  4. Update vault exposure (state.move)
  5. Mint position token
  6. Emit PositionMinted event

redeem(position):
  1. Check if market expired
  2. If pre-expiry: calculate bid price
  3. If post-expiry: determine settlement (win=$1, lose=$0)
  4. Update vault exposure
  5. Burn position token
  6. Transfer USDC to user
  7. Emit PositionRedeemed event
```

## Dependencies

- Sui Framework (Clock, Coin, Balance, Table, etc.)
