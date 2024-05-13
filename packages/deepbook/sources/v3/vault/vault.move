module deepbook::v3vault {
    use sui::balance::{Self, Balance};

    use deepbook::{
        math,
        v3account::{Account, TradeProof},
        v3deep_price::{Self, DeepPrice},
        v3user::User,
        v3order::OrderInfo,
    };

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
            deep_price: v3deep_price::empty(),
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

    /// Given an order, transfer the appropriate balances. Up until this point, any partial fills have been executed
    /// and the remaining quantity is the only quantity left to be injected into the order book.
    /// 1. Transfer the taker balances while applying taker fees.
    /// 2. Transfer the maker balances while applying maker fees.
    /// 3. Update the total fees for the order.
    public(package) fun settle_order<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>,
        order_info: &OrderInfo,
        user: &mut User,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    ) {
        let (mut base_in, mut base_out) = (0, 0);
        let (mut quote_in, mut quote_out) = (0, 0);
        let mut deep_in = 0;
        let taker_fee = if (user.active_stake() >= stake_required) {
            taker_fee / 2
        } else {
            taker_fee
        };
        let executed_quantity = order_info.executed_quantity();
        let remaining_quantity = order_info.remaining_quantity();
        let cumulative_quote_quantity = order_info.cumulative_quote_quantity();

        // Calculate the taker balances. These are derived from executed quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_price.calculate_fees(taker_fee, 0, cumulative_quote_quantity)
        } else {
            self.deep_price.calculate_fees(taker_fee, executed_quantity, 0)
        };
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + cumulative_quote_quantity + quote_fee;
            base_out = base_out + executed_quantity;
        } else {
            base_in = base_in + executed_quantity + base_fee;
            quote_out = quote_out + cumulative_quote_quantity;
        };

        // Calculate the maker balances. These are derived from the remaining quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_price.calculate_fees(maker_fee, 0, math::mul(remaining_quantity, order_info.price()))
        } else {
            self.deep_price.calculate_fees(maker_fee, remaining_quantity, 0)
        };
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + math::mul(remaining_quantity, order_info.price()) + quote_fee;
        } else {
            base_in = base_in + remaining_quantity + base_fee;
        };

        user.add_settled_amounts(base_out, quote_out, 0);
        user.add_owed_amounts(base_in, quote_in, deep_in);
    }
}