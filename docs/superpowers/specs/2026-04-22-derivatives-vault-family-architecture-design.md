# General Expiry Derivatives Protocol Design

Goal: keep `market_data` and `vault` stable, then add product families by upgrading only `orchestration`.

Core rule:

- `market_data` defines the generic market shell, settlement, and typed update authorization
- `vault` defines the generic portfolio, vault, and normalized risk shell
- `orchestration` defines product-specific market-data structs, instruments, engine state, and the adapter functions that turn them into vault-relevant outputs

`<T>` is the family/data-shape witness. For binaries, `T = Binary`. For a later vanilla options launch, `T = Vanilla`.

Function signatures below are design-level Move signatures. They are for boundaries, not final code.

## Packages

```text
packages/
  market_data/
    sources/
      market.move
      update.move
      settlement.move

  vault/
    sources/
      instrument.move
      portfolio.move
      risk.move
      vault.move

  orchestration/
    sources/
      registry.move
      binary_family.move
      binary_data.move
      binary_instrument.move
      binary_state.move
      binary_engine.move
      binary_router.move
```

## Dependency Direction

```text
market_data -> generic market shell
vault       -> generic balance-sheet shell
orchestration -> product meaning
```

`orchestration` defines a new data struct, creates an instance of it, wraps it in a typed `DataHandle<T>`, and asks `market_data` to create `Market<T>` bound to that data shape.

For each family `T`, `orchestration` owns the effective adapter contract:

- `quote`
- `open_effects`
- `close_effects`
- `refresh_risk`
- `settled_payout`

Core `vault` code consumes only normalized outputs from that adapter.

## Package: `market_data`

### `update.move`

Typed handle + cap for product-defined market-data state.

```move
module market_data::update;

public struct DataHandle<phantom T> has copy, drop, store {
    id: ID,
}

public struct UpdateCap<phantom T> has key, store {
    id: UID,
    market_id: ID,
    data_id: ID,
}

public fun new_handle<T>(id: ID): DataHandle<T>;
public fun id<T>(handle: &DataHandle<T>): ID;

public fun market_id<T>(cap: &UpdateCap<T>): ID;
public fun data_id<T>(cap: &UpdateCap<T>): ID;
```

### `settlement.move`

Settlement is the only truly generic market-state shape in core.

```move
module market_data::settlement;

public struct SettlementCap has key, store {
    id: UID,
    market_id: ID,
}

public struct SettlementRule has copy, drop, store {
    method: u8,
    observation_time_ms: u64,
    fallback_method: u8,
}

public struct SettlementState has copy, drop, store {
    status: u8,
    final_value: Option<u64>,
    observed_at_ms: u64,
    finalized_at_ms: u64,
}

public fun new_rule(
    method: u8,
    observation_time_ms: u64,
    fallback_method: u8,
): SettlementRule;

public fun new_state(): SettlementState;
public fun is_finalized(state: &SettlementState): bool;
public fun final_value(state: &SettlementState): u64;

public fun finalize(
    state: &mut SettlementState,
    cap: &SettlementCap,
    rule: &SettlementRule,
    value: u64,
    observed_at_ms: u64,
    clock: &Clock,
);
```

### `market.move`

Core market object. It knows only market identity, settlement, and which typed external data object powers it.

```move
module market_data::market;

public struct Market<phantom T> has key {
    id: UID,
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    data: DataHandle<T>,
    settlement_rule: SettlementRule,
    settlement_state: SettlementState,
}

public fun create<T>(
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    data: DataHandle<T>,
    settlement_rule: SettlementRule,
    ctx: &mut TxContext,
): (Market<T>, UpdateCap<T>, SettlementCap);

public fun id<T>(market: &Market<T>): ID;
public fun expiry_ms<T>(market: &Market<T>): u64;
public fun data<T>(market: &Market<T>): DataHandle<T>;
public fun settlement_state<T>(market: &Market<T>): &SettlementState;

public fun assert_update_access<T>(
    market: &Market<T>,
    cap: &UpdateCap<T>,
);
```

## Package: `vault`

### `instrument.move`

Core vault code should only see opaque instrument ids.

```move
module vault::instrument;

public struct InstrumentId<phantom T> has copy, drop, store {
    id: ID,
}

public fun new<T>(id: ID): InstrumentId<T>;
public fun id<T>(instrument: &InstrumentId<T>): ID;
```

### `portfolio.move`

Generic user holdings object. Cash plus positions in opaque instruments.

```move
module vault::portfolio;

public struct Portfolio<phantom T> has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    positions: Table<InstrumentId<T>, i64>,
}

public fun create<T>(ctx: &mut TxContext): Portfolio<T>;

public fun owner<T>(portfolio: &Portfolio<T>): address;
public fun balance<T, CoinType>(portfolio: &Portfolio<T>): u64;
public fun position<T>(
    portfolio: &Portfolio<T>,
    instrument: InstrumentId<T>,
): i64;

public fun deposit<T, CoinType>(
    portfolio: &mut Portfolio<T>,
    coin: Coin<CoinType>,
    ctx: &TxContext,
);

public fun withdraw<T, CoinType>(
    portfolio: &mut Portfolio<T>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType>;

public fun add_position<T>(
    portfolio: &mut Portfolio<T>,
    instrument: InstrumentId<T>,
    delta: i64,
);

public fun deposit_permissionless<T, CoinType>(
    portfolio: &mut Portfolio<T>,
    coin: Coin<CoinType>,
    ctx: &TxContext,
);
```

### `risk.move`

Normalized outputs that core vault code understands.

```move
module vault::risk;

public struct RiskSnapshot has copy, drop, store {
    mtm: u64,
    max_payout: u64,
    margin_requirement: u64,
}

public struct RiskLimits has copy, drop, store {
    max_mtm_pct: u64,
    max_margin_pct: u64,
}

public struct TradeEffects has copy, drop, store {
    premium_in: u64,
    premium_out: u64,
    position_delta: i64,
    risk: RiskSnapshot,
}

public fun new_snapshot(
    mtm: u64,
    max_payout: u64,
    margin_requirement: u64,
): RiskSnapshot;

public fun new_limits(
    max_mtm_pct: u64,
    max_margin_pct: u64,
): RiskLimits;

public fun new_trade_effects(
    premium_in: u64,
    premium_out: u64,
    position_delta: i64,
    risk: RiskSnapshot,
): TradeEffects;
```

### `vault.move`

Generic counterparty shell. It caches normalized risk but does not know product pricing logic.

```move
module vault::vault;

public struct Vault<phantom T> has key {
    id: UID,
    market_id: ID,
    engine_state_id: ID,
    balances: Bag,
    total_balance: u64,
    lp_supply: u64,
    risk: RiskSnapshot,
    limits: RiskLimits,
    trading_paused: bool,
}

public fun create<T>(
    market_id: ID,
    engine_state_id: ID,
    limits: RiskLimits,
    ctx: &mut TxContext,
): Vault<T>;

public fun id<T>(vault: &Vault<T>): ID;
public fun market_id<T>(vault: &Vault<T>): ID;
public fun engine_state_id<T>(vault: &Vault<T>): ID;
public fun risk<T>(vault: &Vault<T>): RiskSnapshot;

public fun accept_payment<T, CoinType>(
    vault: &mut Vault<T>,
    payment: Balance<CoinType>,
);

public fun dispense_payout<T, CoinType>(
    vault: &mut Vault<T>,
    amount: u64,
): Balance<CoinType>;

public fun set_risk_snapshot<T>(
    vault: &mut Vault<T>,
    risk: RiskSnapshot,
);

public fun apply_trade_effects<T>(
    vault: &mut Vault<T>,
    effects: TradeEffects,
);

public fun assert_solvent<T>(vault: &Vault<T>);
public fun set_trading_paused<T>(vault: &mut Vault<T>, paused: bool);
```

## Package: `orchestration`

`orchestration` is where a new family is added.

### `registry.move`

Links markets, vaults, and engine state.

```move
module orchestration::registry;

public struct AdminCap has key, store {
    id: UID,
}

public struct Registry has key {
    id: UID,
    market_ids: vector<ID>,
    vault_ids: vector<ID>,
    engine_state_ids: vector<ID>,
}

public fun init(ctx: &mut TxContext): (Registry, AdminCap);

public fun register_binary(
    registry: &mut Registry,
    admin: &AdminCap,
    market: &Market<Binary>,
    vault: &Vault<Binary>,
    engine_state: &BinaryState,
);
```

### `binary_family.move`

Binary witness type.

```move
module orchestration::binary_family;

public struct Binary has drop, store {}
```

### `binary_data.move`

Binary-specific market data shape. This is where the current `OracleSVI`-style update surface belongs.

```move
module orchestration::binary_data;

public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
}

public struct BinaryMarketData has key {
    id: UID,
    spot: u64,
    basis: u64,
    svi: SVIParams,
    spot_timestamp_ms: u64,
    basis_timestamp_ms: u64,
    lazer_published_at_us: u64,
}

public fun create(
    ctx: &mut TxContext,
): (BinaryMarketData, DataHandle<Binary>);

public fun update_prices(
    market: &Market<Binary>,
    data: &mut BinaryMarketData,
    cap: &UpdateCap<Binary>,
    spot: u64,
    forward: u64,
    clock: &Clock,
);

public fun update_spot_from_lazer(
    market: &Market<Binary>,
    data: &mut BinaryMarketData,
    cap: &UpdateCap<Binary>,
    update: LazerUpdate,
    clock: &Clock,
);

public fun update_svi(
    market: &Market<Binary>,
    data: &mut BinaryMarketData,
    cap: &UpdateCap<Binary>,
    svi: SVIParams,
    clock: &Clock,
);
```

### `binary_instrument.move`

Binary-specific instrument definitions. Core vault code only sees `InstrumentId<Binary>`.

```move
module orchestration::binary_instrument;

public struct BinarySeries has key {
    id: UID,
    market_id: ID,
    strike: u64,
    kind: u8,
}

public struct BinaryRange has key {
    id: UID,
    market_id: ID,
    lower_strike: u64,
    upper_strike: u64,
}

public fun create_up(
    market_id: ID,
    strike: u64,
    ctx: &mut TxContext,
): (BinarySeries, InstrumentId<Binary>);

public fun create_down(
    market_id: ID,
    strike: u64,
    ctx: &mut TxContext,
): (BinarySeries, InstrumentId<Binary>);

public fun create_range(
    market_id: ID,
    lower_strike: u64,
    upper_strike: u64,
    ctx: &mut TxContext,
): (BinaryRange, InstrumentId<Binary>);
```

### `binary_state.move`

Binary-specific aggregate exposure state.

```move
module orchestration::binary_state;

public struct BinaryState has key {
    id: UID,
    market_id: ID,
}

public fun create(market_id: ID, ctx: &mut TxContext): BinaryState;
public fun id(state: &BinaryState): ID;
```

### `binary_engine.move`

Binary adapter: consumes `BinaryMarketData` + `BinaryState` and emits normalized outputs for core vault code.

```move
module orchestration::binary_engine;

public struct BinaryQuote has copy, drop, store {
    ask: u64,
    bid: u64,
}

public fun quote(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    state: &BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    vault: &Vault<Binary>,
    clock: &Clock,
): BinaryQuote;

public fun open_effects(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    vault: &Vault<Binary>,
    clock: &Clock,
): TradeEffects;

public fun close_effects(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    vault: &Vault<Binary>,
    clock: &Clock,
): TradeEffects;

public fun refresh_risk(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    state: &mut BinaryState,
    vault: &Vault<Binary>,
    clock: &Clock,
): RiskSnapshot;

public fun settled_payout(
    market: &Market<Binary>,
    instrument: InstrumentId<Binary>,
    quantity: u64,
): u64;
```

### `binary_router.move`

Public binary flows.

```move
module orchestration::binary_router;

public fun preview(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    vault: &Vault<Binary>,
    state: &BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
): BinaryQuote;

public fun mint<Quote>(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    vault: &mut Vault<Binary>,
    state: &mut BinaryState,
    portfolio: &mut Portfolio<Binary>,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun redeem<Quote>(
    market: &Market<Binary>,
    data: &BinaryMarketData,
    vault: &mut Vault<Binary>,
    state: &mut BinaryState,
    portfolio: &mut Portfolio<Binary>,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun settle_permissionless<Quote>(
    market: &Market<Binary>,
    vault: &mut Vault<Binary>,
    portfolio: &mut Portfolio<Binary>,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    ctx: &mut TxContext,
);
```

## Binary Launch Flow

1. In `orchestration`, define:
   - `Binary`
   - `BinaryMarketData`
   - binary instruments
   - `BinaryState`
   - binary engine/router
2. Create `BinaryMarketData`, getting `DataHandle<Binary>`.
3. Call `market_data::market::create<Binary>(...)` to create `Market<Binary>`.
4. Receive `UpdateCap<Binary>` from market creation.
5. Create `BinaryState`.
6. Create `Vault<Binary>` and `Portfolio<Binary>`.
7. Use `UpdateCap<Binary>` to authorize binary-specific market-data updates.

## Key Consequence

If new product families are added by upgrading only `orchestration`, then:

- `market_data` cannot hardcode product-specific fields like SVI or option-specific curves
- `vault` cannot hardcode product-specific payoff logic
- product-specific data shapes and update entrypoints must live in `orchestration`
- core packages only understand typed handles, shared shells, normalized risk, and normalized trade effects
