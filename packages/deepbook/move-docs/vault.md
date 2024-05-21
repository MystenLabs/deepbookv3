
<a name="0x0_vault"></a>

# Module `0x0::vault`



-  [Struct `DEEP`](#0x0_vault_DEEP)
-  [Struct `Vault`](#0x0_vault_Vault)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_vault_empty)
-  [Function `settle_account`](#0x0_vault_settle_account)
-  [Function `add_deep_price_point`](#0x0_vault_add_deep_price_point)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
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


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="vault.md#0x0_vault_settle_account">settle_account</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;, balances_out: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, balances_in: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="vault.md#0x0_vault_settle_account">settle_account</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="vault.md#0x0_vault_Vault">Vault</a>&lt;BaseAsset, QuoteAsset&gt;,
    balances_out: Balances,
    balances_in: Balances,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
) {
    <b>if</b> (balances_out.base() &gt; balances_in.base()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.base_balance.split(balances_out.base() - balances_in.base());
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_out.quote() &gt; balances_in.quote()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.quote_balance.split(balances_out.quote() - balances_in.quote());
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_out.deep() &gt; balances_in.deep()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.deep_balance.split(balances_out.deep() - balances_in.deep());
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_in.base() &gt; balances_out.base()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, balances_in.base() - balances_out.base(), <b>false</b>);
        self.base_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_in.quote() &gt; balances_out.quote()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, balances_in.quote() - balances_out.quote(), <b>false</b>);
        self.quote_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (balances_in.deep() &gt; balances_out.deep()) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, balances_in.deep() - balances_out.deep(), <b>false</b>);
        self.deep_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
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
