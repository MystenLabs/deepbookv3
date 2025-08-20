module margin_trading::supply_manager;

use margin_trading::accounting::Accounting;
use deepbook::math;
use sui::clock::Clock;
use sui::table::{Self, Table};

public struct SupplyManager has store {
    supplies: Table<address, Supply>,
}

public struct Supply has store {
    supply_shares: u64,
    share_seconds: u64,
    referral: Option<ID>,
    last_update_timestamp: u64,
}

public(package) fun default(ctx: &mut TxContext): SupplyManager {
    SupplyManager {
        supplies: table::new(ctx),
    }
}

public(package) fun increase_user_supply(
    self: &mut SupplyManager,
    user: address,
    shares: u64,
    referral: Option<ID>,
    clock: &Clock,
): (u64, Option<ID>, u64, Option<ID>) {
    self.add_supply_entry(user, clock);
    let supply = self.supplies.borrow_mut(user);
    supply.update_share_seconds(clock);

    let supply_shares_before = supply.supply_shares;
    let referral_before = supply.referral;
    supply.supply_shares = supply.supply_shares + shares;
    supply.referral = referral;

    (supply_shares_before, referral_before, shares, referral)
}

public(package) fun decrease_user_supply(
    self: &mut SupplyManager,
    user: address,
    shares: u64,
    clock: &Clock,
): (u64, Option<ID>) {
    let supply = self.supplies.borrow_mut(user);
    supply.update_share_seconds(clock);
    supply.supply_shares = supply.supply_shares - shares;

    (shares, supply.referral)
}

public(package) fun reset_share_seconds(self: &mut SupplyManager, user: address, clock: &Clock): u64 {
    let supply = self.supplies.borrow_mut(user);
    let share_seconds = supply.update_share_seconds(clock);
    supply.share_seconds = 0;
    supply.last_update_timestamp = clock.timestamp_ms();

    share_seconds
}

public(package) fun user_supply_shares(self: &SupplyManager, user: address): u64 {
    self.supplies.borrow(user).supply_shares
}

fun update_share_seconds(self: &mut Supply, clock: &Clock): u64 {
    let current_timestamp = clock.timestamp_ms();
    let elapsed_seconds = (current_timestamp - self.last_update_timestamp) / 1000;
    self.share_seconds = self.share_seconds + math::mul(self.supply_shares, elapsed_seconds);
    self.last_update_timestamp = current_timestamp;

    self.share_seconds
}

fun add_supply_entry(self: &mut SupplyManager, user: address, clock: &Clock) {
    if (!self.supplies.contains(user)) {
        self
            .supplies
            .add(
                user,
                Supply {
                    supply_shares: 0,
                    referral: option::none(),
                    share_seconds: 0,
                    last_update_timestamp: clock.timestamp_ms(),
                },
            );
    }
}