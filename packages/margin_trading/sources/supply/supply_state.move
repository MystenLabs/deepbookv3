module margin_trading::supply_state;

use margin_trading::accounting::{Self, Accounting};
use margin_trading::interest::InterestParams;
use margin_trading::referral_manager2::{Self, ReferralManager2};
use margin_trading::supply_config::SupplyConfig;
use margin_trading::supply_manager::{Self, SupplyManager};
use margin_trading::reward_manager2::{Self, RewardManager2};
use sui::clock::Clock;

public struct SupplyState has store {
    total_shares: u64,
    supply_manager: SupplyManager,
    referral_manager: ReferralManager2,
    reward_manager: RewardManager2,
    interest_params: InterestParams,
    supply_config: SupplyConfig,
}

public(package) fun default(
    clock: &Clock,
    interest_params: InterestParams,
    supply_config: SupplyConfig,
    ctx: &mut TxContext,
): SupplyState {
    SupplyState {
        total_shares: 0,
        supply_manager: supply_manager::default(ctx),
        referral_manager: referral_manager2::default(),
        reward_manager: reward_manager2::default(clock),
        interest_params,
        supply_config,
    }
}

public(package) fun supply(
    self: &mut SupplyState,
    user: address,
    shares: u64,
    referral: Option<ID>,
    clock: &Clock,
) {
    self.reward_manager.update(clock);
    self.total_shares = self.total_shares + shares;
    self.reward_manager.set_current_shares(self.total_shares);

    let (supply_shares_before, referral_before, supply_shares_after, referral_after) = self
        .supply_manager
        .increase_user_supply(user, shares, referral, clock);
    self.referral_manager.decrease_referral_supply_shares(referral_before, supply_shares_before, clock);
    self.referral_manager.increase_referral_supply_shares(referral_after, supply_shares_after, clock);
}

public(package) fun withdraw(
    self: &mut SupplyState,
    user: address,
    shares: Option<u64>,
    clock: &Clock,
): u64 {
    self.reward_manager.update(clock);

    let user_supply_shares = self.supply_manager.user_supply_shares(user);
    let shares = shares.get_with_default(user_supply_shares);
    self.total_shares = self.total_shares - shares;
    self.reward_manager.set_current_shares(self.total_shares);

    let (new_supply_shares, referral) = self.supply_manager.decrease_user_supply(user, shares, clock);
    self.referral_manager.decrease_referral_supply_shares(referral, new_supply_shares, clock);

    shares
}

public(package) fun referral_manager_mut(self: &mut SupplyState): &mut ReferralManager2 {
    &mut self.referral_manager
}
