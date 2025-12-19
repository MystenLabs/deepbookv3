// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module test_swap::testing;

use deepbook::balance_manager::{Self, BalanceManager};

public fun new(ctx: &mut TxContext): BalanceManager {
    balance_manager::new(ctx)
}
