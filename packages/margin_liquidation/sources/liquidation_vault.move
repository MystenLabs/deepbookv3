// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_liquidation::liquidation_vault;

use deepbook::pool::Pool;
use deepbook_margin::{
    margin_manager::{MarginManager, liquidate},
    margin_manager_upgraded,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry
};
use pyth::price_info::PriceInfoObject;
use pyth_upgraded::price_info::PriceInfoObject as PriceInfoObjectUpgraded;
use sui::{
    bag::{Self, Bag},
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    dynamic_field as df,
    event,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists_ as UID.exists_;

// === Errors ===
const ENotEnoughBalanceInVault: u64 = 1;
const ETraderNotAuthorized: u64 = 2;

public struct LIQUIDATION_VAULT has drop {}

// === Structs ===
public struct LiquidationVault has key {
    id: UID,
    vault: Bag,
}

public struct BalanceKey<phantom T> has copy, drop, store {}

public struct AuthorizedTradersKey has copy, drop, store {}

// === Caps ===
public struct LiquidationAdminCap has key, store {
    id: UID,
}

// === Events ===
public struct LiquidationByVault has copy, drop {
    vault_id: ID,
    margin_manager_id: ID,
    margin_pool_id: ID,
    base_in: u64,
    base_out: u64,
    quote_in: u64,
    quote_out: u64,
    repay_balance_remaining: u64,
    base_liquidation: bool,
}

fun init(_: LIQUIDATION_VAULT, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let liquidation_admin_cap = LiquidationAdminCap { id };
    transfer::public_transfer(liquidation_admin_cap, ctx.sender());
}

// === Public Functions * ADMIN * ===
public fun deposit<T>(
    self: &mut LiquidationVault,
    _liquidation_cap: &LiquidationAdminCap,
    coin: Coin<T>,
) {
    let balance = coin.into_balance();
    self.deposit_int(balance);
}

public fun withdraw<T>(
    self: &mut LiquidationVault,
    _liquidation_cap: &LiquidationAdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let balance = self.withdraw_int(amount);

    balance.into_coin(ctx)
}

public fun create_liquidation_vault(_liquidation_cap: &LiquidationAdminCap, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let liquidation_vault = LiquidationVault {
        id,
        vault: bag::new(ctx),
    };
    transfer::share_object(liquidation_vault);
}

public fun authorize_trader(
    self: &mut LiquidationVault,
    _liquidation_cap: &LiquidationAdminCap,
    authorized_address: address,
) {
    let key = AuthorizedTradersKey {};
    if (!self.id.exists_(key)) {
        self.id.add(key, vec_set::empty<address>());
    };
    let traders: &mut VecSet<address> = self.id.borrow_mut(key);
    traders.insert(authorized_address);
}

public fun deauthorize_trader(
    self: &mut LiquidationVault,
    _liquidation_cap: &LiquidationAdminCap,
    authorized_address: address,
) {
    let key = AuthorizedTradersKey {};
    let traders: &mut VecSet<address> = self.id.borrow_mut(key);
    traders.remove(&authorized_address);
}

public fun swap_base_to_quote<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: u64,
    deep_in: u64,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_trader(ctx);
    let base_coin = self.withdraw_int<BaseAsset>(base_in).into_coin(ctx);
    let deep_coin = self.withdraw_int<DEEP>(deep_in).into_coin(ctx);

    let (base_out, quote_out, deep_out) = pool.swap_exact_base_for_quote(
        base_coin,
        deep_coin,
        min_quote_out,
        clock,
        ctx,
    );

    self.deposit_int(base_out.into_balance());
    self.deposit_int(quote_out.into_balance());
    self.deposit_int(deep_out.into_balance());
}

public fun swap_quote_to_base<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: u64,
    deep_in: u64,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_trader(ctx);
    let quote_coin = self.withdraw_int<QuoteAsset>(quote_in).into_coin(ctx);
    let deep_coin = self.withdraw_int<DEEP>(deep_in).into_coin(ctx);

    let (base_out, quote_out, deep_out) = pool.swap_exact_quote_for_base(
        quote_coin,
        deep_coin,
        min_base_out,
        clock,
        ctx,
    );

    self.deposit_int(base_out.into_balance());
    self.deposit_int(quote_out.into_balance());
    self.deposit_int(deep_out.into_balance());
}

// === Public Functions * LIQUIDATION * ===
public fun liquidate_base<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let risk_ratio = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    if (!self.should_liquidate<BaseAsset>(registry, pool.id(), risk_ratio)) return;
    let amount = repay_amount.destroy_with_default(self.balance<BaseAsset>());
    let balance = self.withdraw_int<BaseAsset>(amount);
    let (base_coin, quote_coin, base_repay_coin) = margin_manager.liquidate<
        BaseAsset,
        QuoteAsset,
        BaseAsset,
    >(
        registry,
        base_oracle,
        quote_oracle,
        base_margin_pool,
        pool,
        balance.into_coin(ctx),
        clock,
        ctx,
    );
    self.settle_base_liquidation(
        margin_manager.id(),
        base_margin_pool.id(),
        amount,
        base_coin,
        quote_coin,
        base_repay_coin,
    );
}

public fun liquidate_quote<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let risk_ratio = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    if (!self.should_liquidate<QuoteAsset>(registry, pool.id(), risk_ratio)) return;
    let amount = repay_amount.destroy_with_default(self.balance<QuoteAsset>());
    let balance = self.withdraw_int<QuoteAsset>(amount);
    let (base_coin, quote_coin, quote_repay_coin) = margin_manager.liquidate<
        BaseAsset,
        QuoteAsset,
        QuoteAsset,
    >(
        registry,
        base_oracle,
        quote_oracle,
        quote_margin_pool,
        pool,
        balance.into_coin(ctx),
        clock,
        ctx,
    );
    self.settle_quote_liquidation(
        margin_manager.id(),
        quote_margin_pool.id(),
        amount,
        base_coin,
        quote_coin,
        quote_repay_coin,
    );
}

public fun balance<T>(self: &LiquidationVault): u64 {
    let key = BalanceKey<T> {};

    if (self.vault.contains(key)) {
        let balance: &Balance<T> = &self.vault[key];

        balance.value()
    } else {
        0
    }
}

/// `liquidate_base` against Pyth's upgraded Core.
///
/// Pyth is replacing Core with a separately published package, so its `PriceInfoObject`
/// is a distinct Move type and `liquidate_base`'s frozen signature can never accept it.
/// Once Pyth stops publishing legacy Core the legacy entry aborts on staleness by
/// itself, and this becomes the only way the vault can liquidate. Everything but the
/// two oracle reads is shared with the legacy entry.
public fun liquidate_base_upgraded<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let risk_ratio = margin_manager_upgraded::risk_ratio(
        margin_manager,
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    if (!self.should_liquidate<BaseAsset>(registry, pool.id(), risk_ratio)) return;
    let amount = repay_amount.destroy_with_default(self.balance<BaseAsset>());
    let balance = self.withdraw_int<BaseAsset>(amount);
    let (base_coin, quote_coin, base_repay_coin) = margin_manager_upgraded::liquidate<
        BaseAsset,
        QuoteAsset,
        BaseAsset,
    >(
        margin_manager,
        registry,
        base_oracle,
        quote_oracle,
        base_margin_pool,
        pool,
        balance.into_coin(ctx),
        clock,
        ctx,
    );

    self.settle_base_liquidation(
        margin_manager.id(),
        base_margin_pool.id(),
        amount,
        base_coin,
        quote_coin,
        base_repay_coin,
    );
}

/// `liquidate_quote` against Pyth's upgraded Core. See `liquidate_base_upgraded`.
public fun liquidate_quote_upgraded<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let risk_ratio = margin_manager_upgraded::risk_ratio(
        margin_manager,
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    if (!self.should_liquidate<QuoteAsset>(registry, pool.id(), risk_ratio)) return;
    let amount = repay_amount.destroy_with_default(self.balance<QuoteAsset>());
    let balance = self.withdraw_int<QuoteAsset>(amount);
    let (base_coin, quote_coin, quote_repay_coin) = margin_manager_upgraded::liquidate<
        BaseAsset,
        QuoteAsset,
        QuoteAsset,
    >(
        margin_manager,
        registry,
        base_oracle,
        quote_oracle,
        quote_margin_pool,
        pool,
        balance.into_coin(ctx),
        clock,
        ctx,
    );

    self.settle_quote_liquidation(
        margin_manager.id(),
        quote_margin_pool.id(),
        amount,
        base_coin,
        quote_coin,
        quote_repay_coin,
    );
}

// === Private Functions ===

/// Whether this vault should act on `risk_ratio`, and has enough of `Asset` to be
/// worth acting with. Shared so the legacy and upgraded entries cannot drift apart on
/// the gate; the only thing that differs between them is which feed produced the ratio.
fun should_liquidate<Asset>(
    self: &LiquidationVault,
    registry: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    registry.can_liquidate(deepbook_pool_id, risk_ratio) && self.balance<Asset>() >= 1000
}

/// Emits the vault's liquidation event and returns every coin to the vault. Shared by
/// the legacy and upgraded base entries.
fun settle_base_liquidation<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager_id: ID,
    margin_pool_id: ID,
    base_in: u64,
    mut base_coin: Coin<BaseAsset>,
    quote_coin: Coin<QuoteAsset>,
    base_repay_coin: Coin<BaseAsset>,
) {
    event::emit(LiquidationByVault {
        vault_id: self.id(),
        margin_manager_id,
        margin_pool_id,
        base_in,
        quote_in: 0,
        base_out: base_coin.value(),
        quote_out: quote_coin.value(),
        repay_balance_remaining: base_repay_coin.value(),
        base_liquidation: true,
    });

    base_coin.join(base_repay_coin);
    self.deposit_int(base_coin.into_balance());
    self.deposit_int(quote_coin.into_balance());
}

/// Quote-side twin of `settle_base_liquidation`.
fun settle_quote_liquidation<BaseAsset, QuoteAsset>(
    self: &mut LiquidationVault,
    margin_manager_id: ID,
    margin_pool_id: ID,
    quote_in: u64,
    base_coin: Coin<BaseAsset>,
    mut quote_coin: Coin<QuoteAsset>,
    quote_repay_coin: Coin<QuoteAsset>,
) {
    event::emit(LiquidationByVault {
        vault_id: self.id(),
        margin_manager_id,
        margin_pool_id,
        base_in: 0,
        quote_in,
        base_out: base_coin.value(),
        quote_out: quote_coin.value(),
        repay_balance_remaining: quote_repay_coin.value(),
        base_liquidation: false,
    });

    quote_coin.join(quote_repay_coin);
    self.deposit_int(base_coin.into_balance());
    self.deposit_int(quote_coin.into_balance());
}

fun deposit_int<T>(self: &mut LiquidationVault, balance: Balance<T>) {
    let key = BalanceKey<T> {};

    if (self.vault.contains(key)) {
        let vault: &mut Balance<T> = &mut self.vault[key];
        vault.join(balance);
    } else {
        self.vault.add(key, balance);
    }
}

fun withdraw_int<T>(self: &mut LiquidationVault, amount: u64): Balance<T> {
    let key = BalanceKey<T> {};
    if (!self.vault.contains(key)) {
        self.vault.add(key, balance::zero<T>());
    };
    let balance: &mut Balance<T> = &mut self.vault[key];
    assert!(balance.value() >= amount, ENotEnoughBalanceInVault);

    balance.split(amount)
}

fun assert_trader(self: &LiquidationVault, ctx: &TxContext) {
    let key = AuthorizedTradersKey {};
    let traders: &VecSet<address> = self.id.borrow(key);
    assert!(traders.contains(&ctx.sender()), ETraderNotAuthorized);
}

fun id(self: &LiquidationVault): ID {
    self.id.to_inner()
}

// === Test Only ===
/// Reads back a `LiquidationByVault` for assertions. The event is what the off-chain
/// liquidation engine accounts from, and its fields are module-private, so without
/// this a flipped `base_liquidation` discriminator or a transposed `base_in`/`quote_in`
/// is unobservable from a test.
public fun liquidation_event_fields(e: &LiquidationByVault): (u64, u64, u64, u64, u64, bool) {
    (e.base_in, e.quote_in, e.base_out, e.quote_out, e.repay_balance_remaining, e.base_liquidation)
}

#[test_only]
public fun create_liquidation_vault_for_testing(ctx: &mut TxContext): LiquidationVault {
    LiquidationVault {
        id: object::new(ctx),
        vault: bag::new(ctx),
    }
}

#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext): LiquidationAdminCap {
    LiquidationAdminCap { id: object::new(ctx) }
}

#[test_only]
public fun assert_trader_for_testing(self: &LiquidationVault, ctx: &TxContext) {
    self.assert_trader(ctx);
}
