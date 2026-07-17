// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines Propbook's upgrade-required storage version and normalized price scale.
/// Every package upgrade must advance `current_version`; neither value is admin-tunable.
module propbook::constants;

/// Returns the version a feed must match to accept writes and the target version for migration.
public(package) macro fun current_version(): u64 {
    1
}

/// Returns the decimal places used by normalized oracle values: nine means `1e9` units per whole value.
public(package) macro fun float_scaling_decimals(): u64 {
    9
}
