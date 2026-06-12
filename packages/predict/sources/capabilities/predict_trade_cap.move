// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Trade capability for a `PredictManager`. The manager owns the allowlist
/// and the owner-gated mint/revoke entrypoints; this module owns only the
/// cap object itself.
module deepbook_predict::predict_trade_cap;

/// Owners of a `PredictTradeCap` can generate a `PredictTradeProof` to mint/redeem
/// positions on this manager. Risk of equivocation since `PredictTradeCap` is
/// an owned object — high-frequency callers should trade as the manager owner.
public struct PredictTradeCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Return the trade cap object ID.
public fun id(cap: &PredictTradeCap): ID {
    cap.id.to_inner()
}

/// Return the `PredictManager` this cap was minted for.
public fun predict_manager_id(cap: &PredictTradeCap): ID {
    cap.predict_manager_id
}

/// Destroy a `PredictTradeCap` the holder no longer needs.
public fun destroy(cap: PredictTradeCap) {
    let PredictTradeCap { id, .. } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Construct a cap. Allow-listing and the owner check are
/// `predict_manager`'s job.
public(package) fun new(predict_manager_id: ID, ctx: &mut TxContext): PredictTradeCap {
    PredictTradeCap { id: object::new(ctx), predict_manager_id }
}
