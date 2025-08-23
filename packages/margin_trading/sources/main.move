module margin_trading::main;

use margin_trading::accounting::Accounting;
use margin_trading::supply_state::SupplyState;
use margin_trading::margin_registry::MarginAdminCap;
use margin_trading::referral_manager2::ReferralCap;
use deepbook::math;
use sui::balance::Balance;
use sui::coin::Coin;
use sui::clock::Clock;

public struct Main<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    accounting: Accounting,
    supply_state: SupplyState,
    protocol_spread: u64,
    protocol_profit: u64,
}

public fun supply<Asset>(
    self: &mut Main<Asset>,
    coin: Coin<Asset>,
    referral: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.update_accounting(clock);
    let new_supply_shares = self.accounting.increase_total_supply_shares(coin.value());
    self.supply_state.supply(ctx.sender(), new_supply_shares, referral, clock);
    self.vault.join(coin.into_balance());
}

public fun withdraw<Asset>(
    self: &mut Main<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    self.update_accounting(clock);
    let shares = if (amount.is_some()) {
        option::some(self.accounting.to_supply_shares(amount.destroy_some()))
    } else {
        option::none()
    };
    let shares = self.supply_state.withdraw(ctx.sender(), shares, clock);
    let amount = self.accounting.to_supply_amount(shares);

    self.vault.split(amount).into_coin(ctx)
}

public fun mint_referral_cap<Asset>(
    self: &mut Main<Asset>,
    _cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): ReferralCap {
    self.update_accounting(clock);
    self.supply_state.referral_manager_mut().mint_referral_cap(self.accounting.supply_index(), clock, ctx)
}

public fun claim_referral_rewards<Asset>(
    self: &mut Main<Asset>,
    referral_cap: &ReferralCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    self.update_accounting(clock);
    let share_value_appreciated = self.supply_state.referral_manager_mut().claim_referral_rewards(referral_cap.id(), self.accounting.supply_index(), clock);
    let reward_amount = math::mul(share_value_appreciated, self.protocol_spread);
    self.protocol_profit = self.protocol_profit - reward_amount;

    self.vault.split(reward_amount).into_coin(ctx)
}

fun update_accounting<Asset>(self: &mut Main<Asset>, clock: &Clock) {
    let total_interest_accrued = self.accounting.update(clock);
    let protocol_profit = math::mul(total_interest_accrued, self.protocol_spread);
    self.protocol_profit = self.protocol_profit + protocol_profit;
    self.accounting.decrease_total_supply_absolute(protocol_profit);
}