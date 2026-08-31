// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines Propbook's upgrade-required storage version, normalized price scale, and exact-insert carry bounds.
/// Every package upgrade must advance `current_version`; no value here is admin-tunable.
module propbook::constants;

/// Returns the version a feed must match to accept writes and the target version for migration.
public(package) macro fun current_version(): u64 {
    1
}

/// Returns the decimal places used by normalized oracle values: nine means `1e9` units per whole value.
public(package) macro fun float_scaling_decimals(): u64 {
    9
}

/// Returns how far before its envelope an exact-insert observation may have been generated.
/// Exact inserts are permissionless and insert-only, so this bound is compiled rather than
/// caller-supplied: a caller-chosen window could be set arbitrarily wide on the one write
/// that permanently owns a settlement key.
public(package) macro fun max_settlement_carry_ms(): u64 {
    2_000
}

/// Returns how far before its envelope a Block Scholes exact-insert model time may sit.
/// `model_timestamp_ms` is when the estimate was last generated; the exact key is the envelope.
/// The bound is one exact-history period, not Pyth's 2s millisecond-tick window, because Block
/// Scholes exact keys are whole minutes. Latest updates do not use this bound.
public(package) macro fun max_block_scholes_settlement_carry_ms(): u64 {
    60_000
}
