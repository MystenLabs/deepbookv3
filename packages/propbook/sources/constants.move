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
    2
}

/// Decimal places of the 1e9 price scaling that `pyth_feed::normalize_raw_spot`
/// targets.
public(package) macro fun float_scaling_decimals(): u64 {
    9
}

/// Maximum age, below an exact settlement key, of the Pyth price that may settle
/// it: the settling print's `feedUpdateTimestamp` must be within this window
/// at-or-before the envelope/expiry timestamp. A within-window carried price is
/// admissible (settlement is a most-recent-as-of-expiry mark); a longer Pyth
/// carry or halt is rejected so a stale price cannot permanently lock the
/// insert-only key. Compiled, not admin-set: the settlement insert is
/// permissionless, so a caller-supplied window could be set arbitrarily large.
/// Changing it is a package upgrade.
public(package) macro fun max_settlement_carry_ms(): u64 {
    2_000
}
