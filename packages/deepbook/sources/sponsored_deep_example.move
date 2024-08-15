// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// An example of a SponsoredDeep module. In practice, this would be its own package that would
/// depend on DEEP and DeepBook packages. The package initializes a sponsored pool singleton
/// and allows the admin cap owner to deposit and withdraw pools. It also exposes a swap function
/// that will automatically tap into the DEEP sponsored pool to pay for transaction fees. This function
/// in turn calls DeepBook's swap function to perform the swap.
module deepbook::sponsored_deep;
use deepbook::pool::Pool;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use token::deep::DEEP;

const EIncorrectFeeCalculation: u64 = 0;

public struct SPONSORED_DEEP has drop {}

public struct SponsoredDeepAdminCap has key, store {
    id: UID,
}

public struct DeepPool has key {
    id: UID,
    balance: Balance<DEEP>,
}

/// Initialize the SponsoredDeep shared object as a singleton.
/// The SponsoredDeepAdminCap is created and transferred to the sender.
fun init(_: SPONSORED_DEEP, ctx: &mut TxContext) {
    let pool = DeepPool {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    let admin = SponsoredDeepAdminCap { id: object::new(ctx) };

    transfer::share_object(pool);
    transfer::public_transfer(admin, ctx.sender());
}

/// Only admin can deposit DEEP. Add validations as needed.
public fun deposit_deep(
    deep_pool: &mut DeepPool,
    _: &SponsoredDeepAdminCap,
    deep: Coin<DEEP>,
) {
    let deep_balance = deep.into_balance();
    deep_pool.balance.join(deep_balance);
}

/// Only admin can withdraw DEEP. Add validations as needed.
public fun withdraw_deep(
    deep_pool: &mut DeepPool,
    _: &SponsoredDeepAdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DEEP> {
    let deep_balance = deep_pool.balance.split(amount);

    deep_balance.into_coin(ctx)
}

/// Call this function through your front end instead of the DeepBook's swap function
/// to allow for the usage of the sponsored DEEP pool.
public fun swap_exact_base_for_quote_sponsored<BaseAsset, QuoteAsset>(
    deep_pool: &mut DeepPool,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    // calculate the quantity DEEP needed
    let (_, _, deep_needed) = pool.get_quote_quantity_out(
        base_in.value(),
        clock,
    );
    // split the DEEP from the sponsored pool into a coin
    let deep_in = deep_pool.balance.split(deep_needed).into_coin(ctx);
    // Swap
    let (base_out, quote_out, deep_out) = pool.swap_exact_base_for_quote(
        base_in,
        deep_in,
        min_quote_out,
        clock,
        ctx,
    );

    // all fees should be used up
    assert!(deep_out.value() == 0, EIncorrectFeeCalculation);
    // get rid of the zero balance
    deep_out.destroy_zero();

    // return the base and quote coins
    (base_out, quote_out)
}
