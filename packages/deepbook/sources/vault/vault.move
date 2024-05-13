module deepbook::vault {
    use std::type_name::{Self, TypeName};

    use sui::balance::{Self, Balance};

    use deepbook::{
        math,
        account::{Account, TradeProof},
        deep_price::{Self, DeepPrice},
        user::User,
        order::OrderInfo,
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

    /// Transfer any settled amounts for the user.
    public(package) fun settle_user<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        user: &mut User,
        account: &mut Account,
        proof: &TradeProof,
    ) {
        let (base_out, quote_out, deep_out, base_in, quote_in, deep_in) = user.settle();
        if (base_out > base_in) {
            let balance = self.base_balance.split(base_out - base_in);
            account.deposit_with_proof(proof, balance);
        };
        if (quote_out > quote_in) {
            let balance = self.quote_balance.split(quote_out - quote_in);
            account.deposit_with_proof(proof, balance);
        };
        if (deep_out > deep_in) {
            let balance = self.deep_balance.split(deep_out - deep_in);
            account.deposit_with_proof(proof, balance);
        };
        if (base_in > base_out) {
            let balance = account.withdraw_with_proof(proof, base_in - base_out, false);
            self.base_balance.join(balance);
        };
        if (quote_in > quote_out) {
            let balance = account.withdraw_with_proof(proof, quote_in - quote_out, false);
            self.quote_balance.join(balance);
        };
        if (deep_in > deep_out) {
            let balance = account.withdraw_with_proof(proof, deep_in - deep_out, false);
            self.deep_balance.join(balance);
        };
    }

    /// Given an order, settle its balances. Up until this point, any partial fills have been executed
    /// and the remaining quantity is the only quantity left to be injected into the order book.
    /// 1. Calculate the maker and taker fee for this user.
    /// 2. Calculate the total fees for the maker and taker portion of the order.
    /// 3. Add to the user's settled and owed balances.
    public(package) fun settle_order<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>,
        order_info: &OrderInfo,
        user: &mut User,
    ) {
        let base_to_deep = self.deep_price.conversion_rate();
        let total_volume = user.taker_volume() + user.maker_volume();
        let volume_in_deep = math::mul(total_volume, base_to_deep);
        let (taker_fee, maker_fee, stake_required) = order_info.trade_params().params();
        let taker_fee = if (user.active_stake() >= stake_required && volume_in_deep >= stake_required) {
            math::div(taker_fee, 2)
        } else {
            taker_fee
        };

        let executed_quantity = order_info.executed_quantity();
        let remaining_quantity = order_info.remaining_quantity();
        let cumulative_quote_quantity = order_info.cumulative_quote_quantity();
        let deep_in = math::mul(executed_quantity, maker_fee) + math::mul(remaining_quantity, taker_fee);

        if (order_info.is_bid()) {
            user.add_settled_amounts(executed_quantity, 0, 0);
            user.add_owed_amounts(0, cumulative_quote_quantity, deep_in);
        } else {
            user.add_settled_amounts(0, cumulative_quote_quantity, 0);
            user.add_owed_amounts(executed_quantity, 0, deep_in);
        };
    }

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