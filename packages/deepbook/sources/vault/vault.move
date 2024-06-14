module deepbook::vault {
    use sui::balance::{Self, Balance};

    use deepbook::{
        balance_manager::{BalanceManager, TradeProof},
        balances::Balances,
    };

    public struct DEEP has store {}

    public struct Vault<phantom BaseAsset, phantom QuoteAsset> has store {
        base_balance: Balance<BaseAsset>,
        quote_balance: Balance<QuoteAsset>,
        deep_balance: Balance<DEEP>,
    }

    public(package) fun balances<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>
    ): (u64, u64, u64) {
        (self.base_balance.value(), self.quote_balance.value(), self.deep_balance.value())
    }

    public(package) fun empty<BaseAsset, QuoteAsset>(): Vault<BaseAsset, QuoteAsset> {
        Vault {
            base_balance: balance::zero(),
            quote_balance: balance::zero(),
            deep_balance: balance::zero(),
        }
    }

    /// Transfer any settled amounts for the balance_manager.
    public(package) fun settle_balance_manager<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        balances_out: Balances,
        balances_in: Balances,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
    ) {
        if (balances_out.base() > balances_in.base()) {
            let balance = self.base_balance.split(balances_out.base() - balances_in.base());
            balance_manager.deposit_with_proof(proof, balance);
        };
        if (balances_out.quote() > balances_in.quote()) {
            let balance = self.quote_balance.split(balances_out.quote() - balances_in.quote());
            balance_manager.deposit_with_proof(proof, balance);
        };
        if (balances_out.deep() > balances_in.deep()) {
            let balance = self.deep_balance.split(balances_out.deep() - balances_in.deep());
            balance_manager.deposit_with_proof(proof, balance);
        };
        if (balances_in.base() > balances_out.base()) {
            let balance = balance_manager.withdraw_with_proof(proof, balances_in.base() - balances_out.base(), false);
            self.base_balance.join(balance);
        };
        if (balances_in.quote() > balances_out.quote()) {
            let balance = balance_manager.withdraw_with_proof(proof, balances_in.quote() - balances_out.quote(), false);
            self.quote_balance.join(balance);
        };
        if (balances_in.deep() > balances_out.deep()) {
            let balance = balance_manager.withdraw_with_proof(proof, balances_in.deep() - balances_out.deep(), false);
            self.deep_balance.join(balance);
        };
    }
}
