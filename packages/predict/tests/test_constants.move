// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared constants for Predict test code.
#[test_only]
module deepbook_predict::test_constants;

// === Test Addresses ===
const ADMIN: address = @0x0;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CAROL: address = @0xC;

public fun admin(): address { ADMIN }

public fun alice(): address { ALICE }

public fun bob(): address { BOB }

public fun carol(): address { CAROL }
