// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The vault holds all of the assets for this pool. At the end of all
/// transaction processing, the vault is used to settle the balances for the user.
module deepbook::vault {
    // === Imports ===
    use sui::{
        balance::{Self, Balance},
        coin::Coin,
    };
    use deepbook::{
        balance_manager::BalanceManager,
        balances::Balances,
    };
    use token::deep::DEEP;

    // === Errors ===
    const ENotEnoughBaseForLoan: u64 = 1;
    const ENotEnoughQuoteForLoan: u64 = 2;
    const EInvalidLoanAmounts: u64 = 3;
    const EIncorrectBaseReturned: u64 = 4;
    const EIncorrectQuoteReturned: u64 = 5;
    const EIncorrectLoanPool: u64 = 6;

    // === Structs ===
    public struct Vault<phantom BaseAsset, phantom QuoteAsset> has store {
        base_balance: Balance<BaseAsset>,
        quote_balance: Balance<QuoteAsset>,
        deep_balance: Balance<DEEP>,
    }

    public struct FlashLoan {
        pool_id: ID,
        base_amount: u64,
        quote_amount: u64,
    }

    // === Public-Package Functions ===
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

    /// Transfer any settled amounts for the `balance_manager`.
    public(package) fun settle_balance_manager<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        balances_out: Balances,
        balances_in: Balances,
        balance_manager: &mut BalanceManager,
        ctx: &TxContext,
    ) {
        balance_manager.validate_trader(ctx);
        if (balances_out.base() > balances_in.base()) {
            let balance = self.base_balance.split(balances_out.base() - balances_in.base());
            balance_manager.deposit_protected(balance, ctx);
        };
        if (balances_out.quote() > balances_in.quote()) {
            let balance = self.quote_balance.split(balances_out.quote() - balances_in.quote());
            balance_manager.deposit_protected(balance, ctx);
        };
        if (balances_out.deep() > balances_in.deep()) {
            let balance = self.deep_balance.split(balances_out.deep() - balances_in.deep());
            balance_manager.deposit_protected(balance, ctx);
        };
        if (balances_in.base() > balances_out.base()) {
            let balance = balance_manager.withdraw_protected(balances_in.base() - balances_out.base(), false, ctx);
            self.base_balance.join(balance);
        };
        if (balances_in.quote() > balances_out.quote()) {
            let balance = balance_manager.withdraw_protected(balances_in.quote() - balances_out.quote(), false, ctx);
            self.quote_balance.join(balance);
        };
        if (balances_in.deep() > balances_out.deep()) {
            let balance = balance_manager.withdraw_protected(balances_in.deep() - balances_out.deep(), false, ctx);
            self.deep_balance.join(balance);
        };
    }

    public(package) fun withdraw_deep_to_burn<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        amount_to_burn: u64,
    ): Balance<DEEP> {
        self.deep_balance.split(amount_to_burn)
    }

    public(package) fun borrow_flashloan<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        pool_id: ID,
        base_amount: u64,
        quote_amount: u64,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>, FlashLoan) {
        assert!(self.base_balance.value() >= base_amount, ENotEnoughBaseForLoan);
        assert!(self.quote_balance.value() >= quote_amount, ENotEnoughQuoteForLoan);
        assert!(base_amount > 0 || quote_amount > 0, EInvalidLoanAmounts);

        let base = self.base_balance.split(base_amount).into_coin(ctx);
        let quote = self.quote_balance.split(quote_amount).into_coin(ctx);
        let flash_loan = FlashLoan {
            pool_id,
            base_amount,
            quote_amount,
        };

        (base, quote, flash_loan)
    }

    public(package) fun return_flashloan<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        pool_id: ID,
        base: Coin<BaseAsset>,
        quote: Coin<QuoteAsset>,
        flash_loan: FlashLoan,
    ) {
        assert!(base.value() == flash_loan.base_amount, EIncorrectBaseReturned);
        assert!(quote.value() == flash_loan.quote_amount, EIncorrectQuoteReturned);
        assert!(pool_id == flash_loan.pool_id, EIncorrectLoanPool);

        self.base_balance.join(base.into_balance());
        self.quote_balance.join(quote.into_balance());

        let FlashLoan {
            pool_id: _,
            base_amount: _,
            quote_amount: _,
        } = flash_loan;
    }
}
