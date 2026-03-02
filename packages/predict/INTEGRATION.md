# Predict Integration Guide

## Overview

Predict is a decentralized binary options protocol built on Sui. Users bet on whether an underlying asset's price will be above (UP) or below (DOWN) a given strike price at expiry.

**Core concepts:**

- **Binary options** — Each position pays out 1 DUSDC per contract if the outcome is correct, 0 otherwise.
- **Vault as counterparty** — A protocol-owned vault takes the opposite side of every trade. There is no peer-to-peer order matching.
- **SVI oracle pricing** — Prices are derived on-chain from a Stochastic Volatility Inspired (SVI) volatility surface fed by an off-chain oracle (Block Scholes). The SVI parameters allow computing implied volatility for any strike, which is then used with Black-Scholes to produce binary option prices.
- **PredictManager** — Each user creates a shared `PredictManager` object that holds their DUSDC balance and tracks all their positions.

## Network & Constants

Currently deployed on **Sui Testnet** only.

| Constant | Testnet Object ID |
|---|---|
| Predict Package | `0x01db8fc74ead463c7167f9c609af72e64ac4eeb0f6b9c05da17c16ad0fd348d0` |
| Predict Registry | `0xc30b84b73d64472c19f12bc5357273ddce6d76ef04116306808b022078080d0a` |
| Predict Object (shared) | `0x25970603328dd3a95a92596cac4d7baebae93f59fd4c51e95ebaae5540d94c8b` |
| Predict Admin Cap | `0x9ed9f87992ebf99e707f39105ba727bb33894a0e1c684810e1fb462f5d3e7d03` |
| Oracle ID (first) | `0xd1fa546d31733a6806374f004479a2c5b593c5912fe4a432729846cb9106ebba` |
| DUSDC Package | `0x2ff52f1b7cc2d7332cead8f6b812e1f017047e00e9ca843979d92f70aeca75b1` |
| DUSDC Treasury Cap | `0x02becc90ac3a62e7197693a6faef8126e50b79fa47f95cc375d19a551f3af9c5` |

**Type parameters:**

```
Underlying = 0x2::sui::SUI
Quote      = <DUSDC_PACKAGE>::dusdc::DUSDC
```

Use the `/oracles` API endpoint to discover all oracle IDs dynamically rather than hardcoding them.

## API Reference

Base URL: your deployment's predict-server address (e.g., `http://localhost:3000`).

All endpoints are **GET** only. Default limit is **100** when not specified.

### System Endpoints

#### `GET /health`

Health check. Returns `200 OK` with no body.

#### `GET /status`

Indexer pipeline health. Use this to detect staleness.

**Response:**

```json
{
  "status": "ok",
  "current_time_ms": 1709337600000,
  "pipelines": [
    {
      "pipeline": "predict_position_minted",
      "checkpoint_hi_inclusive": 12345,
      "timestamp_ms_hi_inclusive": 1709337590000,
      "epoch_hi_inclusive": 100,
      "time_lag_ms": 10000,
      "time_lag_seconds": 10
    }
  ]
}
```

If any pipeline's `time_lag_seconds` exceeds **30**, data may be stale.

#### `GET /config`

Current protocol configuration (pricing params, risk params, pause status).

**Response:**

```json
{
  "pricing": {
    "base_spread": 10000000,
    "max_skew_multiplier": 1000000000,
    "utilization_multiplier": 2000000000
  },
  "risk": {
    "max_total_exposure_pct": 800000000
  },
  "trading_paused": false
}
```

### Oracle Endpoints

#### `GET /oracles`

List all oracles with their lifecycle status.

**Response:**

```json
[
  {
    "oracle_id": "0x...",
    "oracle_cap_id": "0x...",
    "expiry": 1709337600000,
    "status": "active",
    "activated_at": 1709251200000,
    "settlement_price": null,
    "settled_at": null,
    "created_checkpoint": 1000
  }
]
```

Status values: `"created"`, `"active"`, `"settled"`.

#### `GET /oracles/:oracle_id/prices`

Historical spot and forward prices for an oracle.

| Query Param | Type | Description |
|---|---|---|
| `limit` | `i64` | Max rows (default 100) |
| `start_time` | `i64` | Filter: checkpoint_timestamp_ms >= value |
| `end_time` | `i64` | Filter: checkpoint_timestamp_ms <= value |

**Response:** array of `OraclePricesUpdatedRow`

```json
[
  {
    "event_digest": "...",
    "digest": "...",
    "sender": "0x...",
    "checkpoint": 12345,
    "checkpoint_timestamp_ms": 1709337600000,
    "package": "0x...",
    "oracle_id": "0x...",
    "spot": 95000000000,
    "forward": 95100000000,
    "onchain_timestamp": 1709337600000
  }
]
```

#### `GET /oracles/:oracle_id/prices/latest`

Most recent price update for an oracle. Same shape as a single `OraclePricesUpdatedRow`.

#### `GET /oracles/:oracle_id/svi`

Historical SVI parameter snapshots.

| Query Param | Type | Description |
|---|---|---|
| `limit` | `i64` | Max rows (default 100) |

**Response:** array of `OracleSviUpdatedRow`

```json
[
  {
    "event_digest": "...",
    "digest": "...",
    "sender": "0x...",
    "checkpoint": 12345,
    "checkpoint_timestamp_ms": 1709337600000,
    "package": "0x...",
    "oracle_id": "0x...",
    "a": 40000000,
    "b": 300000000,
    "rho": 250000000,
    "rho_negative": true,
    "m": 50000000,
    "m_negative": false,
    "sigma": 200000000,
    "risk_free_rate": 50000000,
    "onchain_timestamp": 1709337600000
  }
]
```

#### `GET /oracles/:oracle_id/svi/latest`

Most recent SVI parameters. Same shape as a single `OracleSviUpdatedRow`.

### Trading Endpoints

#### `GET /positions/minted`

Query minted (bought) positions.

| Query Param | Type | Description |
|---|---|---|
| `oracle_id` | `String` | Filter by oracle |
| `trader` | `String` | Filter by trader address |
| `manager_id` | `String` | Filter by manager ID |
| `limit` | `i64` | Max rows (default 100) |

**Response:** array of `PositionMintedRow`

```json
[
  {
    "event_digest": "...",
    "digest": "...",
    "sender": "0x...",
    "checkpoint": 12345,
    "checkpoint_timestamp_ms": 1709337600000,
    "package": "0x...",
    "predict_id": "0x...",
    "manager_id": "0x...",
    "trader": "0x...",
    "oracle_id": "0x...",
    "expiry": 1709337600000,
    "strike": 95000000000,
    "is_up": true,
    "quantity": 1000000,
    "cost": 550000,
    "ask_price": 550000000
  }
]
```

#### `GET /positions/redeemed`

Query redeemed (sold/settled) positions. Same filters as `/positions/minted`.

**Response:** array of `PositionRedeemedRow`

```json
[
  {
    "event_digest": "...",
    "digest": "...",
    "sender": "0x...",
    "checkpoint": 12345,
    "checkpoint_timestamp_ms": 1709337600000,
    "package": "0x...",
    "predict_id": "0x...",
    "manager_id": "0x...",
    "trader": "0x...",
    "oracle_id": "0x...",
    "expiry": 1709337600000,
    "strike": 95000000000,
    "is_up": true,
    "quantity": 1000000,
    "payout": 480000,
    "bid_price": 480000000,
    "is_settled": false
  }
]
```

#### `GET /positions/collateralized`

Query collateralized positions (minted using existing positions as collateral).

Same filters as `/positions/minted`.

**Response:**

```json
{
  "minted": [
    {
      "event_digest": "...",
      "predict_id": "0x...",
      "manager_id": "0x...",
      "trader": "0x...",
      "oracle_id": "0x...",
      "locked_expiry": 1709337600000,
      "locked_strike": 90000000000,
      "locked_is_up": true,
      "minted_expiry": 1709337600000,
      "minted_strike": 95000000000,
      "minted_is_up": true,
      "quantity": 1000000,
      "..."
    }
  ],
  "redeemed": []
}
```

#### `GET /trades/:oracle_id`

Combined trade feed (mints + redeems) for an oracle, sorted by checkpoint descending.

| Query Param | Type | Description |
|---|---|---|
| `limit` | `i64` | Max rows (default 100) |

**Response:** array of tagged union events

```json
[
  {
    "type": "mint",
    "event_digest": "...",
    "oracle_id": "0x...",
    "is_up": true,
    "quantity": 1000000,
    "cost": 550000,
    "ask_price": 550000000,
    "..."
  },
  {
    "type": "redeem",
    "event_digest": "...",
    "oracle_id": "0x...",
    "is_up": true,
    "quantity": 1000000,
    "payout": 480000,
    "bid_price": 480000000,
    "is_settled": false,
    "..."
  }
]
```

### User Endpoints

#### `GET /managers`

List all PredictManagers.

| Query Param | Type | Description |
|---|---|---|
| `owner` | `String` | Filter by owner address |

**Response:** array of `PredictManagerCreatedRow`

```json
[
  {
    "event_digest": "...",
    "digest": "...",
    "sender": "0x...",
    "checkpoint": 12345,
    "checkpoint_timestamp_ms": 1709337600000,
    "package": "0x...",
    "manager_id": "0x...",
    "owner": "0x..."
  }
]
```

#### `GET /managers/:manager_id/positions`

All minted and redeemed positions for a specific manager.

**Response:**

```json
{
  "minted": [ /* PositionMintedRow[] */ ],
  "redeemed": [ /* PositionRedeemedRow[] */ ]
}
```

### Vault Endpoint

#### `GET /vault/history`

Vault balance change history (admin deposits/withdrawals).

| Query Param | Type | Description |
|---|---|---|
| `limit` | `i64` | Max rows (default 100) |

**Response:** array of `AdminVaultBalanceChangedRow`

```json
[
  {
    "event_digest": "...",
    "predict_id": "0x...",
    "amount": 1000000000,
    "deposit": true,
    "..."
  }
]
```

## Scaling & Decoding

All numeric values from the API and on-chain use fixed-point integer encoding.

| Domain | Scaling | Example |
|---|---|---|
| **Prices / percentages** | `FLOAT_SCALING = 1e9` | `500_000_000` = 50%, `1_000_000_000` = 100% |
| **Quantities / costs / payouts** | DUSDC (6 decimals) | `1_000_000` = 1 contract = $1 |
| **Timestamps** | Milliseconds since epoch | `1709337600000` |
| **SVI parameters** (a, b, rho, m, sigma, risk_free_rate) | `FLOAT_SCALING = 1e9` | See SVI section below |
| **Strike / spot / forward prices** | `FLOAT_SCALING = 1e9` | `95_000_000_000` = $95 |

**Decoding examples (TypeScript):**

```typescript
const FLOAT_SCALING = 1_000_000_000;
const USDC_DECIMALS = 1_000_000;

// Price from API (e.g., ask_price)
const displayPrice = ask_price / FLOAT_SCALING;        // 0.55 = 55%

// Cost/payout (already in DUSDC base units)
const displayUSD = cost / USDC_DECIMALS;               // 0.55 = $0.55

// Strike price
const displayStrike = strike / FLOAT_SCALING;           // 95.0 = $95

// SVI parameter with sign
const displayRho = rho_negative ? -(rho / FLOAT_SCALING) : (rho / FLOAT_SCALING);
```

## Move Transaction Reference

All trading functions live in the `deepbook_predict::predict` module. Type parameters:

- `Underlying` = `0x2::sui::SUI`
- `Quote` = `<DUSDC_PACKAGE>::dusdc::DUSDC`

### `create_manager`

Create a new `PredictManager` (shared object). Call once per user.

```move
public fun create_manager(ctx: &mut TxContext): ID
```

**Arguments:** none (only `TxContext`).
**Returns:** the manager's object ID.

### `deposit` (on PredictManager)

Deposit DUSDC into a manager's balance. Must be called by the manager's owner.

```move
public fun deposit<T>(
    self: &mut PredictManager,
    coin: Coin<T>,
    ctx: &TxContext,
)
```

### `withdraw` (on PredictManager)

Withdraw DUSDC from a manager's balance.

```move
public fun withdraw<T>(
    self: &mut PredictManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>
```

### `get_trade_amounts`

Preview the cost to mint and payout to redeem for a given market and quantity. Read-only.

```move
public fun get_trade_amounts<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64)   // (mint_cost, redeem_payout)
```

### `mint`

Buy a position. Withdraws cost from the manager's DUSDC balance and records the position.

```move
public fun mint<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

**Aborts if:** trading is paused, oracle is stale (>30s), or risk limits exceeded.

### `redeem`

Sell a position or claim settlement payout. Deposits payout into the manager's balance.

```move
public fun redeem<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

After settlement, redeem pays out `FLOAT_SCALING` (100%) per contract for winning positions and `0` for losing positions.

### `mint_collateralized`

Mint a position using an existing position as collateral (no DUSDC cost). The locked position must have a more favorable strike:

- **UP collateral** (lower strike) -> **UP minted** (higher strike)
- **DOWN collateral** (higher strike) -> **DOWN minted** (lower strike)

```move
public fun mint_collateralized<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
    clock: &Clock,
)
```

### `redeem_collateralized`

Release a collateralized position, freeing the locked collateral.

```move
public fun redeem_collateralized<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
)
```

## MarketKey Construction

A `MarketKey` uniquely identifies a binary option position: `(oracle_id, expiry, strike, direction)`.

```move
// UP position
let key = market_key::up(oracle_id, expiry, strike);

// DOWN position
let key = market_key::down(oracle_id, expiry, strike);

// Generic constructor
let key = market_key::new(oracle_id, expiry, strike, is_up);
```

**In TypeScript** (Sui SDK `moveCall`):

```typescript
// Construct a MarketKey for an UP position
tx.moveCall({
  target: `${PREDICT_PACKAGE}::market_key::up`,
  arguments: [
    tx.pure.id(oracleId),       // oracle_id: ID
    tx.pure.u64(expiry),        // expiry: u64 (ms)
    tx.pure.u64(strike),        // strike: u64 (FLOAT_SCALING)
  ],
});
```

The `expiry` must match the oracle's expiry exactly. Use the `/oracles` endpoint to look up the correct expiry for each oracle.

## Frontend Integration Flow

### 1. Create Manager (one-time)

```typescript
const tx = new Transaction();
tx.moveCall({
  target: `${PREDICT_PACKAGE}::predict::create_manager`,
});
// Execute and store the manager_id from events
```

Verify creation via `GET /managers?owner=<address>`.

### 2. Deposit DUSDC

```typescript
const tx = new Transaction();
const [coin] = tx.splitCoins(tx.gas, [depositAmount]);  // or use existing DUSDC coin
tx.moveCall({
  target: `${PREDICT_PACKAGE}::predict_manager::deposit`,
  typeArguments: [DUSDC_TYPE],
  arguments: [tx.object(managerId), coin],
});
```

### 3. Preview Trade

Call `get_trade_amounts` in a dev-inspect transaction (read-only, no gas):

```typescript
const tx = new Transaction();
const key = tx.moveCall({
  target: `${PREDICT_PACKAGE}::market_key::new`,
  arguments: [
    tx.pure.id(oracleId),
    tx.pure.u64(expiry),
    tx.pure.u64(strike),
    tx.pure.bool(isUp),
  ],
});
tx.moveCall({
  target: `${PREDICT_PACKAGE}::predict::get_trade_amounts`,
  typeArguments: [UNDERLYING_TYPE, DUSDC_TYPE],
  arguments: [
    tx.object(predictObjectId),
    tx.object(oracleId),
    key,
    tx.pure.u64(quantity),
    tx.object.clock(),
  ],
});
// Use client.devInspectTransactionBlock() to read return values
```

### 4. Mint (Buy Position)

```typescript
const tx = new Transaction();
const key = tx.moveCall({
  target: `${PREDICT_PACKAGE}::market_key::new`,
  arguments: [
    tx.pure.id(oracleId),
    tx.pure.u64(expiry),
    tx.pure.u64(strike),
    tx.pure.bool(isUp),
  ],
});
tx.moveCall({
  target: `${PREDICT_PACKAGE}::predict::mint`,
  typeArguments: [UNDERLYING_TYPE, DUSDC_TYPE],
  arguments: [
    tx.object(predictObjectId),
    tx.object(managerId),
    tx.object(oracleId),
    key,
    tx.pure.u64(quantity),
    tx.object.clock(),
  ],
});
```

### 5. Monitor Position

Poll positions via the API:

```typescript
// All positions for a manager
const res = await fetch(`${API_URL}/managers/${managerId}/positions`);
const { minted, redeemed } = await res.json();

// Or filter by oracle
const res = await fetch(`${API_URL}/positions/minted?manager_id=${managerId}&oracle_id=${oracleId}`);
```

### 6. Redeem (Sell or Claim Settlement)

Same structure as mint, but uses `predict::redeem`. Works both before and after settlement.

### 7. Withdraw DUSDC

```typescript
const tx = new Transaction();
const coin = tx.moveCall({
  target: `${PREDICT_PACKAGE}::predict_manager::withdraw`,
  typeArguments: [DUSDC_TYPE],
  arguments: [tx.object(managerId), tx.pure.u64(amount)],
});
tx.transferObjects([coin], tx.pure.address(recipientAddress));
```

## Polling & Monitoring

### Recommended Refresh Intervals

| Data | Interval | Endpoint |
|---|---|---|
| Oracle prices (spot/forward) | 1-2s | `/oracles/:id/prices/latest` |
| SVI parameters | 10-20s | `/oracles/:id/svi/latest` |
| Trade feed | 3-5s | `/trades/:oracle_id` |
| User positions | 5-10s | `/managers/:id/positions` |
| Indexer health | 30s | `/status` |
| Protocol config | 60s | `/config` |

### Staleness Detection

The oracle enforces a **30-second staleness threshold** on-chain. If the oracle hasn't been updated in >30s, `mint` transactions will abort with `EOracleStale (error code 1)`.

Use `/status` to check indexer lag. If any pipeline's `time_lag_seconds > 30`, displayed data may not reflect the latest on-chain state. Show a warning to users in this case.

### Oracle Lifecycle

1. **Created** — Oracle exists but is not yet accepting trades.
2. **Active** — Oracle is live; prices and SVI are being pushed; trading is open.
3. **Settled** — Past expiry; settlement price is frozen; users can only redeem. Winners get `1_000_000` per contract (1 DUSDC), losers get `0`.

Check `GET /oracles` and filter by `status` to show relevant markets.
