# Derivatives Vault-Family Architecture Design

## Scope

This design assumes:

- binaries and vanilla options do **not** share one universal risk basis
- each derivative family has its own counterparty vault object and its own exposure model
- the shared layer is infrastructure: market identity, live market state, settlement, instrument key shapes, account core, registry, and vault accounting shell
- the family-specific layer is economics: exposure updates, pricing, MTM, max payout / margin, and user-facing trading flows

This is therefore **not** a single universal derivatives vault. It is a common protocol shape with multiple vault families.

Function signatures below are design-level Move signatures. They are intended to fix module boundaries and object ownership, not to be copy-pasted as final code.

## Package Layout

```text
packages/
  derivatives_core/
    sources/
      registry.move
      market.move
      market_state.move
      settlement.move
      instrument.move
      accounts.move
      vault_core.move

  binary_vault/
    sources/
      family.move
      portfolio.move
      exposure.move
      risk.move
      vault.move
      periphery.move

  vanilla_options_vault/
    sources/
      family.move
      portfolio.move
      exposure.move
      risk.move
      vault.move
      periphery.move
```

## Design Rules

- `Market` and `MarketState` are shared objects.
- Each vault family has its own shared `Vault` object type.
- User holdings live in family-specific `Portfolio` objects that embed a shared `AccountCore`.
- `instrument.move` is generalized at the core layer because the key shape can be shared.
- Economic meaning lives in family `risk.move` and `exposure.move`.
- `vault_core.move` is reusable code and reusable data shape, not a standalone universal shared vault object.

## Package: `packages/derivatives_core`

### Module: `registry.move`

Purpose: root protocol registry that links markets, market states, and vault instances.

```move
module derivatives_core::registry;

public struct AdminCap has key, store {
    id: UID,
}

public struct VaultRegistration has copy, drop, store {
    family: u8,
    market_id: ID,
    market_state_id: ID,
    vault_id: ID,
}

public struct Registry has key {
    id: UID,
    market_ids: vector<ID>,
    market_state_ids: vector<ID>,
    vaults: Table<ID, VaultRegistration>,
}

public fun init(ctx: &mut TxContext): (Registry, AdminCap);
public fun market_ids(registry: &Registry): vector<ID>;
public fun vault_registration(registry: &Registry, vault_id: ID): VaultRegistration;

public fun register_market(
    registry: &mut Registry,
    admin: &AdminCap,
    market: &Market,
    market_state: &MarketState,
);

public fun register_vault(
    registry: &mut Registry,
    admin: &AdminCap,
    family: u8,
    market: &Market,
    market_state: &MarketState,
    vault_id: ID,
);
```

### Module: `market.move`

Purpose: static market definition. This is the canonical shared object referenced by all vault families.

```move
module derivatives_core::market;

public struct Market has key {
    id: UID,
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    settlement_rule: SettlementRule,
    market_state_id: ID,
}

public fun create(
    underlying_asset: String,
    quote_asset: TypeName,
    expiry_ms: u64,
    settlement_rule: SettlementRule,
    market_state_id: ID,
    ctx: &mut TxContext,
): Market;

public fun id(market: &Market): ID;
public fun underlying_asset(market: &Market): &String;
public fun quote_asset(market: &Market): TypeName;
public fun expiry_ms(market: &Market): u64;
public fun market_state_id(market: &Market): ID;
public fun settlement_rule(market: &Market): &SettlementRule;

public fun assert_not_expired(market: &Market, clock: &Clock);
public fun assert_expired(market: &Market, clock: &Clock);
```

### Module: `market_state.move`

Purpose: hot mutable shared object that receives live pricing inputs and carries final settlement state.

```move
module derivatives_core::market_state;

public struct MarketUpdateCap has key, store {
    id: UID,
    market_id: ID,
}

public struct VolPoint has copy, drop, store {
    strike: u64,
    implied_vol: u64,
}

public struct SurfaceSnapshot has store {
    points: vector<VolPoint>,
    updated_at_ms: u64,
}

public struct PricingSnapshot has copy, drop, store {
    spot: u64,
    forward: u64,
    spot_updated_at_ms: u64,
    forward_updated_at_ms: u64,
}

public struct MarketState has key {
    id: UID,
    market_id: ID,
    spot: u64,
    forward: u64,
    surface: SurfaceSnapshot,
    spot_updated_at_ms: u64,
    forward_updated_at_ms: u64,
    settlement_state: SettlementState,
}

public fun create(
    market_id: ID,
    settlement_state: SettlementState,
    ctx: &mut TxContext,
): (MarketState, MarketUpdateCap);

public fun id(state: &MarketState): ID;
public fun market_id(state: &MarketState): ID;
public fun pricing_snapshot(state: &MarketState): PricingSnapshot;
public fun surface(state: &MarketState): &SurfaceSnapshot;
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

public fun update_surface(
    state: &mut MarketState,
    cap: &MarketUpdateCap,
    points: vector<VolPoint>,
    observed_at_ms: u64,
    clock: &Clock,
);
```

### Module: `settlement.move`

Purpose: define settlement rules and the settlement state machine. This module does not price products.

```move
module derivatives_core::settlement;

public struct SettlementCap has key, store {
    id: UID,
    market_id: ID,
}

public struct SettlementRule has copy, drop, store {
    method: u8,
    observation_time_ms: u64,
    fallback_method: u8,
    rounding_mode: u8,
}

public struct SettlementState has copy, drop, store {
    status: u8,
    proposed_value: Option<u64>,
    final_value: Option<u64>,
    observed_at_ms: u64,
    finalized_at_ms: u64,
}

public fun new_rule(
    method: u8,
    observation_time_ms: u64,
    fallback_method: u8,
    rounding_mode: u8,
): SettlementRule;

public fun create_cap(
    market_id: ID,
    ctx: &mut TxContext,
): SettlementCap;

public fun new_state(): SettlementState;
public fun is_finalized(state: &SettlementState): bool;
public fun final_value(state: &SettlementState): u64;

public fun propose_final_value(
    state: &mut SettlementState,
    cap: &SettlementCap,
    rule: &SettlementRule,
    value: u64,
    observed_at_ms: u64,
    clock: &Clock,
);

public fun finalize(
    state: &mut SettlementState,
    cap: &SettlementCap,
    rule: &SettlementRule,
    clock: &Clock,
);
```

### Module: `instrument.move`

Purpose: generalized instrument key shapes shared across vault families. Economic meaning comes from the family witness type and family risk module.

```move
module derivatives_core::instrument;

public struct SeriesKey<phantom Family> has copy, drop, store {
    market_id: ID,
    strike: u64,
    kind: u8,
}

public struct BandKey<phantom Family> has copy, drop, store {
    market_id: ID,
    lower_strike: u64,
    upper_strike: u64,
    kind: u8,
}

public fun new_series<Family>(
    market_id: ID,
    strike: u64,
    kind: u8,
): SeriesKey<Family>;

public fun new_band<Family>(
    market_id: ID,
    lower_strike: u64,
    upper_strike: u64,
    kind: u8,
): BandKey<Family>;

public fun market_id<Family>(key: &SeriesKey<Family>): ID;
public fun strike<Family>(key: &SeriesKey<Family>): u64;
public fun kind<Family>(key: &SeriesKey<Family>): u8;

public fun band_market_id<Family>(key: &BandKey<Family>): ID;
public fun lower_strike<Family>(key: &BandKey<Family>): u64;
public fun upper_strike<Family>(key: &BandKey<Family>): u64;
public fun band_kind<Family>(key: &BandKey<Family>): u8;
```

### Module: `accounts.move`

Purpose: reusable account shell for user-owned family portfolios. This is embedded inside family-specific portfolio objects.

```move
module derivatives_core::accounts;

public struct AccountCore has store {
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
}

public fun new(owner: address, ctx: &mut TxContext): AccountCore;
public fun owner(account: &AccountCore): address;
public fun balance<T>(account: &AccountCore): u64;

public fun deposit<T>(
    account: &mut AccountCore,
    coin: Coin<T>,
    ctx: &TxContext,
);

public fun withdraw<T>(
    account: &mut AccountCore,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>;

public fun deposit_permissionless<T>(
    account: &mut AccountCore,
    coin: Coin<T>,
    ctx: &TxContext,
);
```

### Module: `vault_core.move`

Purpose: generic collateral, LP share, and solvency shell. Family vault objects embed this and pair it with family exposure state.

```move
module derivatives_core::vault_core;

public struct RiskSnapshot has copy, drop, store {
    mtm: u64,
    max_payout: u64,
    margin_requirement: u64,
}

public struct VaultCore has store {
    balances: Bag,
    total_balance: u64,
    lp_supply: u64,
}

public fun new(ctx: &mut TxContext): VaultCore;
public fun total_balance(core: &VaultCore): u64;
public fun lp_supply(core: &VaultCore): u64;
public fun vault_value(core: &VaultCore, risk: &RiskSnapshot): u64;
public fun available_to_withdraw(core: &VaultCore, risk: &RiskSnapshot): u64;

public fun accept_payment<T>(
    core: &mut VaultCore,
    payment: Balance<T>,
);

public fun dispense_payout<T>(
    core: &mut VaultCore,
    amount: u64,
): Balance<T>;

public fun mint_lp_shares(
    core: &mut VaultCore,
    deposit_amount: u64,
    risk: &RiskSnapshot,
): u64;

public fun burn_lp_shares(
    core: &mut VaultCore,
    share_amount: u64,
    risk: &RiskSnapshot,
): u64;

public fun assert_solvent(
    core: &VaultCore,
    risk: &RiskSnapshot,
);
```

## Package: `packages/binary_vault`

### Module: `family.move`

Purpose: binary-family witness type and typed constructors for the generalized instrument keys.

```move
module binary_vault::family;

public struct BinaryFamily has drop, store {}

const KIND_UP: u8 = 0;
const KIND_DOWN: u8 = 1;
const BAND_KIND_RANGE: u8 = 0;

public fun up(
    market_id: ID,
    strike: u64,
): SeriesKey<BinaryFamily>;

public fun down(
    market_id: ID,
    strike: u64,
): SeriesKey<BinaryFamily>;

public fun range(
    market_id: ID,
    lower_strike: u64,
    upper_strike: u64,
): BandKey<BinaryFamily>;
```

### Module: `portfolio.move`

Purpose: user-owned shared portfolio object for the binary family.

```move
module binary_vault::portfolio;

public struct BinaryPortfolio has key {
    id: UID,
    account: AccountCore,
    series_positions: Table<SeriesKey<BinaryFamily>, u64>,
    band_positions: Table<BandKey<BinaryFamily>, u64>,
}

public fun create(ctx: &mut TxContext): BinaryPortfolio;

public fun owner(portfolio: &BinaryPortfolio): address;
public fun balance<T>(portfolio: &BinaryPortfolio): u64;
public fun series_position(
    portfolio: &BinaryPortfolio,
    key: SeriesKey<BinaryFamily>,
): u64;

public fun band_position(
    portfolio: &BinaryPortfolio,
    key: BandKey<BinaryFamily>,
): u64;

public fun deposit<T>(
    portfolio: &mut BinaryPortfolio,
    coin: Coin<T>,
    ctx: &TxContext,
);

public fun withdraw<T>(
    portfolio: &mut BinaryPortfolio,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>;

public(package) fun increase_series(
    portfolio: &mut BinaryPortfolio,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
);

public(package) fun decrease_series(
    portfolio: &mut BinaryPortfolio,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
);

public(package) fun increase_band(
    portfolio: &mut BinaryPortfolio,
    key: BandKey<BinaryFamily>,
    quantity: u64,
);

public(package) fun decrease_band(
    portfolio: &mut BinaryPortfolio,
    key: BandKey<BinaryFamily>,
    quantity: u64,
);

public(package) fun deposit_permissionless<T>(
    portfolio: &mut BinaryPortfolio,
    coin: Coin<T>,
    ctx: &TxContext,
);
```

### Module: `exposure.move`

Purpose: binary-family aggregate exposure representation. This is where the current strike-matrix style model belongs.

```move
module binary_vault::exposure;

public struct StrikeMatrix has store {
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    cached_mtm: u64,
    cached_max_payout: u64,
}

public struct BinaryExposure has store {
    books: Table<ID, StrikeMatrix>,
}

public fun new(ctx: &mut TxContext): BinaryExposure;

public fun init_market(
    exposure: &mut BinaryExposure,
    market_id: ID,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
);

public fun open_series(
    exposure: &mut BinaryExposure,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
);

public fun close_series(
    exposure: &mut BinaryExposure,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
);

public fun open_band(
    exposure: &mut BinaryExposure,
    key: BandKey<BinaryFamily>,
    quantity: u64,
);

public fun close_band(
    exposure: &mut BinaryExposure,
    key: BandKey<BinaryFamily>,
    quantity: u64,
);

public fun cached_mtm(
    exposure: &BinaryExposure,
    market_id: ID,
): u64;

public fun cached_max_payout(
    exposure: &BinaryExposure,
    market_id: ID,
): u64;
```

### Module: `risk.move`

Purpose: binary-family economics. This module defines quoting, MTM, settled payout, and total risk from `BinaryExposure`.

```move
module binary_vault::risk;

public struct BinaryPricingConfig has store {
    base_spread: u64,
    min_spread: u64,
    utilization_multiplier: u64,
    min_ask_price: u64,
    max_ask_price: u64,
}

public struct BinaryRiskConfig has store {
    max_total_exposure_pct: u64,
    mtm_freshness_ms: u64,
}

public struct BinaryQuote has copy, drop, store {
    ask: u64,
    bid: u64,
}

public fun new_pricing_config(): BinaryPricingConfig;
public fun new_risk_config(): BinaryRiskConfig;

public fun quote_series(
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    market: &Market,
    state: &MarketState,
    exposure: &BinaryExposure,
    pricing: &BinaryPricingConfig,
    core: &VaultCore,
    clock: &Clock,
): BinaryQuote;

public fun quote_band(
    key: BandKey<BinaryFamily>,
    quantity: u64,
    market: &Market,
    state: &MarketState,
    exposure: &BinaryExposure,
    pricing: &BinaryPricingConfig,
    core: &VaultCore,
    clock: &Clock,
): BinaryQuote;

public fun refresh_market_risk(
    exposure: &mut BinaryExposure,
    market: &Market,
    state: &MarketState,
    clock: &Clock,
);

public fun total_risk_snapshot(
    exposure: &BinaryExposure,
    risk_config: &BinaryRiskConfig,
): RiskSnapshot;

public fun settled_series_payout(
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    settlement: &SettlementState,
): u64;

public fun settled_band_payout(
    key: BandKey<BinaryFamily>,
    quantity: u64,
    settlement: &SettlementState,
): u64;
```

### Module: `vault.move`

Purpose: binary-family shared counterparty object. It embeds the shared vault shell and binary-family exposure state.

```move
module binary_vault::vault;

public struct BinaryVault has key {
    id: UID,
    market_id: ID,
    core: VaultCore,
    exposure: BinaryExposure,
    pricing_config: BinaryPricingConfig,
    risk_config: BinaryRiskConfig,
    trading_paused: bool,
}

public fun create(
    registry: &mut Registry,
    admin: &AdminCap,
    market: &Market,
    state: &MarketState,
    ctx: &mut TxContext,
): BinaryVault;

public fun id(vault: &BinaryVault): ID;
public fun market_id(vault: &BinaryVault): ID;
public fun trading_paused(vault: &BinaryVault): bool;
public fun current_risk(vault: &BinaryVault): RiskSnapshot;

public fun set_trading_paused(
    vault: &mut BinaryVault,
    admin: &AdminCap,
    paused: bool,
);

public fun set_pricing_config(
    vault: &mut BinaryVault,
    admin: &AdminCap,
    pricing: BinaryPricingConfig,
);

public fun set_risk_config(
    vault: &mut BinaryVault,
    admin: &AdminCap,
    risk: BinaryRiskConfig,
);

public fun refresh_risk(
    vault: &mut BinaryVault,
    market: &Market,
    state: &MarketState,
    clock: &Clock,
);
```

### Module: `periphery.move`

Purpose: binary-family public flows that orchestrate quote, fund transfer, position issuance, exposure update, and invariant checks.

```move
module binary_vault::periphery;

public fun preview_series(
    vault: &BinaryVault,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
): BinaryQuote;

public fun preview_band(
    vault: &BinaryVault,
    market: &Market,
    state: &MarketState,
    key: BandKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
): BinaryQuote;

public fun mint_series<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun redeem_series<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun mint_band<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    market: &Market,
    state: &MarketState,
    key: BandKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun redeem_band<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    market: &Market,
    state: &MarketState,
    key: BandKey<BinaryFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun settle_series_permissionless<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    state: &MarketState,
    key: SeriesKey<BinaryFamily>,
    quantity: u64,
    ctx: &mut TxContext,
);

public fun settle_band_permissionless<Quote>(
    vault: &mut BinaryVault,
    portfolio: &mut BinaryPortfolio,
    state: &MarketState,
    key: BandKey<BinaryFamily>,
    quantity: u64,
    ctx: &mut TxContext,
);

public fun supply_liquidity<Quote>(
    vault: &mut BinaryVault,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64;

public fun withdraw_liquidity<Quote>(
    vault: &mut BinaryVault,
    lp_shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote>;
```

## Package: `packages/vanilla_options_vault`

### Module: `family.move`

Purpose: vanilla-options-family witness type and typed constructors for shared series keys.

```move
module vanilla_options_vault::family;

public struct VanillaOptionsFamily has drop, store {}

const KIND_CALL: u8 = 0;
const KIND_PUT: u8 = 1;

public fun call(
    market_id: ID,
    strike: u64,
): SeriesKey<VanillaOptionsFamily>;

public fun put(
    market_id: ID,
    strike: u64,
): SeriesKey<VanillaOptionsFamily>;
```

### Module: `portfolio.move`

Purpose: user-owned shared portfolio object for the vanilla-options family.

```move
module vanilla_options_vault::portfolio;

public struct OptionsPortfolio has key {
    id: UID,
    account: AccountCore,
    series_positions: Table<SeriesKey<VanillaOptionsFamily>, u64>,
}

public fun create(ctx: &mut TxContext): OptionsPortfolio;

public fun owner(portfolio: &OptionsPortfolio): address;
public fun balance<T>(portfolio: &OptionsPortfolio): u64;
public fun series_position(
    portfolio: &OptionsPortfolio,
    key: SeriesKey<VanillaOptionsFamily>,
): u64;

public fun deposit<T>(
    portfolio: &mut OptionsPortfolio,
    coin: Coin<T>,
    ctx: &TxContext,
);

public fun withdraw<T>(
    portfolio: &mut OptionsPortfolio,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>;

public(package) fun increase_series(
    portfolio: &mut OptionsPortfolio,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
);

public(package) fun decrease_series(
    portfolio: &mut OptionsPortfolio,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
);

public(package) fun deposit_permissionless<T>(
    portfolio: &mut OptionsPortfolio,
    coin: Coin<T>,
    ctx: &TxContext,
);
```

### Module: `exposure.move`

Purpose: vanilla-options-family aggregate exposure model. This is deliberately separate from binaries because the risk basis is different.

```move
module vanilla_options_vault::exposure;

public struct OptionNode has copy, drop, store {
    strike: u64,
    net_calls: u64,
    net_puts: u64,
}

public struct OptionBook has store {
    nodes: Table<u64, OptionNode>,
    cached_mtm: u64,
    cached_max_payout: u64,
    cached_margin_requirement: u64,
}

public struct OptionsExposure has store {
    books: Table<ID, OptionBook>,
}

public fun new(ctx: &mut TxContext): OptionsExposure;

public fun init_market(
    exposure: &mut OptionsExposure,
    market_id: ID,
    ctx: &mut TxContext,
);

public fun open_series(
    exposure: &mut OptionsExposure,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
);

public fun close_series(
    exposure: &mut OptionsExposure,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
);

public fun cached_mtm(
    exposure: &OptionsExposure,
    market_id: ID,
): u64;

public fun cached_max_payout(
    exposure: &OptionsExposure,
    market_id: ID,
): u64;

public fun cached_margin_requirement(
    exposure: &OptionsExposure,
    market_id: ID,
): u64;
```

### Module: `risk.move`

Purpose: vanilla-options-family economics. This is where Black-Scholes/SVI-derived quoting and options-specific risk live.

```move
module vanilla_options_vault::risk;

public struct OptionsPricingConfig has store {
    spread_bps: u64,
    skew_multiplier: u64,
    utilization_multiplier: u64,
}

public struct OptionsRiskConfig has store {
    max_margin_to_balance_pct: u64,
    state_staleness_ms: u64,
}

public struct OptionsQuote has copy, drop, store {
    ask: u64,
    bid: u64,
}

public fun new_pricing_config(): OptionsPricingConfig;
public fun new_risk_config(): OptionsRiskConfig;

public fun quote_series(
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    market: &Market,
    state: &MarketState,
    exposure: &OptionsExposure,
    pricing: &OptionsPricingConfig,
    core: &VaultCore,
    clock: &Clock,
): OptionsQuote;

public fun refresh_market_risk(
    exposure: &mut OptionsExposure,
    market: &Market,
    state: &MarketState,
    clock: &Clock,
);

public fun total_risk_snapshot(
    exposure: &OptionsExposure,
    risk_config: &OptionsRiskConfig,
): RiskSnapshot;

public fun settled_series_payout(
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    settlement: &SettlementState,
): u64;
```

### Module: `vault.move`

Purpose: vanilla-options-family shared counterparty object. It reuses the shared vault shell but embeds the options-family exposure and config types.

```move
module vanilla_options_vault::vault;

public struct OptionsVault has key {
    id: UID,
    market_id: ID,
    core: VaultCore,
    exposure: OptionsExposure,
    pricing_config: OptionsPricingConfig,
    risk_config: OptionsRiskConfig,
    trading_paused: bool,
}

public fun create(
    registry: &mut Registry,
    admin: &AdminCap,
    market: &Market,
    state: &MarketState,
    ctx: &mut TxContext,
): OptionsVault;

public fun id(vault: &OptionsVault): ID;
public fun market_id(vault: &OptionsVault): ID;
public fun trading_paused(vault: &OptionsVault): bool;
public fun current_risk(vault: &OptionsVault): RiskSnapshot;

public fun set_trading_paused(
    vault: &mut OptionsVault,
    admin: &AdminCap,
    paused: bool,
);

public fun set_pricing_config(
    vault: &mut OptionsVault,
    admin: &AdminCap,
    pricing: OptionsPricingConfig,
);

public fun set_risk_config(
    vault: &mut OptionsVault,
    admin: &AdminCap,
    risk: OptionsRiskConfig,
);

public fun refresh_risk(
    vault: &mut OptionsVault,
    market: &Market,
    state: &MarketState,
    clock: &Clock,
);
```

### Module: `periphery.move`

Purpose: vanilla-options-family public flows that orchestrate quote, fund transfer, position issuance, exposure update, and invariant checks.

```move
module vanilla_options_vault::periphery;

public fun preview_series(
    vault: &OptionsVault,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    clock: &Clock,
): OptionsQuote;

public fun mint_series<Quote>(
    vault: &mut OptionsVault,
    portfolio: &mut OptionsPortfolio,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun redeem_series<Quote>(
    vault: &mut OptionsVault,
    portfolio: &mut OptionsPortfolio,
    market: &Market,
    state: &MarketState,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun settle_series_permissionless<Quote>(
    vault: &mut OptionsVault,
    portfolio: &mut OptionsPortfolio,
    state: &MarketState,
    key: SeriesKey<VanillaOptionsFamily>,
    quantity: u64,
    ctx: &mut TxContext,
);

public fun supply_liquidity<Quote>(
    vault: &mut OptionsVault,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64;

public fun withdraw_liquidity<Quote>(
    vault: &mut OptionsVault,
    lp_shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote>;
```

## Dependency Direction

```text
derivatives_core::market
derivatives_core::market_state
derivatives_core::settlement
derivatives_core::instrument
derivatives_core::accounts
derivatives_core::vault_core
        ↓
binary_vault::{family, portfolio, exposure, risk, vault, periphery}
vanilla_options_vault::{family, portfolio, exposure, risk, vault, periphery}
```

## Main Architectural Consequences

- The shared object that receives high-frequency oracle updates is `MarketState`.
- `Market` is the static identity object and points at `MarketState`.
- `SettlementState` lives in `MarketState`, but `settlement.move` owns the settlement state machine.
- `SeriesKey<Family>` is generalized in the core package because the key shape is reusable.
- Binaries and vanilla options do **not** share one `Vault` type, but they **do** share the embedded `VaultCore`.
- The main custom seam for each family is:
  - `family.move` for typed instrument constructors
  - `exposure.move` for how aggregate exposures are stored and updated
  - `risk.move` for how aggregate exposures are priced and risk-checked
  - `periphery.move` for public user flows

## Initial Recommendation

If this architecture is implemented incrementally:

1. extract `Market`, `MarketState`, `SettlementRule`, `SettlementState`, `VaultCore`, and generalized `SeriesKey`
2. migrate current `predict` into `binary_vault`
3. keep `vanilla_options_vault` as a spec-only package until the binary-family split feels correct

That sequence preserves the current product while isolating the shared kernel from the family-specific economics.
