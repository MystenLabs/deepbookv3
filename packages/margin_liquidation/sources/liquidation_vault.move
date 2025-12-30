// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_liquidation::liquidation_vault;

use deepbook::pool::Pool;
use deepbook_margin::{
    margin_manager::{MarginManager, liquidate},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry
};
use pyth::price_info::PriceInfoObject;
use sui::{bag::{Self, Bag}, balance::{Self, Balance}, clock::Clock, coin::Coin, event};

// === Errors ===
const ENotEnoughBalanceInVault: u64 = 1;

public struct LIQUIDATION_VAULT has drop {}

// === Structs ===
public struct LiquidationVault has key {
    id: UID,
    vault: Bag,
}

public struct BalanceKey<phantom T> has copy, drop, store {}

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
    let base_balance = self.balance<BaseAsset>();
    if (!registry.can_liquidate(pool.id(), risk_ratio) || base_balance < 1000) {
        return
    };
    let amount = repay_amount.destroy_with_default(base_balance);
    let balance = self.withdraw_int<BaseAsset>(amount);
    let (mut base_coin, quote_coin, base_repay_coin) = margin_manager.liquidate<
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
    let repay_balance_remaining = base_repay_coin.value();
    let base_out = base_coin.value();
    let quote_out = quote_coin.value();
    event::emit(LiquidationByVault {
        vault_id: self.id(),
        margin_manager_id: margin_manager.id(),
        margin_pool_id: base_margin_pool.id(),
        base_in: amount,
        quote_in: 0,
        base_out,
        quote_out,
        repay_balance_remaining,
        base_liquidation: true,
    });

    base_coin.join(base_repay_coin);
    self.deposit_int(base_coin.into_balance());
    self.deposit_int(quote_coin.into_balance());
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
    let quote_balance = self.balance<QuoteAsset>();
    if (!registry.can_liquidate(pool.id(), risk_ratio) || quote_balance < 1000) {
        return
    };
    let amount = repay_amount.destroy_with_default(quote_balance);
    let balance = self.withdraw_int<QuoteAsset>(amount);
    let (base_coin, mut quote_coin, quote_repay_coin) = margin_manager.liquidate<
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
    let repay_balance_remaining = quote_repay_coin.value();
    let base_out = base_coin.value();
    let quote_out = quote_coin.value();
    event::emit(LiquidationByVault {
        vault_id: self.id(),
        margin_manager_id: margin_manager.id(),
        margin_pool_id: quote_margin_pool.id(),
        base_in: 0,
        quote_in: amount,
        base_out,
        quote_out,
        repay_balance_remaining,
        base_liquidation: false,
    });

    quote_coin.join(quote_repay_coin);
    self.deposit_int(base_coin.into_balance());
    self.deposit_int(quote_coin.into_balance());
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

// === Private Functions ===
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

fun id(self: &LiquidationVault): ID {
    self.id.to_inner()
}
