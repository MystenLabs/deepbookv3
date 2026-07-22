// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// EWMA parameter last-valid/first-invalid guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__ewma_config_tests;

use deepbook_predict::{config_constants, ewma_config};

const RAW_UNIT: u64 = 1;

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaAlpha)]
fun zero_alpha_aborts() {
    ewma_config::new().set_params(
        config_constants::min_ewma_alpha!() - RAW_UNIT,
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::min_ewma_penalty_rate!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaAlpha)]
fun alpha_one_above_max_aborts() {
    ewma_config::new().set_params(
        config_constants::max_ewma_alpha!() + RAW_UNIT,
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::min_ewma_penalty_rate!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaZScoreThreshold)]
fun z_score_one_below_min_aborts() {
    ewma_config::new().set_params(
        config_constants::min_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!() - RAW_UNIT,
        config_constants::min_ewma_penalty_rate!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaZScoreThreshold)]
fun z_score_one_above_max_aborts() {
    ewma_config::new().set_params(
        config_constants::min_ewma_alpha!(),
        config_constants::max_ewma_z_score_threshold!() + RAW_UNIT,
        config_constants::min_ewma_penalty_rate!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaPenaltyRate)]
fun penalty_rate_one_above_max_aborts() {
    ewma_config::new().set_params(
        config_constants::min_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::max_ewma_penalty_rate!() + RAW_UNIT,
    );
    abort 999
}
