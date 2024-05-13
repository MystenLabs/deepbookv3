
<a name="0x0_vault"></a>

# Module `0x0::vault`



-  [Struct `DEEP`](#0x0_vault_DEEP)
-  [Struct `Vault`](#0x0_vault_Vault)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_vault_empty)
-  [Function `settle_user`](#0x0_vault_settle_user)
-  [Function `settle_order`](#0x0_vault_settle_order)
-  [Function `add_deep_price_point`](#0x0_vault_add_deep_price_point)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
<b>use</b> <a href="user.md#0x0_user">0x0::user</a>;
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

<a name="0x0_vault_settle_user"></a>

## Function `settle_user`

Transfer any settled amounts for the user.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_user">settle_user</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="user.md#0x0_user">user</a>: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_user">settle_user</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="user.md#0x0_user">user</a>: &<b>mut</b> User,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
) {
    <b>let</b> (base_out, quote_out, deep_out, base_in, quote_in, deep_in) = <a href="user.md#0x0_user">user</a>.settle();
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

Given an order, transfer the appropriate balances. Up until this point, any partial fills have been executed
and the remaining quantity is the only quantity left to be injected into the order book.
1. Transfer the taker balances while applying taker fees.
2. Transfer the maker balances while applying maker fees.
3. Update the total fees for the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_order">settle_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="order_info.md#0x0_order_info">order_info</a>: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, <a href="user.md#0x0_user">user</a>: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_order">settle_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="order_info.md#0x0_order_info">order_info</a>: &OrderInfo,
    <a href="user.md#0x0_user">user</a>: &<b>mut</b> User,
) {
    <b>let</b> (<b>mut</b> base_in, <b>mut</b> base_out) = (0, 0);
    <b>let</b> (<b>mut</b> quote_in, <b>mut</b> quote_out) = (0, 0);
    <b>let</b> <b>mut</b> deep_in = 0;
    <b>let</b> (base_conversion_rate, _) = self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.conversion_rates();
    <b>let</b> total_volume = <a href="user.md#0x0_user">user</a>.taker_volume() + <a href="user.md#0x0_user">user</a>.maker_volume();
    <b>let</b> volume_in_deep = <a href="math.md#0x0_math_mul">math::mul</a>(total_volume, base_conversion_rate);
    <b>let</b> (taker_fee, maker_fee, stake_required) = <a href="order_info.md#0x0_order_info">order_info</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>().params();
    <b>let</b> taker_fee = <b>if</b> (<a href="user.md#0x0_user">user</a>.active_stake() &gt;= stake_required && volume_in_deep &gt;= stake_required) {
        <a href="math.md#0x0_math_div">math::div</a>(taker_fee, 2)
    } <b>else</b> {
        taker_fee
    };
    <b>let</b> executed_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.executed_quantity();
    <b>let</b> remaining_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.remaining_quantity();
    <b>let</b> cumulative_quote_quantity = <a href="order_info.md#0x0_order_info">order_info</a>.cumulative_quote_quantity();

    // Calculate the taker balances. These are derived from executed quantity.
    <b>let</b> (base_fee, quote_fee, deep_fee) = <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
        self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.calculate_fees(taker_fee, 0, cumulative_quote_quantity)
    } <b>else</b> {
        self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.calculate_fees(taker_fee, executed_quantity, 0)
    };
    deep_in = deep_in + deep_fee;
    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
        quote_in = quote_in + cumulative_quote_quantity + quote_fee;
        base_out = base_out + executed_quantity;
    } <b>else</b> {
        base_in = base_in + executed_quantity + base_fee;
        quote_out = quote_out + cumulative_quote_quantity;
    };

    // Calculate the maker balances. These are derived from the remaining quantity.
    <b>let</b> (base_fee, quote_fee, deep_fee) = <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
        self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.calculate_fees(maker_fee, 0, <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, <a href="order_info.md#0x0_order_info">order_info</a>.price()))
    } <b>else</b> {
        self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.calculate_fees(maker_fee, remaining_quantity, 0)
    };
    deep_in = deep_in + deep_fee;
    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.is_bid()) {
        quote_in = quote_in + <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, <a href="order_info.md#0x0_order_info">order_info</a>.price()) + quote_fee;
    } <b>else</b> {
        base_in = base_in + remaining_quantity + base_fee;
    };

    <a href="user.md#0x0_user">user</a>.add_settled_amounts(base_out, quote_out, 0);
    <a href="user.md#0x0_user">user</a>.add_owed_amounts(base_in, quote_in, deep_in);
}
</code></pre>



</details>

<a name="0x0_vault_add_deep_price_point"></a>

## Function `add_deep_price_point`



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
        <b>return</b> self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(1, pool_price, timestamp)
    };
    <b>if</b> (quote_type == deep_type) {
        <b>return</b> self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(pool_price, 1, timestamp)
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
    <b>let</b> deep_per_quote = <a href="math.md#0x0_math_div">math::div</a>(deep_per_base, pool_price);

    self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(deep_per_base, deep_per_quote, timestamp)
}
</code></pre>



</details>
