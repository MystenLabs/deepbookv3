// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::test_constants;

public macro fun float_scaling(): u64 { 1_000_000_000 }

public macro fun alice(): address { @0xA }

public macro fun bob(): address { @0xB }

public macro fun carol(): address { @0xC }
