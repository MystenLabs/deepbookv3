// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::ewma_tests;

use deepbook::ewma::{init_ewma_state, EWMAState};

#[test_only]
public fun test_init_ewma_state(ctx: &TxContext): EWMAState {
    init_ewma_state(ctx)
}
