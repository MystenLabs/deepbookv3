# DeepBook Binary Options Protocol - Technical Design Document

*Draft v0.1 - January 2026*

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Oracle Design](#3-oracle-design)
4. [Core Options Contract](#4-core-options-contract)
5. [Collateral Manager](#5-collateral-manager)
6. [Counterparty Vault](#6-counterparty-vault)
7. [Risk Management](#7-risk-management)
8. [Hedging Infrastructure](#8-hedging-infrastructure)
9. [User Flows](#9-user-flows)
10. [Open Questions](#10-open-questions)

---

## 1. Overview

### 1.1 Product Description

A fully on-chain binary options protocol built as an extension to DeepBook. Users can bet on whether the price of an asset (e.g., BTC) will be above or below a strike price at expiration.

**Key Features:**
- Binary payoff: $1 if correct, $0 if incorrect
- Vault-based counterparty model (similar to HyperLiquid HLP)
- Oracle-driven pricing (Block Scholes volatility surface)
- Capital-efficient spreads via position-as-collateral
- Fully on-chain settlement

### 1.2 Inspiration

Inspired by Polymarket's binary prediction markets, but:
- **Fully on-chain** (not hybrid like Polymarket)
- **Vault-based counterparty** (not peer-to-peer order book)
- **Professional pricing** (Block Scholes oracle, not market-driven)

### 1.3 Key Actors

| Actor | Description |
|-------|-------------|
| **Trader** | Buys/sells binary options positions |
| **LP (Liquidity Provider)** | Deposits USDC into vault, earns yield from spreads |
| **Oracle (Block Scholes)** | Provides volatility surface data for pricing |
| **Keeper** | Executes hedging operations (off-chain) |
| **Admin** | Manages parameters, creates markets, emergency controls |

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

**Block Scholes** - Options pricing research firm that pushes data on-chain.

### 3.2 Update Frequency

- ~1 update per second (high frequency)
- One oracle per expiry (not per strike)
- Single oracle can price multiple strikes for same expiry

### 3.3 Oracle Data Structure

```move
public struct OracleData has store, drop {
    expiry: u64,                    // Expiration timestamp
    underlying: TypeName,           // e.g., BTC
    spot_price: u64,                // Current spot price (scaled)
    volatility_surface: vector<VolPoint>,  // IV at different strikes
    risk_free_rate: u64,            // For Black-Scholes calculation
    timestamp: u64,                 // When data was published
}

public struct VolPoint has store, drop, copy {
    strike: u64,
    implied_volatility: u64,        // IV at this strike (scaled)
}
```

### 3.4 Price Computation

Contract computes bid/ask using Black-Scholes for binary options:

```
Binary Call Price = e^(-rT) * N(d2)
Binary Put Price = e^(-rT) * N(-d2)

where:
d2 = [ln(S/K) + (r - 0.5*σ²)*T] / (σ*√T)

S = spot price
K = strike price
r = risk-free rate
σ = implied volatility (from oracle surface)
T = time to expiry
```

### 3.5 Staleness & Fallback

- Oracle data considered stale if `now - timestamp > 30 seconds`
- If stale: pause trading, allow only redemptions
- No fallback oracle initially (can add Pyth/Chainlink later)

---

## 4. Core Options Contract

### 4.1 Market Structure

Each market is defined by:
- **Underlying asset** (e.g., BTC)
- **Strike price** (e.g., $90,000)
- **Expiry timestamp** (e.g., tomorrow 00:00 UTC)
- **Direction** (UP = above strike, DOWN = below strike)

UP and DOWN are inverses: `UP_price + DOWN_price = $1`

### 4.2 Market Lifecycle

```
Day 0:
  - Create 5 markets for Day 1 expiry (strikes around current price)
  - Markets tradeable for ~36 hours

Day 1:
  - Create 5 markets for Day 2 expiry
  - Day 1 markets expire at 00:00 UTC
  - Settlement price determined
  - Users can claim positions

Day 2+:
  - Rolling cycle continues
```

### 4.3 Position Tokens

Positions are fungible tokens using Sui's dynamic coin creation:

```move
public struct MarketId has store, copy, drop {
    underlying: TypeName,
    strike: u64,
    expiry: u64,
    direction: u8,  // 0 = UP, 1 = DOWN
}

// Position is Coin<MarketId>
// Each (strike, expiry, direction) = unique coin type
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
): Coin<MarketId>

/// Redeem a position for USDC
/// Before expiry: receive bid price
/// After expiry: receive $1 (win) or $0 (lose)
public fun redeem(
    vault: &mut Vault,
    oracle: &Oracle,
    position: Coin<MarketId>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```

### 4.5 Settlement

- **Not auto-settle** - users must call `redeem()` to claim
- Settlement price from oracle at expiry timestamp
- Grace period for claims (e.g., 7 days)
- Unclaimed positions after grace period: funds go to vault

---

## 5. Collateral Manager

### 5.1 Purpose

Enables capital-efficient spread positions by allowing users to mint positions using other positions as collateral (instead of USDC).

### 5.2 Collateral Rules

For UP positions:
- Lower strike UP can collateralize higher strike UP
- (90k UP can back 91k UP, because 90k UP is always worth >= 91k UP)

For DOWN positions:
- Higher strike DOWN can collateralize lower strike DOWN
- (91k DOWN can back 90k DOWN)

Same expiry required.

### 5.3 Data Structures

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

### 5.4 Functions

```move
/// Deposit a position as collateral to mint another position
public fun deposit_and_mint(
    manager: &mut CollateralManager,
    vault: &mut Vault,
    collateral: Coin<CollateralMarketId>,
    target_market_id: MarketId,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<TargetMarketId>, ID)  // Returns minted position + record ID

/// Unlock collateral by returning minted position
/// If minted position value = 0 (after expiry), no position required
public fun unlock(
    manager: &mut CollateralManager,
    vault: &Vault,
    oracle: &Oracle,
    record_id: ID,
    minted_position: Option<Coin<MintedMarketId>>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CollateralMarketId>
```

### 5.5 Bull Spread Example

```
1. Mint 90k UP with $0.65 USDC
2. Deposit 90k UP → Mint 91k UP (Collateral Manager)
   - Record: {collateral: 90k_UP, minted: 91k_UP}
3. Sell 91k UP for $0.55 USDC
   - Net cost: $0.10, no positions held

At Expiry (90k < BTC < 91k):
- 91k UP = $0 (worthless)
- 90k UP = $1
- Unlock 90k UP for free (91k is worthless)
- Redeem 90k UP for $1
- Profit: $0.90

At Expiry (BTC > 91k):
- 91k UP = $1, 90k UP = $1
- Must acquire 91k UP ($1) to unlock
- Unlock 90k UP, redeem for $1
- Net: $0, Loss: $0.10

At Expiry (BTC < 90k):
- Both worthless
- Unlock free, redeem for $0
- Loss: $0.10
```

---

## 6. Counterparty Vault

### 6.1 Overview

Single vault that acts as counterparty to all trades. Similar to:
- HyperLiquid's HLP
- GMX's GLP

LPs deposit USDC, earn yield from spread capture and favorable settlements.

### 6.2 Share Accounting

Reuse pattern from DeepBook margin pool:

```move
public struct Vault has key {
    id: UID,
    balance: Balance<USDC>,         // Actual USDC in vault
    total_shares: u64,              // Total LP shares outstanding
    share_value_numerator: u64,     // For computing share value
    share_value_denominator: u64,
    exposure: ExposureTracker,      // Net positions per market
    config: VaultConfig,            // Limits, parameters
    // ...
}

// Share value = balance / total_shares (simplified)
// As vault profits, share value increases automatically
```

### 6.3 Deposit / Withdrawal

```move
/// LP deposits USDC, receives shares
public fun deposit(
    vault: &mut Vault,
    usdc: Coin<USDC>,
    ctx: &mut TxContext,
): VaultShare  // Receipt with share amount

/// LP withdraws shares for USDC
public fun withdraw(
    vault: &mut Vault,
    share: VaultShare,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```

### 6.4 Withdrawal Delay

**Decision: Include withdrawal delay**

- Minimum hold period: 24 hours after deposit
- Prevents deposit-before-settlement attacks
- Rate limiting (token bucket) for large withdrawals

```move
public struct VaultShare has key, store {
    id: UID,
    shares: u64,
    deposited_at: u64,  // Timestamp for lockup check
}

const MIN_LOCKUP_MS: u64 = 24 * 60 * 60 * 1000;  // 24 hours
```

### 6.5 Exposure Tracking

```move
public struct ExposureTracker has store {
    // Net position per market (positive = vault is long UP)
    positions: Table<MarketId, i64>,

    // Aggregate metrics
    total_exposure_value: u64,      // Sum of |position| * price
    total_max_liability: u64,       // Sum of |position| * $1
}
```

### 6.6 P&L Sources

1. **Spread Capture**: Difference between bid/ask on round trips
2. **Settlement**: When positions expire, vault keeps losing side's premium
3. **Time Decay**: As expiry approaches, OTM positions decay to vault's benefit

---

## 7. Risk Management

### 7.1 Capital Reservation

Binary options have bounded payoff: each contract pays $0 or $1.

```
max_liability_per_market = abs(net_position) * $1
total_max_liability = sum across all markets

Invariant: vault_balance >= total_max_liability
```

### 7.2 Position Limits

**Per-Trade Limit:**
```
max_single_trade = min(
    vault_available_capital * 5%,
    market_max_position - current_exposure
)
```

**Per-Market Limit:**
```
max_exposure_per_market = vault_capital * 20%
```

**Aggregate Limit:**
```
max_total_exposure = vault_capital * 80%
```

### 7.3 Spread Adjustment

Dynamic spread based on exposure:

```
exposure_ratio = net_exposure / max_exposure  // -1 to +1
base_spread = oracle_spread  // e.g., 1%
max_adjustment = 2%  // Configurable

adjustment = exposure_ratio * max_adjustment

// If vault is long UP:
up_ask = oracle_mid + base_spread + adjustment   // More expensive
up_bid = oracle_mid - base_spread + adjustment
down_ask = oracle_mid + base_spread - adjustment // Cheaper
down_bid = oracle_mid - base_spread - adjustment
```

### 7.4 Circuit Breakers

| Trigger | Action |
|---------|--------|
| Oracle stale (> 30s) | Pause trading |
| Exposure > 90% of limit | Pause mints, allow redeems only |
| Utilization > 95% | Pause mints |
| Single market > 50% of total exposure | Alert, widen spreads aggressively |

### 7.5 Settlement Risk

Reserve capital for expiring markets:

```
reserved_for_settlement = sum(max_payout) for markets expiring within 24h
available_for_trading = vault_balance - reserved_for_settlement
```

### 7.6 Configurable Parameters

All limits should be configurable via admin functions to allow adjustment based on collected data:

```move
public struct VaultConfig has store {
    max_single_trade_pct: u64,          // Default: 5%
    max_exposure_per_market_pct: u64,   // Default: 20%
    max_total_exposure_pct: u64,        // Default: 80%
    base_spread_bps: u64,               // Default: 100 (1%)
    max_spread_adjustment_bps: u64,     // Default: 200 (2%)
    oracle_staleness_threshold_ms: u64, // Default: 30000 (30s)
    min_lockup_ms: u64,                 // Default: 86400000 (24h)
}
```

---

## 8. Hedging Infrastructure

### 8.1 Design Decision

**Start with Keeper-Based Hedging (Option A)**

Design interface to allow adding automated on-chain hedging later.

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
                              │ deposit_hedge()
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
// Calculate net delta exposure
net_delta = sum(position * delta) across all markets

where delta for binary option ≈ N'(d2) / (S * σ * √T)

// Simplified: if net_delta > threshold, hedge with spot
hedge_needed = abs(net_delta) - current_hedge

// Keeper buys/sells spot to offset
```

### 8.4 Keeper Functions

```move
/// Authorized keeper deposits hedge position
public fun deposit_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    spot_coin: Coin<BTC>,  // Or other underlying
    ctx: &mut TxContext,
)

/// Keeper withdraws hedge to rebalance
public fun withdraw_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<BTC>

/// Report hedge execution (for tracking)
public fun report_hedge(
    vault: &mut Vault,
    keeper_cap: &KeeperCap,
    delta_hedged: i64,
    execution_price: u64,
)
```

### 8.5 Future: Automated On-Chain Hedging

Interface designed to allow adding:
```move
/// Anyone can call if hedge threshold exceeded
public fun auto_rebalance(
    vault: &mut Vault,
    deepbook_pool: &mut Pool<BTC, USDC>,
    oracle: &Oracle,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

---

## 9. User Flows

### 9.1 Trader: Simple Binary Bet

```
1. View available markets
   → get_markets() returns list of (strike, expiry, direction)

2. Get quote for desired position
   → get_quote(market_id) returns (bid, ask)

3. Mint position
   → mint(market_id, usdc_coin) returns position_coin
   → Pays ask price

4. Hold until expiry (or trade on secondary market)

5. Redeem after settlement
   → redeem(position_coin) returns usdc
   → Receives $1 (win) or $0 (lose)
```

### 9.2 Trader: Bull Spread

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
   → unlock(record_id, None)  // None because 91k worthless if in range
   → Returns 90k_UP_coin

6. Redeem collateral
   → redeem(90k_UP_coin) returns $1 (if 90k < BTC < 91k)
```

### 9.3 LP: Provide Liquidity

```
1. Deposit USDC
   → deposit(usdc_coin) returns vault_share

2. Share value increases as vault profits
   → Share value = vault_balance / total_shares

3. Withdraw after lockup (24h minimum)
   → withdraw(vault_share) returns usdc_coin
   → Amount > original deposit if vault profitable
```

### 9.4 Secondary Market Trading

Position tokens are fungible `Coin<MarketId>`:

```
1. List on DeepBook
   → Create pool for MarketId / USDC pair
   → Place limit orders

2. Trade on AMM
   → Position tokens can be swapped on any AMM

3. Arbitrage
   → If DeepBook price < vault bid: buy on DeepBook, redeem at vault
   → If DeepBook price > vault ask: mint at vault, sell on DeepBook
```

---

## 10. Open Questions

### 10.1 To Discuss Further

1. **Fee Structure**
   - Trading fees beyond spread?
   - Protocol fee on vault profits?
   - Fee distribution to different parties?

2. **Oracle Details**
   - Exact data format from Block Scholes
   - Integration method (push vs pull)
   - Backup oracle strategy

3. **Settlement Price**
   - Single point or TWAP?
   - Which oracle for settlement?
   - Dispute mechanism?

4. **Market Creation**
   - Who can create markets? (Admin only vs permissionless)
   - Strike selection algorithm
   - Minimum/maximum time to expiry

5. **Admin Operations**
   - Multi-sig requirements
   - Timelocks on parameter changes
   - Emergency shutdown procedure

6. **Events & Indexing**
   - What events to emit
   - Required data for frontend
   - Analytics requirements

7. **Upgradability**
   - How to upgrade contracts
   - Migration strategy for positions

### 10.2 Implementation Priorities

**Phase 1: MVP**
- Core options contract (mint/redeem)
- Basic vault (deposit/withdraw, share accounting)
- Oracle integration
- Simple exposure tracking
- Manual settlement

**Phase 2: Risk Management**
- Dynamic spread adjustment
- Position limits
- Circuit breakers
- Withdrawal delays

**Phase 3: Advanced Features**
- Collateral manager (spreads)
- Hedging infrastructure
- Secondary market integration
- Analytics dashboard

### 10.3 Data to Collect

For calibrating risk parameters:
- Trade volume by market
- Net exposure over time
- Settlement outcomes (vault win/loss rate)
- LP deposit/withdrawal patterns
- Spread effectiveness (are traders taking both sides?)

---

## Appendix A: Related Code References

### DeepBook Margin Pool (for vault accounting)
- `/packages/deepbook_margin/sources/margin_pool.move`
- `/packages/deepbook_margin/sources/margin_pool/margin_state.move`
- `/packages/deepbook_margin/sources/margin_pool/position_manager.move`

### Research
- `/research/defi-options-research.md` - DeFi options landscape research

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **Binary Option** | Option that pays fixed amount ($1) if condition met, $0 otherwise |
| **Strike Price** | Price threshold for the binary condition |
| **UP Position** | Pays $1 if price > strike at expiry |
| **DOWN Position** | Pays $1 if price < strike at expiry |
| **Vault** | Pool of LP capital that acts as counterparty |
| **Spread** | Difference between bid and ask price |
| **Exposure** | Net directional risk of the vault |
| **Delta** | Sensitivity of option price to underlying price |
| **Collateral Position** | Using one position to back another (for spreads) |

---

*Document Status: Draft - Pending review and completion of open questions*
