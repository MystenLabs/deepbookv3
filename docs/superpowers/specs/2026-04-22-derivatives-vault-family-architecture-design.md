# General Expiry Derivatives Protocol Design

Goal: deploy stable core packages for expiry-based derivatives, then add product families like binaries by upgrading only `orchestration`.

Core rule:

- `market_data` is product-agnostic market truth
- `vault` is product-agnostic balance-sheet state
- `orchestration` defines product meaning, engine state, and public flows

Function signatures below are design-level Move signatures. They are for boundaries, not final code.

## Packages

```text
packages/
  market_data/
    sources/
      market.move
      market_state.move
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
      binary_instrument.move
      binary_state.move
      binary_engine.move
      binary_router.move
```

Future families like vanilla options would be added to `orchestration` with the same shape as the binary modules.

## Dependency Direction

```text
market_data -> canonical market + settlement state
vault       -> canonical portfolio + vault state
orchestration -> product semantics and entrypoints
```

`orchestration` reads `market_data`, mutates `vault`, owns product-specific engine state, and writes normalized `RiskSnapshot` back into core vault state.

## Package: `market_data`

### `market.move`

Static market definition shared by all product families.

```move
module market_data::market;

public struct Market has key {
    id: UID,
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    market_state_id: ID,
    settlement_rule: SettlementRule,
}

public fun create(
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    market_state_id: ID,
    settlement_rule: SettlementRule,
    ctx: &mut TxContext,
): Market;

public fun id(market: &Market): ID;
public fun expiry_ms(market: &Market): u64;
public fun market_state_id(market: &Market): ID;
public fun settlement_rule(market: &Market): &SettlementRule;
```

### `market_state.move`

Hot mutable state for a market. This is what gets updated by price publishers.

```move
module market_data::market_state;

public struct MarketUpdateCap has key, store {
    id: UID,
    market_id: ID,
}

public struct VolPoint has copy, drop, store {
    strike: u64,
    implied_vol: u64,
}

public struct MarketState has key {
    id: UID,
    market_id: ID,
    spot: u64,
    forward: u64,
    vol_surface: vector<VolPoint>,
    spot_updated_at_ms: u64,
    forward_updated_at_ms: u64,
    vol_updated_at_ms: u64,
    settlement_state: SettlementState,
}

public fun create(
    market_id: ID,
    settlement_state: SettlementState,
    ctx: &mut TxContext,
): (MarketState, MarketUpdateCap);

public fun id(state: &MarketState): ID;
public fun market_id(state: &MarketState): ID;
public fun settlement_state(state: &MarketState): &SettlementState;

public fun update_spot(
    state: &mut MarketState,
    cap: &MarketUpdateCap,
    spot: u64,
    observed_at_ms: u64,
    clock: &Clock,
);

public fun update_forward(
    state: &mut MarketState,
    cap: &MarketUpdateCap,
    forward: u64,
    observed_at_ms: u64,
    clock: &Clock,
);

public fun update_vol_surface(
    state: &mut MarketState,
    cap: &MarketUpdateCap,
    vol_surface: vector<VolPoint>,
    observed_at_ms: u64,
    clock: &Clock,
);
```

### `settlement.move`

Settlement rule and finalization state machine. This package does not price products.

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
public fun create_cap(market_id: ID, ctx: &mut TxContext): SettlementCap;
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

## Package: `vault`

### `instrument.move`

Core instrument handle. Core vault code should know only opaque instrument ids, not strikes or payoff semantics.

```move
module vault::instrument;

public struct InstrumentId<phantom Family> has copy, drop, store {
    id: ID,
}

public fun new<Family>(id: ID): InstrumentId<Family>;
public fun id<Family>(instrument: &InstrumentId<Family>): ID;
```

### `portfolio.move`

Generic user portfolio: cash plus quantities of opaque instruments.

```move
module vault::portfolio;

public struct Portfolio<phantom Family> has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    positions: Table<InstrumentId<Family>, i64>,
}

public fun create<Family>(ctx: &mut TxContext): Portfolio<Family>;

public fun owner<Family>(portfolio: &Portfolio<Family>): address;
public fun balance<Family, CoinType>(portfolio: &Portfolio<Family>): u64;
public fun position<Family>(
    portfolio: &Portfolio<Family>,
    instrument: InstrumentId<Family>,
): i64;

public fun deposit<Family, CoinType>(
    portfolio: &mut Portfolio<Family>,
    coin: Coin<CoinType>,
    ctx: &TxContext,
);

public fun withdraw<Family, CoinType>(
    portfolio: &mut Portfolio<Family>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType>;

public fun add_position<Family>(
    portfolio: &mut Portfolio<Family>,
    instrument: InstrumentId<Family>,
    delta: i64,
);

public fun deposit_permissionless<Family, CoinType>(
    portfolio: &mut Portfolio<Family>,
    coin: Coin<CoinType>,
    ctx: &TxContext,
);
```

### `risk.move`

Normalized risk language understood by core vault code.

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

public fun new_snapshot(
    mtm: u64,
    max_payout: u64,
    margin_requirement: u64,
): RiskSnapshot;

public fun new_limits(
    max_mtm_pct: u64,
    max_margin_pct: u64,
): RiskLimits;
```

### `vault.move`

Generic counterparty shell. It holds collateral and cached normalized risk. It does not know product payoff logic.

```move
module vault::vault;

public struct Vault<phantom Family> has key {
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

public fun create<Family>(
    market_id: ID,
    engine_state_id: ID,
    limits: RiskLimits,
    ctx: &mut TxContext,
): Vault<Family>;

public fun id<Family>(vault: &Vault<Family>): ID;
public fun market_id<Family>(vault: &Vault<Family>): ID;
public fun engine_state_id<Family>(vault: &Vault<Family>): ID;
public fun risk<Family>(vault: &Vault<Family>): RiskSnapshot;

public fun accept_payment<Family, CoinType>(
    vault: &mut Vault<Family>,
    payment: Balance<CoinType>,
);

public fun dispense_payout<Family, CoinType>(
    vault: &mut Vault<Family>,
    amount: u64,
): Balance<CoinType>;

public fun set_risk_snapshot<Family>(
    vault: &mut Vault<Family>,
    risk: RiskSnapshot,
);

public fun assert_solvent<Family>(vault: &Vault<Family>);

public fun set_trading_paused<Family>(
    vault: &mut Vault<Family>,
    paused: bool,
);
```

## Package: `orchestration`

This package owns product families. Launching binaries means adding modules here and reusing `market_data` + `vault` unchanged.

### `registry.move`

Links markets, vaults, and product engine state.

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

public fun register_market(
    registry: &mut Registry,
    admin: &AdminCap,
    market: &Market,
    market_state: &MarketState,
);

public fun register_binary_vault(
    registry: &mut Registry,
    admin: &AdminCap,
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
    // strike-matrix style aggregate exposure lives here
}

public fun create(market_id: ID, ctx: &mut TxContext): BinaryState;
public fun id(state: &BinaryState): ID;
```

### `binary_engine.move`

Binary product semantics: pricing, state updates, settlement payout, and risk projection into `RiskSnapshot`.

```move
module orchestration::binary_engine;

public struct BinaryQuote has copy, drop, store {
    ask: u64,
    bid: u64,
}

public fun quote(
    market: &Market,
    market_state: &MarketState,
    engine_state: &BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    vault: &Vault<Binary>,
    clock: &Clock,
): BinaryQuote;

public fun apply_open(
    engine_state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
);

public fun apply_close(
    engine_state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
);

public fun refresh_risk(
    market: &Market,
    market_state: &MarketState,
    engine_state: &mut BinaryState,
    vault: &Vault<Binary>,
    clock: &Clock,
): RiskSnapshot;

public fun settled_payout(
    market_state: &MarketState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
): u64;
```

### `binary_router.move`

Public binary flows. This is where user actions are orchestrated against core packages.

```move
module orchestration::binary_router;

public fun preview(
    vault: &Vault<Binary>,
    market: &Market,
    market_state: &MarketState,
    engine_state: &BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
): BinaryQuote;

public fun mint<Quote>(
    vault: &mut Vault<Binary>,
    portfolio: &mut Portfolio<Binary>,
    market: &Market,
    market_state: &MarketState,
    engine_state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun redeem<Quote>(
    vault: &mut Vault<Binary>,
    portfolio: &mut Portfolio<Binary>,
    market: &Market,
    market_state: &MarketState,
    engine_state: &mut BinaryState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun settle_permissionless<Quote>(
    vault: &mut Vault<Binary>,
    portfolio: &mut Portfolio<Binary>,
    market_state: &MarketState,
    instrument: InstrumentId<Binary>,
    quantity: u64,
    ctx: &mut TxContext,
);
```

## Binary Launch Flow

1. Deploy stable `market_data`.
2. Deploy stable `vault`.
3. Upgrade `orchestration` to add:
   - `Binary`
   - binary instrument structs
   - `BinaryState`
   - binary engine
   - binary router
4. Create:
   - `Market`
   - `MarketState`
   - `Vault<Binary>`
   - `Portfolio<Binary>`
   - binary instrument objects
   - `BinaryState`

## Key Consequence

If a new product family can be added by upgrading only `orchestration`, then:

- `market_data` cannot encode product semantics
- `vault` cannot encode product semantics
- product semantics must live entirely in `orchestration`
- core vault state can only consume normalized outputs like `RiskSnapshot`
