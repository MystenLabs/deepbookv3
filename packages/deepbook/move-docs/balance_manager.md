
<a name="0x0_balance_manager"></a>

# Module `0x0::balance_manager`

The BalanceManager is a shared object that holds all of the balances for different assets. A combination of <code><a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a></code> and
<code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> are passed into a pool to perform trades. A <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> can be generated in two ways: by the
owner directly, or by any <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code> owner. The owner can generate a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> without the risk of
equivocation. The <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code> owner, due to it being an owned object, risks equivocation when generating
a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code>. Generally, a high frequency trading engine will trade as the default owner.


-  [Resource `BalanceManager`](#0x0_balance_manager_BalanceManager)
-  [Struct `BalanceKey`](#0x0_balance_manager_BalanceKey)
-  [Resource `TradeCap`](#0x0_balance_manager_TradeCap)
-  [Struct `TradeProof`](#0x0_balance_manager_TradeProof)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_balance_manager_new)
-  [Function `share`](#0x0_balance_manager_share)
-  [Function `balance`](#0x0_balance_manager_balance)
-  [Function `mint_trade_cap`](#0x0_balance_manager_mint_trade_cap)
-  [Function `revoke_trade_cap`](#0x0_balance_manager_revoke_trade_cap)
-  [Function `generate_proof_as_owner`](#0x0_balance_manager_generate_proof_as_owner)
-  [Function `generate_proof_as_trader`](#0x0_balance_manager_generate_proof_as_trader)
-  [Function `deposit`](#0x0_balance_manager_deposit)
-  [Function `withdraw`](#0x0_balance_manager_withdraw)
-  [Function `withdraw_all`](#0x0_balance_manager_withdraw_all)
-  [Function `validate_proof`](#0x0_balance_manager_validate_proof)
-  [Function `owner`](#0x0_balance_manager_owner)
-  [Function `id`](#0x0_balance_manager_id)
-  [Function `deposit_with_proof`](#0x0_balance_manager_deposit_with_proof)
-  [Function `withdraw_with_proof`](#0x0_balance_manager_withdraw_with_proof)
-  [Function `delete`](#0x0_balance_manager_delete)
-  [Function `trader`](#0x0_balance_manager_trader)
-  [Function `validate_owner`](#0x0_balance_manager_validate_owner)
-  [Function `validate_trader`](#0x0_balance_manager_validate_trader)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="dependencies/sui-framework/bag.md#0x2_bag">0x2::bag</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_balance_manager_BalanceManager"></a>

## Resource `BalanceManager`

A shared object that is passed into pools for placing orders.


<pre><code><b>struct</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a> <b>has</b> key
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
<code><a href="balances.md#0x0_balances">balances</a>: <a href="dependencies/sui-framework/bag.md#0x2_bag_Bag">bag::Bag</a></code>
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

<a name="0x0_balance_manager_BalanceKey"></a>

## Struct `BalanceKey`

Balance identifier.


<pre><code><b>struct</b> <a href="balance_manager.md#0x0_balance_manager_BalanceKey">BalanceKey</a>&lt;T&gt; <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_balance_manager_TradeCap"></a>

## Resource `TradeCap`

Owners of a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code> need to get a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> to trade across pools in a single PTB (drops after).


<pre><code><b>struct</b> <a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a> <b>has</b> store, key
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
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_balance_manager_TradeProof"></a>

## Struct `TradeProof`

BalanceManager owner and <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code> owners can generate a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code>.
<code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> is used to validate the balance_manager when trading on DeepBook.


<pre><code><b>struct</b> <a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a> <b>has</b> drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>trader: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_balance_manager_EBalanceManagerBalanceTooLow"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_EBalanceManagerBalanceTooLow">EBalanceManagerBalanceTooLow</a>: u64 = 3;
</code></pre>



<a name="0x0_balance_manager_EInvalidOwner"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_EInvalidOwner">EInvalidOwner</a>: u64 = 0;
</code></pre>



<a name="0x0_balance_manager_EInvalidProof"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_EInvalidProof">EInvalidProof</a>: u64 = 2;
</code></pre>



<a name="0x0_balance_manager_EInvalidTrader"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_EInvalidTrader">EInvalidTrader</a>: u64 = 1;
</code></pre>



<a name="0x0_balance_manager_EMaxTradeCapsReached"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_EMaxTradeCapsReached">EMaxTradeCapsReached</a>: u64 = 4;
</code></pre>



<a name="0x0_balance_manager_ETradeCapNotInList"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_ETradeCapNotInList">ETradeCapNotInList</a>: u64 = 5;
</code></pre>



<a name="0x0_balance_manager_MAX_TRADE_CAPS"></a>



<pre><code><b>const</b> <a href="balance_manager.md#0x0_balance_manager_MAX_TRADE_CAPS">MAX_TRADE_CAPS</a>: u64 = 1000;
</code></pre>



<a name="0x0_balance_manager_new"></a>

## Function `new`



<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_new">new</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_new">new</a>(ctx: &<b>mut</b> TxContext): <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a> {
    <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
        owner: ctx.sender(),
        <a href="balances.md#0x0_balances">balances</a>: <a href="dependencies/sui-framework/bag.md#0x2_bag_new">bag::new</a>(ctx),
        allow_listed: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_share"></a>

## Function `share`



<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_share">share</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_share">share</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>) {
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>);
}
</code></pre>



</details>

<a name="0x0_balance_manager_balance"></a>

## Function `balance`

Returns the balance of a Coin in an balance_manager.


<pre><code><b>public</b> <b>fun</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>): u64 {
    <b>let</b> key = <a href="balance_manager.md#0x0_balance_manager_BalanceKey">BalanceKey</a>&lt;T&gt; {};
    <b>if</b> (!<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.contains(key)) {
        0
    } <b>else</b> {
        <b>let</b> acc_balance: &Balance&lt;T&gt; = &<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>[key];
        acc_balance.value()
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_mint_trade_cap"></a>

## Function `mint_trade_cap`

Mint a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code>, only owner can mint a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code>.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_mint_trade_cap">mint_trade_cap</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="balance_manager.md#0x0_balance_manager_TradeCap">balance_manager::TradeCap</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_mint_trade_cap">mint_trade_cap</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, ctx: &<b>mut</b> TxContext): <a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a> {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_owner">validate_owner</a>(ctx);
    <b>assert</b>!(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.allow_listed.length() &lt; <a href="balance_manager.md#0x0_balance_manager_MAX_TRADE_CAPS">MAX_TRADE_CAPS</a>, <a href="balance_manager.md#0x0_balance_manager_EMaxTradeCapsReached">EMaxTradeCapsReached</a>);

    <b>let</b> id = <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx);
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.allow_listed.push_back(id.to_inner());

    <a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a> {
        id,
        balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>),
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_revoke_trade_cap"></a>

## Function `revoke_trade_cap`

Revoke a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code>. Only the owner can revoke a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code>.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_revoke_trade_cap">revoke_trade_cap</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, trade_cap_id: &<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_revoke_trade_cap">revoke_trade_cap</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, trade_cap_id: &ID, ctx: &TxContext) {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_owner">validate_owner</a>(ctx);

    <b>let</b> (exists, idx) = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.allow_listed.index_of(trade_cap_id);
    <b>assert</b>!(exists, <a href="balance_manager.md#0x0_balance_manager_ETradeCapNotInList">ETradeCapNotInList</a>);
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.allow_listed.swap_remove(idx);
}
</code></pre>



</details>

<a name="0x0_balance_manager_generate_proof_as_owner"></a>

## Function `generate_proof_as_owner`

Generate a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> by the owner. The owner does not require a capability
and can generate TradeProofs without the risk of equivocation.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, ctx: &TxContext): <a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a> {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_owner">validate_owner</a>(ctx);

    <a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a> {
        balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>),
        trader: ctx.sender(),
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_generate_proof_as_trader"></a>

## Function `generate_proof_as_trader`

Generate a <code><a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a></code> with a <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code>.
Risk of equivocation since <code><a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a></code> is an owned object.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_trader">generate_proof_as_trader</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, trade_cap: &<a href="balance_manager.md#0x0_balance_manager_TradeCap">balance_manager::TradeCap</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_trader">generate_proof_as_trader</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, trade_cap: &<a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a>, ctx: &TxContext): <a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a> {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_trader">validate_trader</a>(trade_cap);

    <a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a> {
        balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>),
        trader: ctx.sender(),
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_deposit"></a>

## Function `deposit`

Deposit funds to an balance_manager. Only owner can call this directly.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_deposit">deposit</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_deposit">deposit</a>&lt;T&gt;(
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>,
    <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>: Coin&lt;T&gt;,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> proof = <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);

    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_deposit_with_proof">deposit_with_proof</a>(&proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>.into_balance());
}
</code></pre>



</details>

<a name="0x0_balance_manager_withdraw"></a>

## Function `withdraw`

Withdraw funds from an balance_manager. Only owner can call this directly.
If withdraw_all is true, amount is ignored and full balance withdrawn.
If withdraw_all is false, withdraw_amount will be withdrawn.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw">withdraw</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, withdraw_amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw">withdraw</a>&lt;T&gt;(
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>,
    withdraw_amount: u64,
    ctx: &<b>mut</b> TxContext,
): Coin&lt;T&gt; {
    <b>let</b> proof = <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);

    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_withdraw_with_proof">withdraw_with_proof</a>(&proof, withdraw_amount, <b>false</b>).into_coin(ctx)
}
</code></pre>



</details>

<a name="0x0_balance_manager_withdraw_all"></a>

## Function `withdraw_all`



<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw_all">withdraw_all</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw_all">withdraw_all</a>&lt;T&gt;(
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>,
    ctx: &<b>mut</b> TxContext,
): Coin&lt;T&gt; {
    <b>let</b> proof = <a href="balance_manager.md#0x0_balance_manager_generate_proof_as_owner">generate_proof_as_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);

    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_withdraw_with_proof">withdraw_with_proof</a>(&proof, 0, <b>true</b>).into_coin(ctx)
}
</code></pre>



</details>

<a name="0x0_balance_manager_validate_proof"></a>

## Function `validate_proof`



<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_proof">validate_proof</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_proof">validate_proof</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a>) {
    <b>assert</b>!(<a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>) == proof.balance_manager_id, <a href="balance_manager.md#0x0_balance_manager_EInvalidProof">EInvalidProof</a>);
}
</code></pre>



</details>

<a name="0x0_balance_manager_owner"></a>

## Function `owner`

Returns the owner of the balance_manager.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_owner">owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_owner">owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>): <b>address</b> {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.owner
}
</code></pre>



</details>

<a name="0x0_balance_manager_id"></a>

## Function `id`

Returns the owner of the balance_manager.


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_id">id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_id">id</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>): ID {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id.to_inner()
}
</code></pre>



</details>

<a name="0x0_balance_manager_deposit_with_proof"></a>

## Function `deposit_with_proof`

Deposit funds to an balance_manager. Pool will call this to deposit funds.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_deposit_with_proof">deposit_with_proof</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>, to_deposit: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;T&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_deposit_with_proof">deposit_with_proof</a>&lt;T&gt;(
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>,
    proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a>,
    to_deposit: Balance&lt;T&gt;,
) {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_proof">validate_proof</a>(proof);

    <b>let</b> key = <a href="balance_manager.md#0x0_balance_manager_BalanceKey">BalanceKey</a>&lt;T&gt; {};

    <b>if</b> (<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.contains(key)) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>: &<b>mut</b> Balance&lt;T&gt; = &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>[key];
        <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>.join(to_deposit);
    } <b>else</b> {
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.add(key, to_deposit);
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_withdraw_with_proof"></a>

## Function `withdraw_with_proof`

Withdraw funds from an balance_manager. Pool will call this to withdraw funds.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw_with_proof">withdraw_with_proof</a>&lt;T&gt;(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>, withdraw_amount: u64, withdraw_all: bool): <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_withdraw_with_proof">withdraw_with_proof</a>&lt;T&gt;(
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>,
    proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a>,
    withdraw_amount: u64,
    withdraw_all: bool,
): Balance&lt;T&gt; {
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_validate_proof">validate_proof</a>(proof);

    <b>let</b> key = <a href="balance_manager.md#0x0_balance_manager_BalanceKey">BalanceKey</a>&lt;T&gt; {};
    <b>let</b> key_exists = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.contains(key);
    <b>if</b> (withdraw_all) {
        <b>if</b> (key_exists) {
            <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.remove(key)
        } <b>else</b> {
            <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>()
        }
    } <b>else</b> {
        <b>assert</b>!(key_exists, <a href="balance_manager.md#0x0_balance_manager_EBalanceManagerBalanceTooLow">EBalanceManagerBalanceTooLow</a>);
        <b>let</b> acc_balance: &<b>mut</b> Balance&lt;T&gt; = &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>[key];
        <b>let</b> acc_value = acc_balance.value();
        <b>assert</b>!(acc_value &gt;= withdraw_amount, <a href="balance_manager.md#0x0_balance_manager_EBalanceManagerBalanceTooLow">EBalanceManagerBalanceTooLow</a>);
        <b>if</b> (withdraw_amount == acc_value) {
            <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balances.md#0x0_balances">balances</a>.remove(key)
        } <b>else</b> {
            acc_balance.split(withdraw_amount)
        }
    }
}
</code></pre>



</details>

<a name="0x0_balance_manager_delete"></a>

## Function `delete`

Deletes an balance_manager.
This is used for deleting temporary balance_managers for direct swap with pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_delete">delete</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_delete">delete</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>) {
    <b>let</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a> {
        id,
        owner: _,
        <a href="balances.md#0x0_balances">balances</a>,
        allow_listed: _,
    } = <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>;

    id.<a href="balance_manager.md#0x0_balance_manager_delete">delete</a>();
    <a href="balances.md#0x0_balances">balances</a>.destroy_empty();
}
</code></pre>



</details>

<a name="0x0_balance_manager_trader"></a>

## Function `trader`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_trader">trader</a>(trade_proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">balance_manager::TradeProof</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balance_manager.md#0x0_balance_manager_trader">trader</a>(trade_proof: &<a href="balance_manager.md#0x0_balance_manager_TradeProof">TradeProof</a>): <b>address</b> {
    trade_proof.trader
}
</code></pre>



</details>

<a name="0x0_balance_manager_validate_owner"></a>

## Function `validate_owner`



<pre><code><b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_owner">validate_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_owner">validate_owner</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, ctx: &TxContext) {
    <b>assert</b>!(ctx.sender() == <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.<a href="balance_manager.md#0x0_balance_manager_owner">owner</a>(), <a href="balance_manager.md#0x0_balance_manager_EInvalidOwner">EInvalidOwner</a>);
}
</code></pre>



</details>

<a name="0x0_balance_manager_validate_trader"></a>

## Function `validate_trader`



<pre><code><b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_trader">validate_trader</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, trade_cap: &<a href="balance_manager.md#0x0_balance_manager_TradeCap">balance_manager::TradeCap</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="balance_manager.md#0x0_balance_manager_validate_trader">validate_trader</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<a href="balance_manager.md#0x0_balance_manager_BalanceManager">BalanceManager</a>, trade_cap: &<a href="balance_manager.md#0x0_balance_manager_TradeCap">TradeCap</a>) {
    <b>assert</b>!(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.allow_listed.contains(<a href="dependencies/sui-framework/object.md#0x2_object_borrow_id">object::borrow_id</a>(trade_cap)), <a href="balance_manager.md#0x0_balance_manager_EInvalidTrader">EInvalidTrader</a>);
}
</code></pre>



</details>
