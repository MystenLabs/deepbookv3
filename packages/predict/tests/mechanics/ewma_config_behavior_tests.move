// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Local EWMA policy defaults, endpoint writes, and enable-state transitions.
#[test_only]
module deepbook_predict::mechanics_ewma_config_behavior_tests;

use deepbook_predict::{config_constants, ewma_config};
use std::unit_test::{assert_eq, destroy};

#[test]
fun defaults_and_enable_toggle_match_policy() {
    let mut config = ewma_config::new();
    assert_eq!(config.alpha(), config_constants::default_ewma_alpha!());
    assert_eq!(config.z_score_threshold(), config_constants::default_ewma_z_score_threshold!());
    assert_eq!(config.penalty_rate(), config_constants::default_ewma_penalty_rate!());
    assert!(!config.enabled());
    config.set_enabled(true);
    assert!(config.enabled());
    config.set_enabled(false);
    assert!(!config.enabled());
    destroy(config);
}

#[test]
fun parameter_endpoints_are_stored_exactly() {
    let mut config = ewma_config::new();
    config.set_params(
        config_constants::min_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::min_ewma_penalty_rate!(),
    );
    assert_eq!(config.alpha(), config_constants::min_ewma_alpha!());
    assert_eq!(config.z_score_threshold(), config_constants::min_ewma_z_score_threshold!());
    assert_eq!(config.penalty_rate(), config_constants::min_ewma_penalty_rate!());
    config.set_params(
        config_constants::max_ewma_alpha!(),
        config_constants::max_ewma_z_score_threshold!(),
        config_constants::max_ewma_penalty_rate!(),
    );
    assert_eq!(config.alpha(), config_constants::max_ewma_alpha!());
    assert_eq!(config.z_score_threshold(), config_constants::max_ewma_z_score_threshold!());
    assert_eq!(config.penalty_rate(), config_constants::max_ewma_penalty_rate!());
    destroy(config);
}
