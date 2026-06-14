// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Package-own upgrade-required constants for `propbook`: the version gate and
/// price scaling target. Changing either is a package upgrade, not an admin
/// action, so they stay as macros (no config struct, setter, or admin flow).
/// Every package upgrade MUST bump `current_version`.
module propbook::constants;

/// Running package version: the exact version a feed must match to accept
/// updates, and the target of each feed's `migrate`.
public(package) macro fun current_version(): u64 {
    1
}

/// Decimal places of the 1e9 price scaling that `normalize_pyth_price` targets.
public(package) macro fun float_scaling_decimals(): u64 {
    9
}
