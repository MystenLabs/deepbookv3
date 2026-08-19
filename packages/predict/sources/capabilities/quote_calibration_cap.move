// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable authority to publish quote calibration corrections, and nothing else.
/// `Registry` owns the allowlist, and `ProtocolConfig` owns the state a valid capability may write.
module deepbook_predict::quote_calibration_cap;

/// Capability authorized to publish calibration corrections while its ID remains allowlisted.
public struct QuoteCalibrationCap has key, store {
    id: UID,
}

/// Returns the capability identity used by the registry allowlist.
public fun id(cap: &QuoteCalibrationCap): ID {
    cap.id.to_inner()
}

/// Destroy a `QuoteCalibrationCap` the holder no longer needs.
public fun destroy(cap: QuoteCalibrationCap) {
    let QuoteCalibrationCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Constructs a capability for the registry to allowlist atomically.
public(package) fun new(ctx: &mut TxContext): QuoteCalibrationCap {
    QuoteCalibrationCap { id: object::new(ctx) }
}
