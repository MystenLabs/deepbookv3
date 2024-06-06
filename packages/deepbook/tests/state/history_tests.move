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
    use deepbook::{
        history::Self,
        trade_params::Self,
        constants,
    };

    const EWrongRebateAmount: u64 = 0;

    const FLOAT_SCALING: u64 = 1_000_000_000;

    #[test]
    /// Test that the rebate amount is calculated correctly.
    fun test_rebate_amount() {
        let owner: address = @0x1;
        let mut test = begin(owner);

        let trade_params = trade_params::new(0, 0, 1_000_000);
        let mut history = history::empty(trade_params, 0, test.ctx());
        let mut epochs_to_advance = constants::epochs_for_phase_out();

        while (epochs_to_advance > 0) {
            test.next_epoch(owner);
            history.update(trade_params, test.ctx());
            history.set_current_volumes(
                10 * FLOAT_SCALING, // total_volume
                5 * FLOAT_SCALING, // total_staked_volume
                500_000_000, // total_fees_collected
            );
            epochs_to_advance = epochs_to_advance - 1;
        };

        // epoch 29
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        history.set_current_volumes(
            10 * FLOAT_SCALING, // total_volume
            5 * FLOAT_SCALING, // total_staked_volume
            1_000_000_000, // total_fees_collected
        );

        // epoch 30
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        let rebate = history.calculate_rebate_amount(
            29,
            3 * FLOAT_SCALING,
            1_000_000
        );
        assert!(rebate == 180_000_000, EWrongRebateAmount);

        test_utils::destroy(history);
        end(test);
    }

    #[test]
    /// Test that the rebate amount is correct when the epoch is skipped.
    fun test_epoch_skipped() {
        let owner: address = @0x1;
        let mut test = begin(owner);

        let trade_params = trade_params::new(0, 0, 1_000_000);

        // epoch 0
        let mut history = history::empty(trade_params, 0, test.ctx());
        let mut epochs_to_advance = constants::epochs_for_phase_out();

        while (epochs_to_advance > 0) {
            test.next_epoch(owner);
            history.update(trade_params, test.ctx());
            history.set_current_volumes(
                10 * FLOAT_SCALING, // total_volume
                5 * FLOAT_SCALING, // total_staked_volume
                500_000_000, // total_fees_collected
            );
            epochs_to_advance = epochs_to_advance - 1;
        };

        // epoch 29
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        history.set_current_volumes(
            10 * FLOAT_SCALING, // total_volume
            5 * FLOAT_SCALING, // total_staked_volume
            1_000_000_000, // total_fees_collected
        );

        // epoch 31
        test.next_epoch(owner);
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        let rebate_epoch_0_alice = history.calculate_rebate_amount(
            28, // epoch
            0, // maker_volume
            1_000_000 // stake
        );
        assert!(rebate_epoch_0_alice == 0, EWrongRebateAmount);

        let rebate_epoch_1_alice = history.calculate_rebate_amount(
            28, // epoch
            0, // maker_volume
            1_000_000 // stake
        );
        assert!(rebate_epoch_1_alice == 0, EWrongRebateAmount);

        let rebate_epoch_1_bob = history.calculate_rebate_amount(
            29,
            3 * FLOAT_SCALING,
            1_000_000 // stake
        );
        assert!(rebate_epoch_1_bob == 180_000_000, EWrongRebateAmount);

        test_utils::destroy(history);
        end(test);
    }

    #[test]
    fun test_other_maker_volume_above_phase_out() {
        let owner: address = @0x1;
        let mut test = begin(owner);

        let trade_params = trade_params::new(0, 0, 1_000_000);

        // epoch 0
        let mut history = history::empty(trade_params, 0, test.ctx());
        let mut epochs_to_advance = constants::epochs_for_phase_out();

        while (epochs_to_advance > 0) {
            test.next_epoch(owner);
            history.update(trade_params, test.ctx());
            history.set_current_volumes(
                10 * FLOAT_SCALING, // total_volume
                5 * FLOAT_SCALING, // total_staked_volume
                500_000_000, // total_fees_collected
            );
            epochs_to_advance = epochs_to_advance - 1;
        };

        // epoch 29
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        history.set_current_volumes(
            15 * FLOAT_SCALING, // total_volume
            5 * FLOAT_SCALING, // total_staked_volume
            1_000_000_000, // total_fees_collected
        );

        // epoch 30
        test.next_epoch(owner);
        history.update(trade_params, test.ctx());

        let rebate = history.calculate_rebate_amount(
            29,
            3 * FLOAT_SCALING,
            1_000_000
        );
        assert!(rebate == 0, EWrongRebateAmount);

        test_utils::destroy(history);
        end(test);
    }
}
