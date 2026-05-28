// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared constants for Predict test code.
#[test_only]
module deepbook_predict::test_constants;

use deepbook_predict::constants;

// === Test Addresses ===
const ADMIN: address = @0x0;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CAROL: address = @0xC;

public fun admin(): address { ADMIN }

public fun alice(): address { ALICE }

public fun bob(): address { BOB }

public fun carol(): address { CAROL }

/// Default expiry-fee ramp window seeded by test helpers; matches the
/// production "ramp disabled" sentinel.
public(package) macro fun default_expiry_fee_window_ms(): u64 { 0 }

/// Default expiry-fee ramp multiplier seeded by test helpers; 1x is a no-op,
/// matching the production "ramp disabled" sentinel.
public(package) macro fun default_expiry_fee_max_multiplier(): u64 {
    constants::float_scaling!()
}
