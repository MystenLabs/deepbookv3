// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Deposit capability for a `PredictManager`. The manager owns the allowlist
/// and the owner-gated mint/revoke entrypoints; this module owns only the
/// cap object itself.
module deepbook_predict::predict_deposit_cap;

/// `PredictDepositCap` is used to deposit funds into a PredictManager by a
/// non-owner.
public struct PredictDepositCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Return the deposit cap object ID.
public fun id(cap: &PredictDepositCap): ID {
    cap.id.to_inner()
}

/// Return the `PredictManager` this cap was minted for.
public fun predict_manager_id(cap: &PredictDepositCap): ID {
    cap.predict_manager_id
}

/// Destroy a `PredictDepositCap` the holder no longer needs.
public fun destroy(cap: PredictDepositCap) {
    let PredictDepositCap { id, .. } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Construct a cap. Allow-listing and the owner check are
/// `predict_manager`'s job.
public(package) fun new(predict_manager_id: ID, ctx: &mut TxContext): PredictDepositCap {
    PredictDepositCap { id: object::new(ctx), predict_manager_id }
}
