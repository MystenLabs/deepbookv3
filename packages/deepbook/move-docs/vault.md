
<a name="0x0_vault"></a>

# Module `0x0::vault`



-  [Struct `DEEP`](#0x0_vault_DEEP)
-  [Struct `Vault`](#0x0_vault_Vault)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_vault_empty)
-  [Function `settle_account`](#0x0_vault_settle_account)
-  [Function `settle_order`](#0x0_vault_settle_order)
-  [Function `add_deep_price_point`](#0x0_vault_add_deep_price_point)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="account_data.md#0x0_account_data">0x0::account_data</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
<b>use</b> <a href="dependencies/move-stdlib/type_name.md#0x1_type_name">0x1::type_name</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
</code></pre>



<a name="0x0_vault_DEEP"></a>

## Struct `DEEP`



<pre><code><b>struct</b> <a href="vault.md#0x0_vault_DEEP">DEEP</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>dummy_field: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

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
<code>deep_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="vault.md#0x0_vault_DEEP">vault::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_vault_EIneligibleTargetPool"></a>



<pre><code><b>const</b> <a href="vault.md#0x0_vault_EIneligibleTargetPool">EIneligibleTargetPool</a>: u64 = 1;
</code></pre>



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
        <a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_empty">deep_price::empty</a>(),
    }
}
</code></pre>



</details>

<a name="0x0_vault_settle_account"></a>

## Function `settle_account`

Transfer any settled amounts for the account.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_account">settle_account</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account_data.md#0x0_account_data">account_data</a>: &<b>mut</b> <a href="account_data.md#0x0_account_data_AccountData">account_data::AccountData</a>, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_account">settle_account</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account_data.md#0x0_account_data">account_data</a>: &<b>mut</b> AccountData,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
) {
    <b>let</b> (base_out, quote_out, deep_out, base_in, quote_in, deep_in) = <a href="account_data.md#0x0_account_data">account_data</a>.settle();
    <b>if</b> (base_out &gt; base_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.base_balance.split(base_out - base_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (quote_out &gt; quote_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.quote_balance.split(quote_out - quote_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (deep_out &gt; deep_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.deep_balance.split(deep_out - deep_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (base_in &gt; base_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, base_in - base_out, <b>false</b>);
        self.base_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (quote_in &gt; quote_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, quote_in - quote_out, <b>false</b>);
        self.quote_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (deep_in &gt; deep_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, deep_in - deep_out, <b>false</b>);
        self.deep_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
}
</code></pre>



</details>

<a name="0x0_vault_settle_order"></a>

## Function `settle_order`

Given an order, settle its balances. Up until this point, any partial fills have been executed
and the remaining quantity is the only quantity left to be injected into the order book.
1. Calculate the maker and taker fee for this account.
2. Calculate the total fees for the maker and taker portion of the order.
3. Add to the account's settled and owed balances.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_order">settle_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="order_info.md#0x0_order_info">order_info</a>: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, <a href="account_data.md#0x0_account_data">account_data</a>: &<b>mut</b> <a href="account_data.md#0x0_account_data_AccountData">account_data::AccountData</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_order">settle_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="order_info.md#0x0_order_info">order_info</a>: &OrderInfo,
    <a href="account_data.md#0x0_account_data">account_data</a>: &<b>mut</b> AccountData,
) {
    <b>let</b> base_to_deep = self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.conversion_rate();
    <b>let</b> total_volume = <a href="account_data.md#0x0_account_data">account_data</a>.taker_volume() + <a href="account_data.md#0x0_account_data">account_data</a>.maker_volume();
    <b>let</b> volume_in_deep = <a href="math.md#0x0_math_mul">math::mul</a>(total_volume, base_to_deep);
    <b>let</b> <a href="trade_params.md#0x0_trade_params">trade_params</a> = <a href="order_info.md#0x0_order_info">order_info</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>();
    <b>let</b> taker_fee = <a href="trade_params.md#0x0_trade_params">trade_params</a>.taker_fee();
    <b>let</b> maker_fee = <a href="trade_params.md#0x0_trade_params">trade_params</a>.maker_fee();
    <b>let</b> stake_required = <a href="trade_params.md#0x0_trade_params">trade_params</a>.stake_required();
    <b>let</b> taker_fee = <b>if</b> (<a href="account_data.md#0x0_account_data">account_data</a>.active_stake() &gt;= stake_required && volume_in_deep &gt;= stake_required) {
        <a href="math.md#0x0_math_div">math::div</a>(taker_fee, 2)
    } <b>else</b> {
        taker_fee
    };

    <b>let</b> executed_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.executed_quantity();
    <b>let</b> remaining_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.remaining_quantity();
    <b>let</b> cumulative_quote_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.cumulative_quote_quantity();
    <b>let</b> deep_in = <a href="math.md#0x0_math_mul">math::mul</a>(<a href="order_info.md#0x0_order_info">order_info</a>.deep_per_base(), <a href="math.md#0x0_math_mul">math::mul</a>(executed_quantity, taker_fee));

    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
        <a href="account_data.md#0x0_account_data">account_data</a>.add_settled_amounts(executed_quantity, 0, 0);
        <a href="account_data.md#0x0_account_data">account_data</a>.add_owed_amounts(0, cumulative_quote_quantity, deep_in);
    } <b>else</b> {
        <a href="account_data.md#0x0_account_data">account_data</a>.add_settled_amounts(0, cumulative_quote_quantity, 0);
        <a href="account_data.md#0x0_account_data">account_data</a>.add_owed_amounts(executed_quantity, 0, deep_in);
    };

    // Maker Part of Settling Order
    <b>if</b> (remaining_quantity &gt; 0 && !<a href="order_info.md#0x0_order_info">order_info</a>.is_immediate_or_cancel()) {
        <b>let</b> deep_in = <a href="math.md#0x0_math_mul">math::mul</a>(<a href="order_info.md#0x0_order_info">order_info</a>.deep_per_base(), <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, maker_fee));
        <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
            <a href="account_data.md#0x0_account_data">account_data</a>.add_owed_amounts(0, <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, <a href="order_info.md#0x0_order_info">order_info</a>.price()), deep_in);
        } <b>else</b> {
            <a href="account_data.md#0x0_account_data">account_data</a>.add_owed_amounts(remaining_quantity, 0, deep_in);
        };
    };
}
</code></pre>



</details>

<a name="0x0_vault_add_deep_price_point"></a>

## Function `add_deep_price_point`

Adds a price point along with a timestamp to the deep price.
Allows for the calculation of deep price per base asset.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="deep_price.md#0x0_deep_price">deep_price</a>: u64, pool_price: u64, deep_base_type: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a>, deep_quote_type: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="deep_price.md#0x0_deep_price">deep_price</a>: u64,
    pool_price: u64,
    deep_base_type: TypeName,
    deep_quote_type: TypeName,
    timestamp: u64,
) {
    <b>let</b> base_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;();
    <b>let</b> quote_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;<a href="vault.md#0x0_vault_DEEP">DEEP</a>&gt;();
    <b>if</b> (base_type == deep_type) {
        <b>return</b> self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(1, timestamp)
    };
    <b>if</b> (quote_type == deep_type) {
        <b>return</b> self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(pool_price, timestamp)
    };

    <b>assert</b>!((base_type == deep_base_type || base_type == deep_quote_type) ||
            (quote_type == deep_base_type || quote_type == deep_quote_type), <a href="vault.md#0x0_vault_EIneligibleTargetPool">EIneligibleTargetPool</a>);
    <b>assert</b>!(!(base_type == deep_base_type && quote_type == deep_quote_type), <a href="vault.md#0x0_vault_EIneligibleTargetPool">EIneligibleTargetPool</a>);

    <b>let</b> deep_per_base = <b>if</b> (base_type == deep_base_type) {
        <a href="deep_price.md#0x0_deep_price">deep_price</a>
    } <b>else</b> <b>if</b> (base_type == deep_quote_type) {
        <a href="math.md#0x0_math_div">math::div</a>(1, <a href="deep_price.md#0x0_deep_price">deep_price</a>)
    } <b>else</b> <b>if</b> (quote_type == deep_base_type) {
        <a href="math.md#0x0_math_mul">math::mul</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price)
    } <b>else</b> {
        <a href="math.md#0x0_math_div">math::div</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price)
    };

    self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(deep_per_base, timestamp)
}
</code></pre>



</details>
