
<a name="0x0_vault"></a>

# Module `0x0::vault`

The vault holds all of the assets for this pool. At the end of all
transaction processing, the vault is used to settle the balances for the user.


-  [Struct `Vault`](#0x0_vault_Vault)
-  [Struct `FlashLoanHotPotato`](#0x0_vault_FlashLoanHotPotato)
-  [Constants](#@Constants_0)
-  [Function `balances`](#0x0_vault_balances)
-  [Function `empty`](#0x0_vault_empty)
-  [Function `settle_balance_manager`](#0x0_vault_settle_balance_manager)
-  [Function `withdraw_deep_to_burn`](#0x0_vault_withdraw_deep_to_burn)
-  [Function `borrow_flashloan`](#0x0_vault_borrow_flashloan)
-  [Function `return_flashloan`](#0x0_vault_return_flashloan)


<pre><code><b>use</b> <a href="balance_manager.md#0x0_balance_manager">0x0::balance_manager</a>;
<b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep</a>;
</code></pre>



<a name="0x0_vault_Vault"></a>

## Struct `Vault`



<pre><code><b>struct</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>base_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;BaseAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;QuoteAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_vault_FlashLoanHotPotato"></a>

## Struct `FlashLoanHotPotato`



<pre><code><b>struct</b> <a href="vault.md#0x0_vault_FlashLoanHotPotato">FlashLoanHotPotato</a>
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>base_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_amount: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_vault_EIncorrectPool"></a>



<pre><code><b>const</b> <a href="vault.md#0x0_vault_EIncorrectPool">EIncorrectPool</a>: u64 = 4;
</code></pre>



<a name="0x0_vault_ENotEnoughBase"></a>



<pre><code><b>const</b> <a href="vault.md#0x0_vault_ENotEnoughBase">ENotEnoughBase</a>: u64 = 1;
</code></pre>



<a name="0x0_vault_ENotEnoughQuote"></a>



<pre><code><b>const</b> <a href="vault.md#0x0_vault_ENotEnoughQuote">ENotEnoughQuote</a>: u64 = 2;
</code></pre>



<a name="0x0_vault_balances"></a>

## Function `balances`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances">balances</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances">balances</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;
): (u64, u64, u64) {
    (self.base_balance.value(), self.quote_balance.value(), self.deep_balance.value())
}
</code></pre>



</details>

<a name="0x0_vault_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_empty">empty</a>&lt;BaseAsset, QuoteAsset&gt;(): <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_empty">empty</a>&lt;BaseAsset, QuoteAsset&gt;(): <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt; {
    <a href="vault.md#0x0_vault_Vault">Vault</a> {
        base_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        quote_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        deep_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
    }
}
</code></pre>



</details>

<a name="0x0_vault_settle_balance_manager"></a>

## Function `settle_balance_manager`

Transfer any settled amounts for the <code><a href="balance_manager.md#0x0_balance_manager">balance_manager</a></code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_balance_manager">settle_balance_manager</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, balances_out: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, balances_in: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_balance_manager">settle_balance_manager</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    balances_out: Balances,
    balances_in: Balances,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    ctx: &TxContext,
) {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.validate_trader(ctx);
    <b>if</b> (balances_out.base() &gt; balances_in.base()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.base_balance.split(balances_out.base() - balances_in.base());
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.deposit_protected(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>, ctx);
    };
    <b>if</b> (balances_out.quote() &gt; balances_in.quote()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.quote_balance.split(balances_out.quote() - balances_in.quote());
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.deposit_protected(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>, ctx);
    };
    <b>if</b> (balances_out.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>() &gt; balances_in.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.deep_balance.split(balances_out.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>() - balances_in.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>());
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.deposit_protected(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>, ctx);
    };
    <b>if</b> (balances_in.base() &gt; balances_out.base()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.withdraw_protected(balances_in.base() - balances_out.base(), <b>false</b>, ctx);
        self.base_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_in.quote() &gt; balances_out.quote()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.withdraw_protected(balances_in.quote() - balances_out.quote(), <b>false</b>, ctx);
        self.quote_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_in.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>() &gt; balances_out.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.withdraw_protected(balances_in.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>() - balances_out.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>(), <b>false</b>, ctx);
        self.deep_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
}
</code></pre>



</details>

<a name="0x0_vault_withdraw_deep_to_burn"></a>

## Function `withdraw_deep_to_burn`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_withdraw_deep_to_burn">withdraw_deep_to_burn</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, amount_to_burn: u64): <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_withdraw_deep_to_burn">withdraw_deep_to_burn</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    amount_to_burn: u64,
): Balance&lt;DEEP&gt; {
    self.deep_balance.split(amount_to_burn)
}
</code></pre>



</details>

<a name="0x0_vault_borrow_flashloan"></a>

## Function `borrow_flashloan`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_borrow_flashloan">borrow_flashloan</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, base_amount: u64, quote_amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="vault.md#0x0_vault_FlashLoanHotPotato">vault::FlashLoanHotPotato</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_borrow_flashloan">borrow_flashloan</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    pool_id: ID,
    base_amount: u64,
    quote_amount: u64,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, <a href="vault.md#0x0_vault_FlashLoanHotPotato">FlashLoanHotPotato</a>) {
    <b>assert</b>!(self.base_balance.value() &gt;= base_amount, <a href="vault.md#0x0_vault_ENotEnoughBase">ENotEnoughBase</a>);
    <b>assert</b>!(self.quote_balance.value() &gt;= quote_amount, <a href="vault.md#0x0_vault_ENotEnoughQuote">ENotEnoughQuote</a>);

    <b>let</b> base = self.base_balance.split(base_amount).into_coin(ctx);
    <b>let</b> quote = self.quote_balance.split(quote_amount).into_coin(ctx);
    <b>let</b> hot_potato = <a href="vault.md#0x0_vault_FlashLoanHotPotato">FlashLoanHotPotato</a> {
        pool_id,
        base_amount,
        quote_amount,
    };

    (base, quote, hot_potato)
}
</code></pre>



</details>

<a name="0x0_vault_return_flashloan"></a>

## Function `return_flashloan`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_return_flashloan">return_flashloan</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, base: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, quote: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, hot_potato: <a href="vault.md#0x0_vault_FlashLoanHotPotato">vault::FlashLoanHotPotato</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_return_flashloan">return_flashloan</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    pool_id: ID,
    base: Coin&lt;BaseAsset&gt;,
    quote: Coin&lt;QuoteAsset&gt;,
    hot_potato: <a href="vault.md#0x0_vault_FlashLoanHotPotato">FlashLoanHotPotato</a>,
) {
    <b>assert</b>!(base.value() == hot_potato.base_amount, <a href="vault.md#0x0_vault_ENotEnoughBase">ENotEnoughBase</a>);
    <b>assert</b>!(quote.value() == hot_potato.quote_amount, <a href="vault.md#0x0_vault_ENotEnoughQuote">ENotEnoughQuote</a>);
    <b>assert</b>!(pool_id == hot_potato.pool_id, <a href="vault.md#0x0_vault_EIncorrectPool">EIncorrectPool</a>);

    self.base_balance.join(base.into_balance());
    self.quote_balance.join(quote.into_balance());

    <b>let</b> <a href="vault.md#0x0_vault_FlashLoanHotPotato">FlashLoanHotPotato</a> {
        pool_id: _,
        base_amount: _,
        quote_amount: _,
    } = hot_potato;
}
</code></pre>



</details>
