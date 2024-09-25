#[test_only]
module sponsored_swap::sponsored_swap_tests;

use deepbook::pool::Pool;
use deepbook::pool_tests;
use sponsored_swap::sponsored_swap::{Self, SponsoredTokens};
use std::type_name;
use sui::clock::Clock;
use sui::coin::mint_for_testing;
use sui::object::id_to_address;
use sui::sui::SUI;
use sui::test_scenario::{begin, end};
use sui::test_utils::{destroy, assert_eq};
use token::deep::DEEP;

public struct USDC has store {}

const OWNER: address = @0x1;
const ALICE: address = @0x2;

#[test]
fun test_exact_base_for_quote_sponsored() {
    let mut test = begin(OWNER);
    let sponsored_tokens_id = sponsored_swap::test_sponsored_tokens(test.ctx());
    let pool_id = pool_tests::setup_everything<SUI, USDC, DEEP, USDC>(
        &mut test,
    );
    let admin_cap = sponsored_swap::admin_cap_for_testing(test.ctx());

    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let mut sponsored_tokens = test.take_shared_by_id<SponsoredTokens>(
        sponsored_tokens_id,
    );

    let sponsored_deep = mint_for_testing<DEEP>(1_000_000_000, test.ctx());
    sponsored_tokens.deposit_sponsored_tokens(&admin_cap, sponsored_deep);

    let base_in = mint_for_testing<SUI>(1_000_000_000, test.ctx());
    let clock = test.take_shared<Clock>();

    let (
        base_out,
        quote_out,
    ) = sponsored_tokens.swap_exact_base_for_quote_sponsored(
        &mut pool,
        base_in,
        0,
        &clock,
        test.ctx(),
    );

    std::debug::print(&base_out.value());
    std::debug::print(&quote_out.value());

    destroy(base_out);
    destroy(quote_out);
    destroy(pool);
    destroy(sponsored_tokens);
    destroy(admin_cap);
    destroy(clock);

    test.end();
}

#[test]
fun test_sponsored_tokens() {
    let mut test = begin(OWNER);
    let sponsored_tokens_id = sponsored_swap::test_sponsored_tokens(test.ctx());

    test.next_tx(ALICE);
    let sponsored_tokens = test.take_shared_by_id<SponsoredTokens>(
        sponsored_tokens_id,
    );

    destroy(sponsored_tokens);
    test.end();
}
