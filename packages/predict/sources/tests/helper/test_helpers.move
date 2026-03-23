// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::test_helpers;

/// Assert signed value equals expected magnitude and sign.
public fun assert_signed_eq(
    actual_mag: u64,
    actual_neg: bool,
    expected_mag: u64,
    expected_neg: bool,
) {
    assert!(actual_mag == expected_mag);
    assert!(actual_neg == expected_neg);
}
