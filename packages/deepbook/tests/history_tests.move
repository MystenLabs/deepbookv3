// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::history_tests {
    use sui::{
        test_scenario::{
            begin,
            end,
        },
        test_utils,
    };
    use deepbook::history::Self;

    const EWrongRebateAmount: u64 = 0;

    const FLOAT_SCALING: u64 = 1_000_000_000;

    #[test]
    fun test_rebate_amount() {
        let owner: address = @0x1;
        let mut test = begin(owner);

        let mut history = history::empty(test.ctx());
        history.set_current_volumes(
            10 * FLOAT_SCALING, // total_volume
            5 * FLOAT_SCALING, // total_staked_volume
            500_000_000, // total_fees_collected
            1_000_000, // stake_required
            10, // accounts_with_rebates
        );

        test.next_epoch(owner);
        history.update(test.ctx());

        history.set_current_volumes(
            10 * FLOAT_SCALING, // total_volume
            5 * FLOAT_SCALING, // total_staked_volume
            1_000_000_000, // total_fees_collected
            1_000_000, // stake_required
            10, // accounts_with_rebates
        );

        test.next_epoch(owner);
        history.update(test.ctx());

        let rebate = history.calculate_rebate_amount(test.ctx().epoch() - 1, 3 * FLOAT_SCALING, 1_000_000);
        assert!(rebate == 180_000_000, EWrongRebateAmount);

        test_utils::destroy(history);
        end(test);
    }
}
