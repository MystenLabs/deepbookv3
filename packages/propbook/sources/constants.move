// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Package-own upgrade-required constants for `propbook`: the version gate and
/// price scaling target. Changing either is a package upgrade, not an admin
/// action, so they stay as macros (no config struct, setter, or admin flow).
/// Every package upgrade MUST bump `current_version`.
module propbook::constants;

/// Running package version: the exact version a feed must match to accept
/// updates, and the target of each feed's `migrate`.
///
/// Why every feed's `EWrongVersion` gate is unreachable within one package
/// version (and so carries no `expected_failure` test, per unit-tests.md Rule 4):
/// `create_and_share` stamps a feed with `current_version!()`, and `migrate` only
/// advances a feed forward to that same compiled constant. So a feed's `version`
/// can never diverge from `current_version!()` at a single package version. The
/// gate fires only after a live package upgrade, against a feed that has not been
/// migrated yet — which is exactly what it exists to do.
public(package) macro fun current_version(): u64 {
    1
}

/// Decimal places of the 1e9 price scaling that `pyth_feed::normalize_raw_spot`
/// targets.
public(package) macro fun float_scaling_decimals(): u64 {
    9
}
