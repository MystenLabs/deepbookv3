// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The sponsored swap module enables any user to call DeepBook's
/// `swap_exact_base_for_quote` and `swap_exact_quote_for_base`
/// functions without needing any DEEP tokens. The DEEP tokens will
/// instead be sponsored by the `SponsoredSwapAdminCap` owner.
module sponsored_swap::sponsored_swap;

use deepbook::pool::Pool;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use token::deep::DEEP;

const ENotEnoughBalance: u64 = 0;
const EIncorrectFeeCalculation: u64 = 1;

public struct SponsoredSwapAdminCap has key, store {
    id: UID,
}

public struct SponsoredTokens has key {
    id: UID,
    balance: Balance<DEEP>,
}

/// Initialize the SponsoredTokens shared object as a singleton.
/// The `SponsoredSwapAdminCap` is created and transferred to the sender.
fun init(ctx: &mut TxContext) {
    let sponsored_tokens = SponsoredTokens {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    let admin = SponsoredSwapAdminCap { id: object::new(ctx) };

    transfer::share_object(sponsored_tokens);
    transfer::public_transfer(admin, ctx.sender());
}

/// Deposit DEEP tokens into the SponsoredTokens shared object by the admin.
public fun deposit_sponsored_tokens(
    self: &mut SponsoredTokens,
    _: &SponsoredSwapAdminCap,
    deep: Coin<DEEP>,
) {
    let deep_balance = deep.into_balance();
    self.balance.join(deep_balance);
}

/// Withdraw DEEP tokens from the SponsoredTokens shared object by the admin.
public fun withdraw_sponsored_tokens(
    self: &mut SponsoredTokens,
    _: &SponsoredSwapAdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DEEP> {
    assert!(self.balance.value() >= amount, ENotEnoughBalance);
    let deep_balance = self.balance.split(amount);

    deep_balance.into_coin(ctx)
}

/// Swap exact base for quote tokens with DEEP tokens sponsored.
/// First, calculate the quantity of DEEP needed for the swap. Then,
/// split that quantity from the SponsoredTokens shared object and
/// call DeepBook's `swap_exact_base_for_quote` function.
public fun swap_exact_base_for_quote_sponsored<BaseAsset, QuoteAsset>(
    self: &mut SponsoredTokens,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (_, _, deep_needed) = pool.get_quote_quantity_out(
        base_in.value(),
        clock,
    );

    assert!(self.balance.value() >= deep_needed, ENotEnoughBalance);
    let deep_in = self.balance.split(deep_needed).into_coin(ctx);
    let (base_out, quote_out, deep_out) = pool.swap_exact_base_for_quote(
        base_in,
        deep_in,
        min_quote_out,
        clock,
        ctx,
    );

    assert!(deep_out.value() == 0, EIncorrectFeeCalculation);
    deep_out.destroy_zero();

    (base_out, quote_out)
}

/// Swap exact quote for base tokens with DEEP tokens sponsored.
/// First, calculate the quantity of DEEP needed for the swap. Then,
/// split that quantity from the SponsoredTokens shared object and
/// call DeepBook's `swap_exact_quote_for_base` function.
public fun swap_exact_quote_for_base_sponsored<BaseAsset, QuoteAsset>(
    self: &mut SponsoredTokens,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    // Calculate the quantity of DEEP needed
    let (_, _, deep_needed) = pool.get_base_quantity_out(
        quote_in.value(),
        clock,
    );

    assert!(self.balance.value() >= deep_needed, ENotEnoughBalance);
    let deep_in = self.balance.split(deep_needed).into_coin(ctx);
    let (base_out, quote_out, deep_out) = pool.swap_exact_quote_for_base(
        quote_in,
        deep_in,
        min_base_out,
        clock,
        ctx,
    );

    assert!(deep_out.value() == 0, EIncorrectFeeCalculation);
    deep_out.destroy_zero();

    (base_out, quote_out)
}

/// Get the balance of DEEP tokens in the SponsoredTokens shared object.
public fun sponsored_token_balance(self: &SponsoredTokens): u64 {
    self.balance.value()
}

/// Get the quantity of quote tokens out for a given quantity of base tokens in.
public fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_in: u64,
    clock: &Clock,
): (u64, u64, u64) {
    pool.get_quote_quantity_out(base_in, clock)
}

/// Get the quantity of base tokens out for a given quantity of quote tokens in.
public fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    quote_in: u64,
    clock: &Clock,
): (u64, u64, u64) {
    pool.get_base_quantity_out(quote_in, clock)
}

#[test_only]
public fun test_sponsored_tokens(ctx: &mut TxContext): ID {
    let sponsored_tokens = SponsoredTokens {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    let id = object::id(&sponsored_tokens);
    transfer::share_object(sponsored_tokens);

    id
}

#[test_only]
public fun admin_cap_for_testing(ctx: &mut TxContext): SponsoredSwapAdminCap {
    SponsoredSwapAdminCap { id: object::new(ctx) }
}
