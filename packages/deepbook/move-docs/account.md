
<a name="0x0_account"></a>

# Module `0x0::account`

The Account is a shared object that holds all of the balances for a user. A combination of <code><a href="account.md#0x0_account_Account">Account</a></code> and
<code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> are passed into a pool to perform trades. A <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> can be generated in two ways: by the
owner directly, or by any <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code> owner. The owner can generate a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> without the risk of
equivocation. The <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code> owner, due to it being an owned object, risks equivocation when generating
a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code>. Generally, a high frequency trading engine will trade as the default owner.


-  [Resource `Account`](#0x0_account_Account)
-  [Struct `BalanceKey`](#0x0_account_BalanceKey)
-  [Resource `TradeCap`](#0x0_account_TradeCap)
-  [Struct `TradeProof`](#0x0_account_TradeProof)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_account_new)
-  [Function `share`](#0x0_account_share)
-  [Function `balance`](#0x0_account_balance)
-  [Function `mint_trade_cap`](#0x0_account_mint_trade_cap)
-  [Function `revoke_trade_cap`](#0x0_account_revoke_trade_cap)
-  [Function `generate_proof_as_owner`](#0x0_account_generate_proof_as_owner)
-  [Function `generate_proof_as_trader`](#0x0_account_generate_proof_as_trader)
-  [Function `deposit`](#0x0_account_deposit)
-  [Function `withdraw`](#0x0_account_withdraw)
-  [Function `validate_proof`](#0x0_account_validate_proof)
-  [Function `owner`](#0x0_account_owner)
-  [Function `deposit_with_proof`](#0x0_account_deposit_with_proof)
-  [Function `withdraw_with_proof`](#0x0_account_withdraw_with_proof)
-  [Function `delete`](#0x0_account_delete)
-  [Function `validate_owner`](#0x0_account_validate_owner)
-  [Function `validate_trader`](#0x0_account_validate_trader)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="dependencies/sui-framework/bag.md#0x2_bag">0x2::bag</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_account_Account"></a>

## Resource `Account`

A shared object that is passed into pools for placing orders.


<pre><code><b>struct</b> <a href="account.md#0x0_account_Account">Account</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>balances: <a href="dependencies/sui-framework/bag.md#0x2_bag_Bag">bag::Bag</a></code>
</dt>
<dd>

</dd>
<dt>
<code>allow_listed: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_account_BalanceKey"></a>

## Struct `BalanceKey`

Balance identifier.


<pre><code><b>struct</b> <a href="account.md#0x0_account_BalanceKey">BalanceKey</a>&lt;T&gt; <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_account_TradeCap"></a>

## Resource `TradeCap`

Owners of a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code> need to get a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> to trade across pools in a single PTB (drops after).


<pre><code><b>struct</b> <a href="account.md#0x0_account_TradeCap">TradeCap</a> <b>has</b> store, key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_account_TradeProof"></a>

## Struct `TradeProof`

Account owner and <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code> owners can generate a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code>.
<code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> is used to validate the account when trading on DeepBook.


<pre><code><b>struct</b> <a href="account.md#0x0_account_TradeProof">TradeProof</a> <b>has</b> drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_account_EAccountBalanceTooLow"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_EAccountBalanceTooLow">EAccountBalanceTooLow</a>: u64 = 3;
</code></pre>



<a name="0x0_account_EInvalidOwner"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_EInvalidOwner">EInvalidOwner</a>: u64 = 0;
</code></pre>



<a name="0x0_account_EInvalidProof"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_EInvalidProof">EInvalidProof</a>: u64 = 2;
</code></pre>



<a name="0x0_account_EInvalidTrader"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_EInvalidTrader">EInvalidTrader</a>: u64 = 1;
</code></pre>



<a name="0x0_account_EMaxTradeCapsReached"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_EMaxTradeCapsReached">EMaxTradeCapsReached</a>: u64 = 5;
</code></pre>



<a name="0x0_account_ENoBalance"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_ENoBalance">ENoBalance</a>: u64 = 4;
</code></pre>



<a name="0x0_account_ETradeCapNotInList"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_ETradeCapNotInList">ETradeCapNotInList</a>: u64 = 6;
</code></pre>



<a name="0x0_account_MAX_TRADE_CAPS"></a>



<pre><code><b>const</b> <a href="account.md#0x0_account_MAX_TRADE_CAPS">MAX_TRADE_CAPS</a>: u64 = 1000;
</code></pre>



<a name="0x0_account_new"></a>

## Function `new`



<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_new">new</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="account.md#0x0_account_Account">account::Account</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_new">new</a>(ctx: &<b>mut</b> TxContext): <a href="account.md#0x0_account_Account">Account</a> {
    <a href="account.md#0x0_account_Account">Account</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
        owner: ctx.sender(),
        balances: <a href="dependencies/sui-framework/bag.md#0x2_bag_new">bag::new</a>(ctx),
        allow_listed: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
    }
}
</code></pre>



</details>

<a name="0x0_account_share"></a>

## Function `share`



<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_share">share</a>(<a href="account.md#0x0_account">account</a>: <a href="account.md#0x0_account_Account">account::Account</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_share">share</a>(<a href="account.md#0x0_account">account</a>: <a href="account.md#0x0_account_Account">Account</a>) {
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="account.md#0x0_account">account</a>);
}
</code></pre>



</details>

<a name="0x0_account_balance"></a>

## Function `balance`

Returns the balance of a Coin in an account.


<pre><code><b>public</b> <b>fun</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">Account</a>): u64 {
    <b>let</b> key = <a href="account.md#0x0_account_BalanceKey">BalanceKey</a>&lt;T&gt; {};
    <b>if</b> (!<a href="account.md#0x0_account">account</a>.balances.contains(key)) {
        0
    } <b>else</b> {
        <b>let</b> acc_balance: &Balance&lt;T&gt; = &<a href="account.md#0x0_account">account</a>.balances[key];
        acc_balance.value()
    }
}
</code></pre>



</details>

<a name="0x0_account_mint_trade_cap"></a>

## Function `mint_trade_cap`

Mint a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code>, only owner can mint a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code>.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_mint_trade_cap">mint_trade_cap</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="account.md#0x0_account_TradeCap">account::TradeCap</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_mint_trade_cap">mint_trade_cap</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>, ctx: &<b>mut</b> TxContext): <a href="account.md#0x0_account_TradeCap">TradeCap</a> {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_owner">validate_owner</a>(ctx);
    <b>assert</b>!(<a href="account.md#0x0_account">account</a>.allow_listed.length() &lt; <a href="account.md#0x0_account_MAX_TRADE_CAPS">MAX_TRADE_CAPS</a>, <a href="account.md#0x0_account_EMaxTradeCapsReached">EMaxTradeCapsReached</a>);

    <b>let</b> id = <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx);
    <a href="account.md#0x0_account">account</a>.allow_listed.push_back(id.to_inner());

    <a href="account.md#0x0_account_TradeCap">TradeCap</a> {
        id,
        account_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="account.md#0x0_account">account</a>),
    }
}
</code></pre>



</details>

<a name="0x0_account_revoke_trade_cap"></a>

## Function `revoke_trade_cap`

Revoke a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code>. Only the owner can revoke a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code>.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_revoke_trade_cap">revoke_trade_cap</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, trade_cap_id: &<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_revoke_trade_cap">revoke_trade_cap</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>, trade_cap_id: &ID, ctx: &TxContext) {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_owner">validate_owner</a>(ctx);

    <b>let</b> (exists, idx) = <a href="account.md#0x0_account">account</a>.allow_listed.index_of(trade_cap_id);
    <b>assert</b>!(exists, <a href="account.md#0x0_account_ETradeCapNotInList">ETradeCapNotInList</a>);
    <a href="account.md#0x0_account">account</a>.allow_listed.swap_remove(idx);
}
</code></pre>



</details>

<a name="0x0_account_generate_proof_as_owner"></a>

## Function `generate_proof_as_owner`

Generate a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> by the owner. The owner does not require a capability
and can generate TradeProofs without the risk of equivocation.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="account.md#0x0_account_TradeProof">account::TradeProof</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>, ctx: &TxContext): <a href="account.md#0x0_account_TradeProof">TradeProof</a> {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_owner">validate_owner</a>(ctx);

    <a href="account.md#0x0_account_TradeProof">TradeProof</a> {
        account_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="account.md#0x0_account">account</a>),
    }
}
</code></pre>



</details>

<a name="0x0_account_generate_proof_as_trader"></a>

## Function `generate_proof_as_trader`

Generate a <code><a href="account.md#0x0_account_TradeProof">TradeProof</a></code> with a <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code>.
Risk of equivocation since <code><a href="account.md#0x0_account_TradeCap">TradeCap</a></code> is an owned object.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_generate_proof_as_trader">generate_proof_as_trader</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, trade_cap: &<a href="account.md#0x0_account_TradeCap">account::TradeCap</a>): <a href="account.md#0x0_account_TradeProof">account::TradeProof</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_generate_proof_as_trader">generate_proof_as_trader</a>(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>, trade_cap: &<a href="account.md#0x0_account_TradeCap">TradeCap</a>): <a href="account.md#0x0_account_TradeProof">TradeProof</a> {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_trader">validate_trader</a>(trade_cap);

    <a href="account.md#0x0_account_TradeProof">TradeProof</a> {
        account_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="account.md#0x0_account">account</a>),
    }
}
</code></pre>



</details>

<a name="0x0_account_deposit"></a>

## Function `deposit`

Deposit funds to an account. Only owner can call this directly.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_deposit">deposit</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_deposit">deposit</a>&lt;T&gt;(
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: Coin&lt;T&gt;,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> proof = <a href="account.md#0x0_account_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="account.md#0x0_account">account</a>, ctx);

    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_deposit_with_proof">deposit_with_proof</a>(&proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>);
}
</code></pre>



</details>

<a name="0x0_account_withdraw"></a>

## Function `withdraw`

Withdraw funds from an account. Only owner can call this directly.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_withdraw">withdraw</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, amount: u64, withdraw_all: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_withdraw">withdraw</a>&lt;T&gt;(
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    amount: u64,
    withdraw_all: bool,
    ctx: &<b>mut</b> TxContext,
): Coin&lt;T&gt; {
    <b>let</b> proof = <a href="account.md#0x0_account_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="account.md#0x0_account">account</a>, ctx);

    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_withdraw_with_proof">withdraw_with_proof</a>(&proof, amount, withdraw_all, ctx)
}
</code></pre>



</details>

<a name="0x0_account_validate_proof"></a>

## Function `validate_proof`



<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_validate_proof">validate_proof</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_validate_proof">validate_proof</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">TradeProof</a>) {
    <b>assert</b>!(<a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="account.md#0x0_account">account</a>) == proof.account_id, <a href="account.md#0x0_account_EInvalidProof">EInvalidProof</a>);
}
</code></pre>



</details>

<a name="0x0_account_owner"></a>

## Function `owner`

Returns the owner of the account.


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_owner">owner</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="account.md#0x0_account_owner">owner</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">Account</a>): <b>address</b> {
    <a href="account.md#0x0_account">account</a>.owner
}
</code></pre>



</details>

<a name="0x0_account_deposit_with_proof"></a>

## Function `deposit_with_proof`

Deposit funds to an account. Pool will call this to deposit funds.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_deposit_with_proof">deposit_with_proof</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="account.md#0x0_account_deposit_with_proof">deposit_with_proof</a>&lt;T&gt;(
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    proof: &<a href="account.md#0x0_account_TradeProof">TradeProof</a>,
    <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: Coin&lt;T&gt;,
) {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_proof">validate_proof</a>(proof);

    <b>let</b> key = <a href="account.md#0x0_account_BalanceKey">BalanceKey</a>&lt;T&gt; {};
    <b>let</b> to_deposit = <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>.into_balance();

    <b>if</b> (<a href="account.md#0x0_account">account</a>.balances.contains(key)) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>: &<b>mut</b> Balance&lt;T&gt; = &<b>mut</b> <a href="account.md#0x0_account">account</a>.balances[key];
        <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>.join(to_deposit);
    } <b>else</b> {
        <a href="account.md#0x0_account">account</a>.balances.add(key, to_deposit);
    }
}
</code></pre>



</details>

<a name="0x0_account_withdraw_with_proof"></a>

## Function `withdraw_with_proof`

Withdraw funds from an account. Pool will call this to withdraw funds.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_withdraw_with_proof">withdraw_with_proof</a>&lt;T&gt;(<a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, withdraw_all: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="account.md#0x0_account_withdraw_with_proof">withdraw_with_proof</a>&lt;T&gt;(
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    proof: &<a href="account.md#0x0_account_TradeProof">TradeProof</a>,
    amount: u64,
    withdraw_all: bool,
    ctx: &<b>mut</b> TxContext,
): Coin&lt;T&gt; {
    <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_validate_proof">validate_proof</a>(proof);

    <b>let</b> key = <a href="account.md#0x0_account_BalanceKey">BalanceKey</a>&lt;T&gt; {};
    <b>assert</b>!(<a href="account.md#0x0_account">account</a>.balances.contains(key), <a href="account.md#0x0_account_ENoBalance">ENoBalance</a>);
    <b>let</b> acc_balance: &<b>mut</b> Balance&lt;T&gt; = &<b>mut</b> <a href="account.md#0x0_account">account</a>.balances[key];
    <b>let</b> value = acc_balance.value();

    <b>if</b> (!withdraw_all) {
        <b>assert</b>!(value &gt;= amount, <a href="account.md#0x0_account_EAccountBalanceTooLow">EAccountBalanceTooLow</a>);
        acc_balance.split(amount).into_coin(ctx)
    } <b>else</b> {
        acc_balance.split(value).into_coin(ctx)
    }
}
</code></pre>



</details>

<a name="0x0_account_delete"></a>

## Function `delete`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_delete">delete</a>(<a href="account.md#0x0_account">account</a>: <a href="account.md#0x0_account_Account">account::Account</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="account.md#0x0_account_delete">delete</a>(<a href="account.md#0x0_account">account</a>: <a href="account.md#0x0_account_Account">Account</a>) {
    <b>let</b> <a href="account.md#0x0_account_Account">Account</a> {
        id,
        owner: _,
        balances,
        allow_listed: _,
    } = <a href="account.md#0x0_account">account</a>;

    id.<a href="account.md#0x0_account_delete">delete</a>();
    balances.destroy_empty();
}
</code></pre>



</details>

<a name="0x0_account_validate_owner"></a>

## Function `validate_owner`



<pre><code><b>fun</b> <a href="account.md#0x0_account_validate_owner">validate_owner</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="account.md#0x0_account_validate_owner">validate_owner</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">Account</a>, ctx: &TxContext) {
    <b>assert</b>!(ctx.sender() == <a href="account.md#0x0_account">account</a>.<a href="account.md#0x0_account_owner">owner</a>(), <a href="account.md#0x0_account_EInvalidOwner">EInvalidOwner</a>);
}
</code></pre>



</details>

<a name="0x0_account_validate_trader"></a>

## Function `validate_trader`



<pre><code><b>fun</b> <a href="account.md#0x0_account_validate_trader">validate_trader</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>, trade_cap: &<a href="account.md#0x0_account_TradeCap">account::TradeCap</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="account.md#0x0_account_validate_trader">validate_trader</a>(<a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">Account</a>, trade_cap: &<a href="account.md#0x0_account_TradeCap">TradeCap</a>) {
    <b>assert</b>!(<a href="account.md#0x0_account">account</a>.allow_listed.contains(<a href="dependencies/sui-framework/object.md#0x2_object_borrow_id">object::borrow_id</a>(trade_cap)), <a href="account.md#0x0_account_EInvalidTrader">EInvalidTrader</a>);
}
</code></pre>



</details>
