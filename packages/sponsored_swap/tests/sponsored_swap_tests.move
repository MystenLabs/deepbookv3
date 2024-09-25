#[test_only]
module sponsored_swap::sponsored_swap_tests;

use deepbook::pool::Pool;
use deepbook::pool_tests;
use std::type_name;
use sui::clock::Clock;
use sui::coin::mint_for_testing;
use sui::object::id_to_address;
use sui::sui::SUI;
use sui::test_scenario::{begin, end};
use sui::test_utils::{destroy, assert_eq};
use token::deep::DEEP;

const OWNER: address = @0x1;
