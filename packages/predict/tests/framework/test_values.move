// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minimal shared inputs for the Phase 1 production-valid test world.
#[test_only]
module deepbook_predict::test_values;

use deepbook_predict::{constants, market_manager};
use fixed_math::math;

const SYSTEM: address = @0x0;
const ADMIN: address = @0xA;
const ALICE: address = @0xB;
const NOW_MS: u64 = 120_000;
const PYTH_SOURCE_ID: u32 = 1;
const PROBOOK_UNDERLYING_ID: u32 = 42;
const TICK_SIZE: u64 = 1_000_000_000;
const ADMISSION_TICK_SIZE: u64 = 10_000_000_000;
const MAX_EXPIRY_ALLOCATION: u64 = 250_000_000_000;
const CADENCE_WINDOW_SIZE: u64 = 1;
const POOL_CAPITAL: u64 = 20_000_000_000;
const STRIKE_TICK: u64 = 100;
const MINT_QUANTITY: u64 = 1_000_000_000;
const TRADER_DEPOSIT: u64 = 1_000_000_000;

public fun system(): address { SYSTEM }

public fun admin(): address { ADMIN }

public fun alice(): address { ALICE }

public fun now_ms(): u64 { NOW_MS }

public fun pyth_source_id(): u32 { PYTH_SOURCE_ID }

public fun propbook_underlying_id(): u32 { PROBOOK_UNDERLYING_ID }

public fun cadence_id(): u8 { market_manager::cadence_one_minute!() }

public fun cadence_period_ms(): u64 { constants::one_minute_ms!() }

public fun cadence_window_size(): u64 { CADENCE_WINDOW_SIZE }

public fun expiry_ms(): u64 { NOW_MS + cadence_period_ms() }

public fun tick_size(): u64 { TICK_SIZE }

public fun admission_tick_size(): u64 { ADMISSION_TICK_SIZE }

public fun max_expiry_allocation(): u64 { MAX_EXPIRY_ALLOCATION }

public fun initial_expiry_cash(): u64 { constants::expiry_cash_floor!() }

public fun pool_capital(): u64 { POOL_CAPITAL }

public fun strike_tick(): u64 { STRIKE_TICK }

public fun mint_quantity(): u64 { MINT_QUANTITY }

public fun trader_deposit(): u64 { TRADER_DEPOSIT }

public fun leverage_one_x(): u64 { math::float_scaling!() }
