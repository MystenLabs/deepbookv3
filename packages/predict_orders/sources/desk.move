// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The order-flow companion's shared `OrderDesk`: the delayed-execution policy
/// every market queue runs under, and the companion's version floor.
///
/// One desk per deployment: `init` creates and shares it when the package is
/// published, and nothing else builds one. Each market's `MarketQueue` sits at
/// an ID derived from the desk and the market (`queue::create_and_share`), so a
/// single desk gives each market exactly one queue, and with it one per-account
/// cap, stuck gate, policy, and version floor. The desk exists before Predict
/// allowlists this package's witness; until `protocol_config::set_order_flow`
/// does, Predict's admission, commit, and fill primitives refuse the companion.
///
/// Predict's `AdminCap` administers the desk. Its setters check the desk floor
/// and refuse while Predict is frozen, through the public
/// `protocol_config::frozen`; the policy cannot move funds, and every Predict
/// invariant holds inside Predict's primitives whatever it says. Only queue
/// creation takes the desk mutably, so trading never serializes on it.
module deepbook_predict_orders::desk;

use deepbook_predict::{admin::AdminCap, protocol_config::ProtocolConfig};
use deepbook_predict_orders::{
    delayed_execution_config::{Self, DelayedExecutionPolicy},
    queue_events
};
use sui::clock::Clock;

const EPackageVersionDisabled: u64 = 0;
const EVersionWatermarkNotAdvanced: u64 = 1;
const EProtocolFrozen: u64 = 2;

/// The companion's compiled version, compared against the desk floor.
public macro fun current_version(): u64 { 1 }

/// The shared policy and version floor of one order-flow companion deployment.
public struct OrderDesk has key {
    id: UID,
    policy: DelayedExecutionPolicy,
    /// Minimum companion version permitted to run. Monotonic;
    /// `bump_version_watermark` advances it to the running `current_version!()`,
    /// retiring older companion code.
    version_watermark: u64,
}

/// Create and share the deployment's one desk at publish, with the launch
/// policy and the launch floor. Emits no `DelayedExecutionPolicyUpdated`:
/// `init` has no `Clock` for its `onchain_timestamp_ms`, and the launch policy
/// is the desk's state in the publish transaction. Every setter emits the
/// complete policy from then on.
fun init(ctx: &mut TxContext) {
    transfer::share_object(OrderDesk {
        id: object::new(ctx),
        policy: delayed_execution_config::new(),
        version_watermark: current_version!(),
    });
}

// === Public Functions ===

/// Return the desk object ID for external discovery and PTB construction.
public fun id(desk: &OrderDesk): ID {
    desk.id.to_inner()
}

/// Return the policy, for SDK and devInspect reads.
public fun policy(desk: &OrderDesk): DelayedExecutionPolicy {
    desk.policy
}

/// Return the desk's version floor, for SDK and devInspect reads.
public fun version_watermark(desk: &OrderDesk): u64 {
    desk.version_watermark
}

/// Set every timing field and the Pyth channel in one call, so the relational
/// rules hold on the final state (`delayed_execution_config::set_timing`).
/// Waiting orders keep the τ, deadline, and channel they were placed with, so a
/// new delay, stall timeout, or channel reaches only new orders. Commit reads
/// the buffer and gap wait when it runs, so those also apply to waiting cohorts.
public fun set_timing(
    desk: &mut OrderDesk,
    _admin_cap: &AdminCap,
    config: &ProtocolConfig,
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
    svi_max_age_ms: u64,
    clock: &Clock,
) {
    desk.assert_admin_allowed(config);
    desk
        .policy
        .set_timing(
            delay_ms,
            stall_timeout_ms,
            stuck_threshold_ms,
            gap_wait_ms,
            pyth_price_buffer_ms,
            pyth_channel,
            svi_max_age_ms,
        );
    queue_events::emit_policy_updated(desk.id(), desk.policy, clock.timestamp_ms());
}

/// Set the queue capacities, the per-account cap, the minimum early sell, and
/// the two `settle_step` batch sizes. Lowering a capacity below the current
/// pending count only blocks new orders.
public fun set_limits(
    desk: &mut OrderDesk,
    _admin_cap: &AdminCap,
    config: &ProtocolConfig,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
    clock: &Clock,
) {
    desk.assert_admin_allowed(config);
    desk
        .policy
        .set_limits(
            mint_capacity,
            sell_capacity,
            per_account_cap,
            min_sell_quantity,
            settle_refund_batch,
            settle_payout_batch,
        );
    queue_events::emit_policy_updated(desk.id(), desk.policy, clock.timestamp_ms());
}

/// Set the flat fee charged per queued order, in USDC base units. Applies to
/// orders placed after the call; waiting orders keep the fee they paid.
public fun set_order_fee(
    desk: &mut OrderDesk,
    _admin_cap: &AdminCap,
    config: &ProtocolConfig,
    order_fee: u64,
    clock: &Clock,
) {
    desk.assert_admin_allowed(config);
    desk.policy.set_order_fee(order_fee);
    queue_events::emit_policy_updated(desk.id(), desk.policy, clock.timestamp_ms());
}

/// Advance the desk floor to this package's compiled `current_version!()`,
/// retiring older companion code. Aborts unless the executing version is above
/// the floor.
public fun bump_version_watermark(desk: &mut OrderDesk, _admin_cap: &AdminCap) {
    let version = current_version!();
    assert!(version > desk.version_watermark, EVersionWatermarkNotAdvanced);
    desk.version_watermark = version;
}

// === Public-Package Functions ===

/// Abort when the running companion version is below the desk floor.
public(package) fun assert_version(desk: &OrderDesk) {
    assert!(current_version!() >= desk.version_watermark, EPackageVersionDisabled);
}

public(package) fun policy_ref(desk: &OrderDesk): &DelayedExecutionPolicy {
    &desk.policy
}

/// The desk's UID, which each market's queue ID is derived from
/// (`queue::create_and_share` claims it inline, as Sui's object-construction
/// check requires).
public(package) fun uid_mut(desk: &mut OrderDesk): &mut UID {
    &mut desk.id
}

// === Private Functions ===

/// The desk floor, and no admin change while Predict is frozen.
fun assert_admin_allowed(desk: &OrderDesk, config: &ProtocolConfig) {
    desk.assert_version();
    assert!(!config.frozen(), EProtocolFrozen);
}

// === Test-Only Functions ===

#[test_only]
/// Run `init`: create and share a desk at the launch policy. Calling it again
/// shares another desk, which only the wrong-desk binding tests want.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
