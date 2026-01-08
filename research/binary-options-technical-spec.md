# DeepBook Binary Options Protocol - Technical Specification

*Version 1.0 - January 2026*

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Oracle Design](#3-oracle-design)
4. [Core Options Contract](#4-core-options-contract)
5. [Counterparty Vault](#5-counterparty-vault)
6. [Risk Management](#6-risk-management)
7. [Collateral Manager](#7-collateral-manager)
8. [Hedging Infrastructure](#8-hedging-infrastructure)
9. [Admin & Governance](#9-admin--governance)
10. [Events](#10-events)
11. [User Flows](#11-user-flows)
12. [Implementation Phases](#12-implementation-phases)

---

## 1. Overview

### 1.1 Product Description

A fully on-chain binary options protocol built as an extension to DeepBook. Users bet on whether the price of an asset (e.g., BTC) will be above or below a strike price at expiration.

**Key Characteristics:**
- **Binary payoff:** $1 if correct, $0 if incorrect
- **Vault-based counterparty:** Single vault acts as counterparty to all trades (similar to HyperLiquid HLP)
- **Oracle-driven pricing:** Block Scholes volatility surface for professional-grade pricing
- **Spread-only fees:** No trading fees; vault profits from bid/ask spread
- **Capital-efficient spreads:** Position-as-collateral enables bull/bear spreads
- **Fully on-chain settlement**

### 1.2 Key Actors

| Actor | Description |
|-------|-------------|
| **Trader** | Buys/sells binary options positions |
| **LP (Liquidity Provider)** | Deposits USDC into vault, earns yield from spreads |
| **Oracle (Block Scholes)** | Provides volatility surface data for pricing |
| **Keeper** | Executes hedging operations (off-chain) |
| **Admin** | Multisig that manages parameters, creates markets, emergency controls |

### 1.3 Fee Structure

**Spread-only model:**
- Traders pay the ask price when minting positions
- Traders receive the bid price when redeeming before expiry
- 100% of spread goes to the vault (LPs)
- No additional trading fees, protocol fees, or settlement fees

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         USERS                                    │
│                  (Traders & LPs)                                 │
└─────────────────┬───────────────────────────┬───────────────────┘
                  │                           │
                  ▼                           ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐
│    Core Options Contract    │   │    Counterparty Vault       │
│  ─────────────────────────  │   │  ─────────────────────────  │
│  • mint(market, usdc)       │   │  • deposit(usdc) → shares   │
│  • redeem(position) → usdc  │   │  • withdraw(shares) → usdc  │
│  • get_quote(market)        │   │  • exposure tracking        │
│  • Position tokens (Coin)   │   │  • spread calculation       │
└─────────────────┬───────────┘   └─────────────────┬───────────┘
                  │                                 │
                  │         ┌───────────────────────┘
                  │         │
                  ▼         ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐
│    Collateral Manager       │   │    Oracle (Block Scholes)   │
│  ─────────────────────────  │   │  ─────────────────────────  │
│  • deposit_and_mint()       │   │  • Volatility surface       │
│  • unlock()                 │   │  • ~1 update/second         │
│  • Spread positions         │   │  • One oracle per expiry    │
└─────────────────────────────┘   └─────────────────────────────┘
```

### 2.2 Module Structure

```
packages/
└── deepbook_options/
    ├── Move.toml
    └── sources/
        ├── options.move              # Main entry point
        ├── options/
        │   ├── market.move           # Market creation & management
        │   ├── vault.move            # LP vault (deposits, withdrawals, shares)
        │   ├── vault_state.move      # Exposure tracking, P&L
        │   ├── pricing.move          # Quote calculation from oracle
        │   ├── position.move         # Position token (dynamic coin)
        │   ├── settlement.move       # Settlement logic
        │   └── risk.move             # Risk limits, circuit breakers
        ├── collateral/
        │   ├── collateral_manager.move   # Position-as-collateral
        │   └── collateral_record.move    # Tracking records
        ├── oracle/
        │   └── oracle.move           # Oracle interface & data structures
        └── admin/
            └── admin.move            # Admin capabilities, parameter updates
```

---

## 3. Oracle Design

### 3.1 Data Provider

**Block Scholes** - Options pricing research firm that pushes volatility surface data on-chain.

### 3.2 Update Frequency

- ~1 update per second (high frequency)
- One oracle per expiry (not per strike)
- Single oracle can price multiple strikes for same expiry

### 3.3 Data Structures

```move
public struct OracleData has store, drop {
    expiry: u64,                          // Expiration timestamp
    underlying: TypeName,                 // e.g., BTC
    spot_price: u64,                      // Current spot price (scaled)
    volatility_surface: vector<VolPoint>, // IV at different strikes
    risk_free_rate: u64,                  // For Black-Scholes calculation
    timestamp: u64,                       // When data was published
}

public struct VolPoint has store, drop, copy {
    strike: u64,
    implied_volatility: u64,              // IV at this strike (scaled)
}
```

### 3.4 Price Computation

Binary option prices computed using Black-Scholes:

```
Binary Call Price = e^(-rT) * N(d2)
Binary Put Price  = e^(-rT) * N(-d2)

where:
d2 = [ln(S/K) + (r - 0.5*σ²)*T] / (σ*√T)

S = spot price (from oracle)
K = strike price
r = risk-free rate (from oracle)
σ = implied volatility (interpolated from oracle surface)
T = time to expiry
```

### 3.5 Staleness & Fallback

| Condition | Action |
|-----------|--------|
| `now - timestamp > 30 seconds` | Oracle considered stale |
| Stale oracle | Pause trading, allow only redemptions |
| No fallback oracle | Not implemented initially (can add Pyth/Chainlink later) |

---

## 4. Core Options Contract

### 4.1 Market Definition

Each market is defined by:

| Field | Description | Example |
|-------|-------------|---------|
| `underlying` | Asset being tracked | BTC |
| `strike` | Price threshold | $90,000 |
| `expiry` | Settlement timestamp | Tomorrow 00:00 UTC |
| `direction` | UP (above) or DOWN (below) | UP |

**Invariant:** `UP_price + DOWN_price = $1`

### 4.2 Market Lifecycle

```
Day 0:
  └─ Create 5 markets for Day 1 expiry (strikes around current price)
  └─ Markets tradeable for ~36 hours

Day 1:
  └─ Create 5 markets for Day 2 expiry
  └─ Day 1 markets expire at 00:00 UTC
  └─ Settlement price determined from oracle
  └─ Users can claim winning positions

Day 2+:
  └─ Rolling cycle continues
```

### 4.3 Position Tokens

Positions are fungible tokens using Sui's coin system:

```move
public struct MarketId has store, copy, drop {
    underlying: TypeName,
    strike: u64,
    expiry: u64,
    direction: u8,  // 0 = UP, 1 = DOWN
}

// Position represented as Coin<POSITION>
// Each (underlying, strike, expiry, direction) = unique position type
```

### 4.4 Core Functions

```move
/// Get current bid/ask quote for a market
public fun get_quote(
    vault: &Vault,
    oracle: &Oracle,
    market_id: MarketId,
    clock: &Clock,
): (u64, u64)  // (bid, ask)

/// Mint a position by paying USDC (trader pays ask price)
public fun mint(
    vault: &mut Vault,
    oracle: &Oracle,
    market_id: MarketId,
    usdc: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<POSITION>

/// Redeem a position for USDC
/// Before expiry: receive bid price
/// After expiry: receive $1 (win) or $0 (lose)
public fun redeem(
    vault: &mut Vault,
    oracle: &Oracle,
    position: Coin<POSITION>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```

### 4.5 Settlement

| Aspect | Behavior |
|--------|----------|
| Settlement trigger | User calls `redeem()` (not auto-settle) |
| Settlement price | Oracle price at expiry timestamp |
| Grace period | 7 days to claim positions |
| Unclaimed positions | Funds go to vault after grace period |

---

## 5. Counterparty Vault

### 5.1 Overview

Single vault acts as counterparty to all trades. LPs deposit USDC, earn yield from spread capture and favorable settlements.

### 5.2 Data Structures

```move
public struct Vault has key {
    id: UID,
    balance: Balance<USDC>,
    total_shares: u64,
    exposure: ExposureTracker,
    config: VaultConfig,
    trading_paused: bool,
    withdrawals_paused: bool,
}

public struct VaultShare has key, store {
    id: UID,
    shares: u64,
    deposited_at: u64,  // For lockup enforcement
}

public struct ExposureTracker has store {
    positions: Table<MarketId, i64>,    // Net position per market
    total_exposure_value: u64,          // Sum of |position| * price
    total_max_liability: u64,           // Sum of |position| * $1
}
```

### 5.3 LP Functions

```move
/// LP deposits USDC, receives shares
public fun deposit(
    vault: &mut Vault,
    usdc: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
): VaultShare

/// LP withdraws shares for USDC (after lockup period)
public fun withdraw(
    vault: &mut Vault,
    share: VaultShare,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```

### 5.4 Share Value

```
share_value = vault_balance / total_shares

// As vault profits from spreads and settlements:
// - vault_balance increases
// - total_shares stays constant
// - share_value automatically increases
```

### 5.5 Withdrawal Lockup

| Parameter | Value |
|-----------|-------|
| Minimum lockup | 24 hours after deposit |
| Reason | Prevents deposit-before-settlement attacks |

---

## 6. Risk Management

### 6.1 Capital Reservation

Binary options have bounded payoff: each contract pays $0 or $1.

```
max_liability_per_market = abs(net_position) * $1
total_max_liability = sum across all markets

Invariant: vault_balance >= total_max_liability
```

### 6.2 Position Limits

```move
public struct VaultConfig has store {
    max_single_trade_pct: u64,          // Default: 5% of available capital
    max_exposure_per_market_pct: u64,   // Default: 20% of vault capital
    max_total_exposure_pct: u64,        // Default: 80% of vault capital
    base_spread_bps: u64,               // Default: 100 (1%)
    max_spread_adjustment_bps: u64,     // Default: 200 (2%)
    oracle_staleness_threshold_ms: u64, // Default: 30000 (30s)
    min_lockup_ms: u64,                 // Default: 86400000 (24h)
}
```

**Per-Trade Limit:**
```
max_single_trade = min(
    vault_available_capital * max_single_trade_pct,
    market_max_position - current_exposure
)
```

**Per-Market Limit:**
```
max_exposure_per_market = vault_capital * max_exposure_per_market_pct
```

**Aggregate Limit:**
```
max_total_exposure = vault_capital * max_total_exposure_pct
```

### 6.3 Dynamic Spread Adjustment

Spread widens based on vault exposure to incentivize balanced flow:

```
exposure_ratio = net_exposure / max_exposure  // -1 to +1
base_spread = config.base_spread_bps
max_adjustment = config.max_spread_adjustment_bps

adjustment = exposure_ratio * max_adjustment

// If vault is long UP:
up_ask  = oracle_mid + base_spread + adjustment  // More expensive to buy
up_bid  = oracle_mid - base_spread + adjustment
down_ask = oracle_mid + base_spread - adjustment // Cheaper to buy (incentivized)
down_bid = oracle_mid - base_spread - adjustment
```

### 6.4 Circuit Breakers

| Trigger | Action |
|---------|--------|
| Oracle stale (> 30s) | Pause trading |
| Exposure > 90% of limit | Pause mints, allow redeems only |
| Utilization > 95% | Pause mints |
| Single market > 50% of total exposure | Widen spreads aggressively |

### 6.5 Settlement Reserve

```
reserved_for_settlement = sum(max_payout) for markets expiring within 24h
available_for_trading = vault_balance - reserved_for_settlement
```

---

## 7. Collateral Manager

### 7.1 Purpose

Enables capital-efficient spread positions by allowing users to mint positions using other positions as collateral (instead of USDC).

### 7.2 Collateral Rules

| Position Type | Collateral Rule |
|---------------|-----------------|
| UP positions | Lower strike UP can collateralize higher strike UP |
| DOWN positions | Higher strike DOWN can collateralize lower strike DOWN |
| Requirement | Same expiry required |

**Example:** 90k UP can back 91k UP (because 90k UP is always worth ≥ 91k UP)

### 7.3 Data Structures

```move
public struct CollateralManager has key {
    id: UID,
    records: Table<ID, CollateralRecord>,
}

public struct CollateralRecord has store {
    owner: address,
    collateral_market_id: MarketId,  // e.g., 90k UP
    minted_market_id: MarketId,      // e.g., 91k UP
    amount: u64,
    created_at: u64,
}
```

### 7.4 Functions

```move
/// Deposit a position as collateral to mint another position
public fun deposit_and_mint(
    manager: &mut CollateralManager,
    vault: &mut Vault,
    collateral: Coin<COLLATERAL_POSITION>,
    target_market_id: MarketId,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<TARGET_POSITION>, ID)  // Returns minted position + record ID

/// Unlock collateral by returning minted position
/// If minted position value = 0 (after expiry), no position required
public fun unlock(
    manager: &mut CollateralManager,
    vault: &Vault,
    oracle: &Oracle,
    record_id: ID,
    minted_position: Option<Coin<MINTED_POSITION>>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<COLLATERAL_POSITION>
```

### 7.5 Bull Spread Example

```
1. Mint 90k UP with $0.65 USDC
2. Deposit 90k UP as collateral → Mint 91k UP
3. Sell 91k UP for $0.55 USDC
   Net cost: $0.10

At Expiry (90k < BTC < 91k):
├─ 91k UP = $0 (worthless)
├─ 90k UP = $1 (winner)
├─ Unlock 90k UP for free (91k worthless, no return needed)
├─ Redeem 90k UP for $1
└─ Profit: $0.90

At Expiry (BTC > 91k):
├─ 91k UP = $1, 90k UP = $1
├─ Must acquire 91k UP ($1) to unlock collateral
├─ Unlock 90k UP, redeem for $1
└─ Net: $0, Loss: $0.10

At Expiry (BTC < 90k):
├─ Both worthless
├─ Unlock free, redeem for $0
└─ Loss: $0.10
```

---

## 8. Hedging Infrastructure

### 8.1 Approach

**Keeper-based hedging** - Off-chain keeper monitors vault exposure and executes hedges on external venues.

### 8.2 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VAULT                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Exposure Tracker                                    │    │
│  │  • net_delta: i64 (current directional exposure)    │    │
│  │  • hedge_threshold: u64 (when to signal hedge)      │    │
│  │  • current_hedge: i64 (existing hedge position)     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              │ emit HedgeNeeded event
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    KEEPER (Off-Chain)                        │
│  • Monitors HedgeNeeded events                              │
│  • Executes hedge on DeepBook spot / external perps         │
│  • Reports hedge execution back to vault                    │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              │ report_hedge()
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    HEDGE ACCOUNT                             │
│  • Holds spot positions (e.g., BTC)                         │
│  • Tracks hedge P&L                                         │
│  • P&L flows to vault at settlement                         │
└─────────────────────────────────────────────────────────────┘
```

### 8.3 Hedge Calculation

```
// Net delta exposure
net_delta = sum(position * delta) across all markets

where delta for binary option ≈ N'(d2) / (S * σ * √T)

// Trigger hedge when threshold exceeded
hedge_needed = abs(net_delta) - current_hedge
```

### 8.4 Keeper Functions

```move
/// Keeper capability for authorized hedging operations
public struct KeeperCap has key, store {
    id: UID,
}

/// Authorized keeper deposits hedge position
public fun deposit_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    spot_coin: Coin<BTC>,
    ctx: &mut TxContext,
)

/// Keeper withdraws hedge to rebalance
public fun withdraw_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<BTC>

/// Report hedge execution for tracking
public fun report_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    delta_hedged: i64,
    execution_price: u64,
)
```

---

## 9. Admin & Governance

### 9.1 Admin Capability

Single `AdminCap` held by existing multisig. No granular capabilities, no timelocks.

```move
public struct AdminCap has key, store {
    id: UID,
}
```

### 9.2 Admin Functions

**Market Management:**
```move
public fun create_market(
    admin: &AdminCap,
    vault: &mut Vault,
    underlying: TypeName,
    strike: u64,
    expiry: u64,
    ctx: &mut TxContext,
)
```

**Emergency Controls:**
```move
public fun pause_trading(admin: &AdminCap, vault: &mut Vault)
public fun unpause_trading(admin: &AdminCap, vault: &mut Vault)
public fun pause_withdrawals(admin: &AdminCap, vault: &mut Vault)
public fun unpause_withdrawals(admin: &AdminCap, vault: &mut Vault)
```

**Risk Parameter Updates:**
```move
public fun update_max_single_trade_pct(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_max_exposure_per_market_pct(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_max_total_exposure_pct(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_base_spread_bps(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_max_spread_adjustment_bps(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_oracle_staleness_threshold(admin: &AdminCap, vault: &mut Vault, value: u64)
public fun update_min_lockup(admin: &AdminCap, vault: &mut Vault, value: u64)
```

---

## 10. Events

All events are indexed for frontend and analytics.

### 10.1 Trading Events

```move
public struct PositionMinted has copy, drop {
    market_id: MarketId,
    trader: address,
    amount: u64,
    price: u64,
    usdc_paid: u64,
}

public struct PositionRedeemed has copy, drop {
    market_id: MarketId,
    trader: address,
    amount: u64,
    price: u64,
    usdc_received: u64,
    is_settlement: bool,
}
```

### 10.2 Vault Events

```move
public struct LiquidityDeposited has copy, drop {
    depositor: address,
    usdc_amount: u64,
    shares_minted: u64,
    share_value: u64,
}

public struct LiquidityWithdrawn has copy, drop {
    withdrawer: address,
    shares_burned: u64,
    usdc_received: u64,
    share_value: u64,
}
```

### 10.3 Market Events

```move
public struct MarketCreated has copy, drop {
    market_id: MarketId,
    underlying: TypeName,
    strike: u64,
    expiry: u64,
}

public struct MarketSettled has copy, drop {
    market_id: MarketId,
    settlement_price: u64,
    up_wins: bool,
}
```

### 10.4 Admin Events

```move
public struct TradingPaused has copy, drop {
    paused_by: address,
}

public struct TradingUnpaused has copy, drop {
    unpaused_by: address,
}

public struct WithdrawalsPaused has copy, drop {
    paused_by: address,
}

public struct WithdrawalsUnpaused has copy, drop {
    unpaused_by: address,
}

public struct RiskParameterUpdated has copy, drop {
    parameter: vector<u8>,
    old_value: u64,
    new_value: u64,
}
```

### 10.5 Collateral Events

```move
public struct CollateralDeposited has copy, drop {
    record_id: ID,
    owner: address,
    collateral_market_id: MarketId,
    minted_market_id: MarketId,
    amount: u64,
}

public struct CollateralUnlocked has copy, drop {
    record_id: ID,
    owner: address,
}
```

### 10.6 Hedging Events

```move
public struct HedgeNeeded has copy, drop {
    net_delta: i64,
    current_hedge: i64,
    hedge_needed: i64,
}

public struct HedgeReported has copy, drop {
    delta_hedged: i64,
    execution_price: u64,
}
```

---

## 11. User Flows

### 11.1 Trader: Simple Binary Bet

```
1. View available markets
   → get_markets() returns list of (strike, expiry, direction)

2. Get quote for desired position
   → get_quote(market_id) returns (bid, ask)

3. Mint position
   → mint(market_id, usdc_coin) returns position_coin
   → Pays ask price

4. Hold until expiry

5. Redeem after settlement
   → redeem(position_coin) returns usdc
   → Receives $1 (win) or $0 (lose)
```

### 11.2 Trader: Bull Spread (Capital Efficient)

```
1. Mint lower strike position
   → mint(90k_UP, $0.65) returns 90k_UP_coin

2. Use as collateral to mint higher strike
   → deposit_and_mint(90k_UP_coin, 91k_UP)
   → Returns (91k_UP_coin, record_id)

3. Sell higher strike for premium
   → redeem(91k_UP_coin) returns $0.55
   → Net cost: $0.10

4. Wait for expiry

5. Unlock collateral
   → unlock(record_id, None)
   → Returns 90k_UP_coin

6. Redeem collateral
   → redeem(90k_UP_coin) returns $1 (if 90k < BTC < 91k)
```

### 11.3 LP: Provide Liquidity

```
1. Deposit USDC
   → deposit(usdc_coin) returns vault_share

2. Share value increases as vault profits
   → share_value = vault_balance / total_shares

3. Withdraw after lockup (24h minimum)
   → withdraw(vault_share) returns usdc_coin
   → Amount > original if vault profitable
```

### 11.4 Secondary Market Trading

Position tokens are fungible and can be traded:

```
1. List on DeepBook CLOB
   → Create pool for POSITION / USDC pair

2. Trade on any AMM
   → Position tokens are standard Coin types

3. Arbitrage opportunities
   → If market price < vault bid: buy on market, redeem at vault
   → If market price > vault ask: mint at vault, sell on market
```

---

## 12. Implementation Phases

### Phase 1: MVP

| Component | Description |
|-----------|-------------|
| Core options contract | `mint()`, `redeem()`, `get_quote()` |
| Basic vault | `deposit()`, `withdraw()`, share accounting |
| Oracle integration | Block Scholes data structures, pricing |
| Simple exposure tracking | Net positions per market |
| Manual settlement | Admin triggers settlement price |
| Basic events | Trading and vault events |

### Phase 2: Risk Management

| Component | Description |
|-----------|-------------|
| Dynamic spread adjustment | Exposure-based spread widening |
| Position limits | Per-trade, per-market, aggregate limits |
| Circuit breakers | Auto-pause on threshold breach |
| Withdrawal delays | 24h lockup enforcement |
| Admin controls | Pause/unpause, parameter updates |

### Phase 3: Advanced Features

| Component | Description |
|-----------|-------------|
| Collateral manager | Position-as-collateral for spreads |
| Hedging infrastructure | Keeper integration, hedge tracking |
| Secondary market | DeepBook pool integration |
| Full event suite | All events for analytics |

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Binary Option** | Option paying fixed amount ($1) if condition met, $0 otherwise |
| **Strike Price** | Price threshold for the binary condition |
| **UP Position** | Pays $1 if price > strike at expiry |
| **DOWN Position** | Pays $1 if price < strike at expiry |
| **Vault** | Pool of LP capital acting as counterparty |
| **Spread** | Difference between bid and ask price |
| **Exposure** | Net directional risk of the vault |
| **Delta** | Sensitivity of option price to underlying price |
| **Collateral Position** | Using one position to back another (for spreads) |

---

## Appendix B: Related Code References

| Reference | Location |
|-----------|----------|
| DeepBook Margin Pool | `/packages/deepbook_margin/sources/margin_pool.move` |
| Margin State | `/packages/deepbook_margin/sources/margin_pool/margin_state.move` |
| Position Manager | `/packages/deepbook_margin/sources/margin_pool/position_manager.move` |

---

*Document Status: Approved for Implementation*
