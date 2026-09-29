// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The trading phases of an index market.
/// Paused is a phase. A mid is not written while the market is paused.
module venue::market_phase;

const LIVE: u8 = 0;
const PENDING: u8 = 1;
const SETTLEMENT: u8 = 2;
const PAUSED: u8 = 3;

/// Trading is open.
public fun live(): u8 { LIVE }

/// Trading has ended. The market is waiting for a result.
public fun pending(): u8 { PENDING }

/// A result or a void is stored. Tickets can be claimed.
public fun settlement(): u8 { SETTLEMENT }

/// Trading and mid writes are stopped.
public fun paused(): u8 { PAUSED }
