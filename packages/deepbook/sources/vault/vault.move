module deepbook::vault {
    use std::type_name::{Self, TypeName};

    use sui::balance::{Self, Balance};

    use deepbook::{
        math,
        account::{Account, TradeProof},
        deep_price::{Self, DeepPrice},
        account_data::AccountData,
        order_info::OrderInfo,
        balances::Self,
    };

    const EIneligibleTargetPool: u64 = 1;

    public struct DEEP has store {}

    public struct Vault<phantom BaseAsset, phantom QuoteAsset> has store {
        base_balance: Balance<BaseAsset>,
        quote_balance: Balance<QuoteAsset>,
        deep_balance: Balance<DEEP>,
        deep_price: DeepPrice,
    }

    public(package) fun empty<BaseAsset, QuoteAsset>(): Vault<BaseAsset, QuoteAsset> {
        Vault {
            base_balance: balance::zero(),
            quote_balance: balance::zero(),
            deep_balance: balance::zero(),
            deep_price: deep_price::empty(),
        }
    }

    /// Transfer any settled amounts for the account.
    public(package) fun settle_account<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        account_data: &mut AccountData,
        account: &mut Account,
        proof: &TradeProof,
    ) {
        let (balances_out, balances_in) = account_data.settle();
        if (balances_out.base() > balances_in.base()) {
            let balance = self.base_balance.split(balances_out.base() - balances_in.base());
            account.deposit_with_proof(proof, balance);
        };
        if (balances_out.quote() > balances_in.quote()) {
            let balance = self.quote_balance.split(balances_out.quote() - balances_in.quote());
            account.deposit_with_proof(proof, balance);
        };
        if (balances_out.deep() > balances_in.deep()) {
            let balance = self.deep_balance.split(balances_out.deep() - balances_in.deep());
            account.deposit_with_proof(proof, balance);
        };
        if (balances_in.base() > balances_out.base()) {
            let balance = account.withdraw_with_proof(proof, balances_in.base() - balances_out.base(), false);
            self.base_balance.join(balance);
        };
        if (balances_in.quote() > balances_out.quote()) {
            let balance = account.withdraw_with_proof(proof, balances_in.quote() - balances_out.quote(), false);
            self.quote_balance.join(balance);
        };
        if (balances_in.deep() > balances_out.deep()) {
            let balance = account.withdraw_with_proof(proof, balances_in.deep() - balances_out.deep(), false);
            self.deep_balance.join(balance);
        };
    }

    /// Given an order, settle its balances. Up until this point, any partial fills have been executed
    /// and the remaining quantity is the only quantity left to be injected into the order book.
    /// 1. Calculate the maker and taker fee for this account.
    /// 2. Calculate the total fees for the maker and taker portion of the order.
    /// 3. Add to the account's settled and owed balances.
    public(package) fun settle_order<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>,
        order_info: &mut OrderInfo,
        account_data: &mut AccountData,
    ) {
        let base_to_deep = self.deep_price.conversion_rate();
        let total_volume = account_data.taker_volume() + account_data.maker_volume();
        let volume_in_deep = math::mul(total_volume, base_to_deep);
        let trade_params = order_info.trade_params();
        let taker_fee = trade_params.taker_fee();
        let maker_fee = trade_params.maker_fee();
        let stake_required = trade_params.stake_required();
        let taker_fee = if (account_data.active_stake() >= stake_required && volume_in_deep >= stake_required) {
            math::mul(taker_fee, 500_000_000)
        } else {
            taker_fee
        };

        let executed_quantity = order_info.executed_quantity();
        let remaining_quantity = order_info.remaining_quantity();
        let cumulative_quote_quantity = order_info.cumulative_quote_quantity();
        let deep_in = math::mul(order_info.deep_per_base(), math::mul(executed_quantity, taker_fee));
        order_info.set_paid_fees(deep_in);

        let settled_balances;
        let owed_balances;

        if (order_info.is_bid()) {
            settled_balances = balances::new(executed_quantity, 0, 0);
            owed_balances = balances::new(0, cumulative_quote_quantity, deep_in);
        } else {
            settled_balances = balances::new(0, cumulative_quote_quantity, 0);
            owed_balances = balances::new(executed_quantity, 0, deep_in);
        };

        account_data.add_settled_amounts(settled_balances);
        account_data.add_owed_amounts(owed_balances);

        // Maker Part of Settling Order
        if (remaining_quantity > 0 && !order_info.is_immediate_or_cancel()) {
            let deep_in = math::mul(order_info.deep_per_base(), math::mul(remaining_quantity, maker_fee));
            let owed_balances = if (order_info.is_bid()) {
                balances::new(0, math::mul(remaining_quantity, order_info.price()), deep_in)
            } else {
                balances::new(remaining_quantity, 0, deep_in)
            };
            account_data.add_owed_amounts(owed_balances);
        };
    }

    /// Adds a price point along with a timestamp to the deep price.
    /// Allows for the calculation of deep price per base asset.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        deep_price: u64,
        pool_price: u64,
        deep_base_type: TypeName,
        deep_quote_type: TypeName,
        timestamp: u64,
    ) {
        let base_type = type_name::get<BaseAsset>();
        let quote_type = type_name::get<QuoteAsset>();
        let deep_type = type_name::get<DEEP>();
        if (base_type == deep_type) {
            return self.deep_price.add_price_point(1, timestamp)
        };
        if (quote_type == deep_type) {
            return self.deep_price.add_price_point(pool_price, timestamp)
        };

        assert!((base_type == deep_base_type || base_type == deep_quote_type) ||
                (quote_type == deep_base_type || quote_type == deep_quote_type), EIneligibleTargetPool);
        assert!(!(base_type == deep_base_type && quote_type == deep_quote_type), EIneligibleTargetPool);

        let deep_per_base = if (base_type == deep_base_type) {
            deep_price
        } else if (base_type == deep_quote_type) {
            math::div(1, deep_price)
        } else if (quote_type == deep_base_type) {
            math::mul(deep_price, pool_price)
        } else {
            math::div(deep_price, pool_price)
        };

        self.deep_price.add_price_point(deep_per_base, timestamp)
    }
}
