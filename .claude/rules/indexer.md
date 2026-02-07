---
paths:
  - "crates/server/**"
  - "crates/schema/**"
  - "crates/indexer/**"
---

# Indexer Development Rules

**Update this file** when you discover new indexer insights, performance issues, or debugging tips during sessions.

## Codebase Structure

- `crates/server/src/server.rs` - Route handlers and API endpoints
- `crates/server/src/reader.rs` - Database query functions
- `crates/schema/migrations/` - Diesel database migrations
- `crates/indexer/` - Indexer logic and OpenAPI spec

## Common Commands

- Build: `cargo build -p deepbook-server`
- Test: `cargo test -p deepbook-server`

## Performance-Critical Endpoints

### /ticker Endpoint (server.rs:659-734)
Heavy operations that can cause 504 timeouts:
1. `fetch_historical_volume()` called twice (base and quote) - scans 24h of `order_fills`
2. Complex DISTINCT ON query for last prices
3. No pagination or caching

### /summary Endpoint
Calls `/ticker` internally, so inherits all its performance issues.

## Database Query Patterns

### order_fills Table (Heaviest)
- Volume queries: filter by `pool_id` + `checkpoint_timestamp_ms` range
- Last price queries: DISTINCT ON with ORDER BY `pool_id`, `checkpoint_timestamp_ms DESC`
- Fill lookups: filter by `maker_balance_manager_id` or `taker_balance_manager_id`

### order_updates Table
- Order history: filter by `pool_id`, `status`, `balance_manager_id`

### balances Table
- Deposited assets: filter by `balance_manager_id`, `asset`, `deposit = true`

### collateral_events Table
- Event history: filter by `margin_manager_id`, `checkpoint_timestamp_ms` range

### margin_manager_state Table
- Manager lookups: filter/join by `deepbook_pool_id`

## Recommended Indices

These composite indices significantly improve query performance:

```sql
-- order_fills: volume and ticker queries
CREATE INDEX idx_order_fills_pool_id_checkpoint_timestamp_ms
    ON order_fills (pool_id, checkpoint_timestamp_ms);

CREATE INDEX idx_order_fills_pool_id_checkpoint_timestamp_ms_desc
    ON order_fills (pool_id, checkpoint_timestamp_ms DESC);

CREATE INDEX idx_order_fills_maker_balance_manager_id
    ON order_fills (maker_balance_manager_id);

CREATE INDEX idx_order_fills_taker_balance_manager_id
    ON order_fills (taker_balance_manager_id);

-- order_updates: order history
CREATE INDEX idx_order_updates_pool_id_status_balance_manager_id
    ON order_updates (pool_id, status, balance_manager_id);

-- balances: deposited assets (partial index)
CREATE INDEX idx_balances_balance_manager_id_asset_deposit
    ON balances (balance_manager_id, asset) WHERE deposit = true;

-- collateral_events: event history
CREATE INDEX idx_collateral_events_margin_manager_id_checkpoint_timestamp_ms
    ON collateral_events (margin_manager_id, checkpoint_timestamp_ms DESC);

-- margin_manager_state: joins
CREATE INDEX idx_margin_manager_state_deepbook_pool_id
    ON margin_manager_state (deepbook_pool_id);
```

## Diesel Migration Notes

- **Cannot use `CREATE INDEX CONCURRENTLY`** - Diesel migrations run inside a transaction
- Use `IF NOT EXISTS` for idempotent migrations
- For zero-downtime index creation on production:
  1. Run `CREATE INDEX CONCURRENTLY` manually via psql (outside transaction)
  2. Then run migration with `IF NOT EXISTS` which will be a no-op

## Common Issues

### 504 Gateway Timeout
Usually caused by:
1. Missing composite indices on `order_fills`
2. Large time range queries (24h default)
3. Sequential queries that could be parallelized

### TransactionExpiration Enum Error
SDK v2.1.0+ uses `ValidDuring` (enum value 2) by default. Older tools may not recognize it.
Fix: Set explicit epoch-based expiration before building transaction:
```typescript
const { epoch } = await client.getLatestSuiSystemState();
tx.setExpiration({ Epoch: Number(epoch) + 5 });
```

### PostgreSQL Function Type Mismatch
PostgreSQL function matching requires **exact parameter types**. `TIMESTAMP` and `TIMESTAMP WITH TIME ZONE` are different types.

`to_timestamp()` returns `TIMESTAMPTZ`, so if a function expects `TIMESTAMP`, you must cast:
```sql
-- Wrong: function get_ohclv(text, text, timestamptz, ...) does not exist
to_timestamp($3)

-- Correct: cast to match function signature
to_timestamp($3)::timestamp
```

### Default Limit of 1
The `ParameterUtil` trait (`server.rs:1893-1897`) defaults to `limit=1` when not provided. This affects 24 endpoints:
- `order_updates`, `trades`, `margin_manager_created`, `loan_borrowed`, `loan_repaid`, `liquidation`, `asset_supplied`, `asset_withdrawn`, `deepbook_pool_updated`, `interest_params_updated`, `margin_pool_config_updated`, `maintainer_cap_updated`, `maintainer_fees_withdrawn`, `protocol_fees_withdrawn`, `supplier_cap_minted`, `supply_referral_minted`, `pause_cap_updated`, `protocol_fees_increased`, `referral_fees_claimed`, `referral_fee_events`, `deepbook_pool_registered`, `deepbook_pool_updated_registry`, `deepbook_pool_config_updated`, `collateral_events`

### No Pagination on /margin_manager_states
Returns ALL rows without limit. Can cause timeouts/memory issues with large tables.

## Connection Pools

The server creates **3 separate connection pools**:
1. **Reader** (`server.rs:151`) - API read queries
2. **Writer** (`server.rs:158`) - Admin writes
3. **margin_db** (`server.rs:286`) - Margin poller

Each pool has its own connections. Monitor total connections if experiencing pool exhaustion.
