// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Withdraw capability for a `PredictManager`. The manager owns the allowlist
/// and the owner-gated mint/revoke entrypoints; this module owns only the
/// cap object itself.
module deepbook_predict::predict_withdraw_cap;

/// `PredictWithdrawCap` is used to withdraw funds from a PredictManager by a
/// non-owner.
public struct PredictWithdrawCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Return the withdraw cap object ID.
public fun id(cap: &PredictWithdrawCap): ID {
    cap.id.to_inner()
}

/// Return the `PredictManager` this cap was minted for.
public fun predict_manager_id(cap: &PredictWithdrawCap): ID {
    cap.predict_manager_id
}

/// Destroy a `PredictWithdrawCap` the holder no longer needs.
public fun destroy(cap: PredictWithdrawCap) {
    let PredictWithdrawCap { id, .. } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Construct a cap. Allow-listing and the owner check are
/// `predict_manager`'s job.
public(package) fun new(predict_manager_id: ID, ctx: &mut TxContext): PredictWithdrawCap {
    PredictWithdrawCap { id: object::new(ctx), predict_manager_id }
}
